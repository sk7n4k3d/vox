import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Which provider a preview came from — drives whether the tap opens the raw
/// link or an inline media player/embed.
enum LinkPreviewKind { generic, youtube, tiktok, instagram }

/// Open-Graph / oEmbed metadata for a URL, used to render an inline preview.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  /// Provider that produced this preview.
  final LinkPreviewKind kind;

  /// YouTube / TikTok video id, when [kind] is one of those.
  final String? videoId;

  /// Instagram embed HTML (oEmbed `html` field), played in a WebView on tap.
  final String? embedHtml;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
    this.kind = LinkPreviewKind.generic,
    this.videoId,
    this.embedHtml,
  });

  bool get hasContent =>
      (title != null && title!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty) ||
      (embedHtml != null && embedHtml!.isNotEmpty);
}

/// Fetches link previews. For YouTube / TikTok / Instagram it uses the public
/// tokenless oEmbed endpoints (no API key); otherwise it parses OpenGraph tags
/// from the HTML. Safety limits everywhere: short timeout, capped response
/// size, only http(s), neutral UA. Results are cached per-URL for the session.
class LinkPreviewService {
  LinkPreviewService._()
    : _newClient = _pinningClient,
      _lookup = InternetAddress.lookup,
      _timeoutOverride = null;

  @visibleForTesting
  LinkPreviewService.forTesting({
    http.Client Function(List<InternetAddress> addresses)? newClient,
    Future<List<InternetAddress>> Function(String host)? lookup,
    Duration? timeoutOverride,
  }) : _newClient = newClient ?? _pinningClient,
       _lookup = lookup ?? InternetAddress.lookup,
       _timeoutOverride = timeoutOverride;

  static final LinkPreviewService instance = LinkPreviewService._();

  /// Fabrique de client HTTP — en production un client **épinglé** sur les
  /// adresses déjà validées ; injectable dans les tests.
  final http.Client Function(List<InternetAddress> addresses) _newClient;

  /// Résolution DNS, injectable dans les tests.
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Échelle de temps réduite pour les tests de délai ; production = null.
  final Duration? _timeoutOverride;

  static const Duration _timeout = Duration(seconds: 6);

  /// Budget total d'un fetch, redirections et lecture du corps comprises :
  /// sans lui, chaque saut consommait son propre timeout d'en-têtes et un
  /// corps envoyé au compte-gouttes pouvait laisser le Future pendu.
  static const Duration _totalTimeout = Duration(seconds: 15);
  static const int _maxBytes = 256 * 1024; // only need the <head>
  static const int _maxImageBytes = 2 * 1024 * 1024;
  static const String _ua =
      'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 VOXLinkPreview/1.0';

  Duration get _chunkTimeout => _timeoutOverride ?? _timeout;
  Duration get _totalBudget =>
      _timeoutOverride != null ? _timeoutOverride * 3 : _totalTimeout;

  /// Client dont les connexions sortantes sont **fixées** sur les adresses
  /// déjà jugées : entre notre résolution et le dial du client, le DNS n'a
  /// plus sa mot à dire (anti rebinding). Pour https, la socket est montée
  /// en TLS **ici** : `HttpClient.connectionFactory` fait confiance à la
  /// socket retournée et n'ajoute jamais TLS lui-même (http_impl.dart ne
  /// wrappe que le chemin proxy CONNECT). On appelle donc nous-mêmes
  /// [SecureSocket.secure] avec `host:` = nom d'origine, ce qui conserve
  /// SNI **et** vérification de certificat (rejet par défaut d'un
  /// certificat non inspiré ou mal nommé).
  static http.Client _pinningClient(
    List<InternetAddress> addresses, {
    SecurityContext? trustedRootsOverride,
  }) => IOClient(
    HttpClient(context: trustedRootsOverride)
      ..connectionFactory =
          (Uri target, String? proxyHost, int? proxyPort) async {
            final secure = target.scheme == 'https';
            final dialed = _dialPinned(
              addresses,
              target,
              secure,
              trustedRootsOverride,
            );
            return ConnectionTask.fromSocket<Socket>(
              dialed,
              () => dialed.then(
                (s) => s.destroy(),
                onError: (Object _) {}, // échec de dial : rien à détruire
              ),
            );
          },
  );

  /// Test-visible : le client épinglé réel de la prod, avec une racine de
  /// confiance optionnelle pour servir aux tests TLS réels.
  @visibleForTesting
  static http.Client pinningClientForTesting(
    List<InternetAddress> addresses, {
    SecurityContext? trustedRootsOverride,
  }) => _pinningClient(
    addresses,
    trustedRootsOverride: trustedRootsOverride,
  );

  static Future<Socket> _dialPinned(
    List<InternetAddress> addresses,
    Uri target,
    bool secure, [
    // Racine personnalisée : uniquement pour les tests TLS réels ; la prod
    // passe null et SecureSocket.secure utilise les racines système.
    SecurityContext? context,
  ]) async {
    Object? lastError;
    for (final addr in addresses) {
      Socket? raw;
      try {
        raw = await Socket.connect(
          addr,
          target.hasPort ? target.port : (secure ? 443 : 80),
          timeout: _timeout,
        );
        if (!secure) return raw;
        return await SecureSocket.secure(
          raw,
          // Nom d'ORIGINE (jamais l'IP) : SNI + vérification du certificat
          // contre le nom demandé. Pas d'onBadCertificate = rejet par défaut.
          host: target.host,
          context: context,
        );
      } catch (e) {
        lastError = e;
        try {
          raw?.destroy();
        } catch (_) {}
      }
    }
    throw lastError ??
        const SocketException('no resolved address could be dialed');
  }

  final Map<String, Future<LinkPreviewData?>> _cache = {};
  // Synchronous result cache: lets a recycled list cell render the preview
  // immediately (no loading flicker) once it has been fetched once.
  final Map<String, LinkPreviewData?> _resolved = {};

  /// Already-resolved preview for [url], if it was fetched before. `null` value
  /// means "fetched, no preview"; absent key means "not fetched yet".
  bool isResolved(String url) => _resolved.containsKey(url);
  LinkPreviewData? resolved(String url) => _resolved[url];

  Future<LinkPreviewData?> fetch(String url) {
    return _cache.putIfAbsent(url, () async {
      final data = await _doFetch(url);
      _resolved[url] = data;
      return data;
    });
  }

  Future<LinkPreviewData?> _doFetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    if (isBlockedPreviewHost(uri.host)) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (_isYoutube(host)) {
      final d = await _fetchOembedJson(
        'https://www.youtube.com/oembed'
        '?url=${Uri.encodeComponent(url)}&format=json',
        url: url,
        kind: LinkPreviewKind.youtube,
        videoId: _youtubeId(uri),
      );
      if (d != null) return d;
    } else if (_isTiktok(host)) {
      final d = await _fetchOembedJson(
        'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}',
        url: url,
        kind: LinkPreviewKind.tiktok,
        videoId: _tiktokId(uri),
        authorField: 'author_name',
      );
      if (d != null) return d;
    } else if (_isInstagram(host)) {
      final d = await _fetchInstagram(url);
      if (d != null) return d;
    }
    return _fetchOg(uri);
  }

  bool _isYoutube(String host) =>
      host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');

  bool _isTiktok(String host) =>
      host == 'tiktok.com' || host.endsWith('.tiktok.com');

  bool _isInstagram(String host) =>
      host == 'instagram.com' ||
      host.endsWith('.instagram.com') ||
      host == 'instagr.am';

  String? _youtubeId(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return v;
    final segs = uri.pathSegments;
    if (segs.length >= 2 &&
        (segs.first == 'shorts' ||
            segs.first == 'embed' ||
            segs.first == 'v')) {
      return segs[1];
    }
    return null;
  }

  String? _tiktokId(Uri uri) {
    final m = RegExp(r'/video/(\d+)').firstMatch(uri.path);
    return m?.group(1);
  }

  Future<LinkPreviewData?> _fetchOembedJson(
    String endpoint, {
    required String url,
    required LinkPreviewKind kind,
    String? videoId,
    String authorField = 'author_name',
  }) async {
    final body = await _get(endpoint, accept: 'application/json');
    if (body == null) return null;
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final title = _str(j['title']);
      final author = _str(j[authorField]);
      final image = _str(j['thumbnail_url']);
      final data = LinkPreviewData(
        url: url,
        title: title,
        description: author,
        imageUrl: image,
        siteName: kind == LinkPreviewKind.youtube ? 'YouTube' : 'TikTok',
        kind: kind,
        videoId: videoId,
      );
      return data.hasContent ? data : null;
    } catch (_) {
      return null;
    }
  }

  Future<LinkPreviewData?> _fetchInstagram(String url) async {
    final body = await _get(
      'https://graph.facebook.com/v25.0/instagram_oembed'
      '?url=${Uri.encodeComponent(url)}',
      accept: 'application/json',
    );
    if (body == null) return null;
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final html = _str(j['html']);
      final image = _str(j['thumbnail_url']);
      final author = _str(j['author_name']);
      if ((html == null || html.isEmpty) && image == null) return null;
      return LinkPreviewData(
        url: url,
        title: author,
        description: author,
        imageUrl: image,
        siteName: 'Instagram',
        kind: LinkPreviewKind.instagram,
        embedHtml: html,
      );
    } catch (_) {
      return null;
    }
  }

  Future<LinkPreviewData?> _fetchOg(Uri uri) async {
    final r = await _guardedFetch(
      uri,
      accept: 'text/html,application/xhtml+xml,*/*',
      maxBytes: _maxBytes,
      maxRedirects: 5,
    );
    if (r == null) return null;
    if (r.contentType.isNotEmpty && !r.contentType.contains('html')) {
      return null;
    }
    // Read at most _maxBytes — the <head> is all we need.
    return _parse(uri.toString(), utf8.decode(r.bytes, allowMalformed: true));
  }

  /// Cache des vignettes déjà demandées : la carte se reconstruit à chaque
  /// interaction, sans clé de cache chaque rebuild relancerait un fetch.
  /// Plafonné en OCTETS (audit 2026-11-04) : l'ancien plafond de 64 entrées
  /// laissait traîner jusqu'à 64 × 2 Mo de décodés. Chaque insertion réserve
  /// le pire cas ([_maxImageBytes]), corrigé à la résolution de la future.
  final Map<String, Future<Uint8List?>> _imageCache = {};
  final Map<String, int> _imageCacheSizes = {};
  int _imageCacheBytes = 0;

  static const int _maxImageCacheBytes = 8 * 1024 * 1024;

  Future<Uint8List?> fetchImage(String imageUrl) {
    final existing = _imageCache[imageUrl];
    if (existing != null) return existing;
    while (_imageCacheBytes + _maxImageBytes > _maxImageCacheBytes &&
        _imageCache.isNotEmpty) {
      final oldest = _imageCache.keys.first;
      _imageCache.remove(oldest);
      _imageCacheBytes -= _imageCacheSizes.remove(oldest) ?? 0;
    }
    _imageCacheBytes += _maxImageBytes;
    // réserve le pire cas dès l'insertion : une entrée non résolue doit déjà
    // compter dans le budget, sinon l'éviction sous-compte.
    _imageCacheSizes[imageUrl] = _maxImageBytes;
    final future = _fetchImage(imageUrl).then((bytes) {
      // L'entrée a pu être évictée pendant que sa future était en vol : son
      // quota a déjà été rendu au budget à l'éviction. Toute correction ici
      // créerait un déficit comptable (le plafond se désarme) et une taille
      // orpheline dans la map. Entrée sortie = on ne comptabilise rien.
      if (!_imageCache.containsKey(imageUrl)) return bytes;
      final actual = bytes?.length ?? 0;
      final reserved = _imageCacheSizes[imageUrl] ?? _maxImageBytes;
      _imageCacheSizes[imageUrl] = actual;
      _imageCacheBytes = (_imageCacheBytes + actual - reserved).clamp(0, 1 << 30);
      return bytes;
    });
    _imageCache[imageUrl] = future;
    return future;
  }

  @visibleForTesting
  int get imageCacheBytesForTest => _imageCacheBytes;

  @visibleForTesting
  int get imageCacheCountForTest => _imageCache.length;

  /// Vignette : **même** pipeline gardé que les pages (https seul, résolution
  /// validée, connexion épinglée, taille et durée plafonnées). Une chaîne
  /// `og:image` vient du HTML distant et peut pointer vers le téléphone :
  /// elle ne doit jamais finir dans un `Image.network` brut.
  Future<Uint8List?> _fetchImage(String imageUrl) async {
    final img = Uri.tryParse(imageUrl);
    if (img == null || img.scheme != 'https') return null;
    final r = await _guardedFetch(
      img,
      accept: 'image/*',
      maxBytes: _maxImageBytes,
      maxRedirects: 3,
    );
    if (r == null) return null;
    if (!r.contentType.toLowerCase().startsWith('image/')) return null;
    return Uint8List.fromList(r.bytes);
  }

  /// GETs tous azimuts du service : chaque saut est vérifié **après
  /// résolution DNS**, rejeté si une réponse tombe dans le réseau interne,
  /// puis épinglé sur les adresses jugées. La lecture du corps est bornée en
  /// octets et dans le temps, et l'ensemble de la chaîne a une deadline
  /// globale.
  Future<_GuardedResponse?> _guardedFetch(
    Uri start, {
    required String accept,
    required int maxBytes,
    required int maxRedirects,
  }) async {
    final deadline = DateTime.now().add(_totalBudget);
    var current = start;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (DateTime.now().isAfter(deadline)) return null;
      if (current.scheme != 'http' && current.scheme != 'https') return null;
      // Ports autorisés uniquement (audit 2026-11-04) : un lien de SMS ne
      // doit pas transformer l'app en scanner de ports pour tout Internet.
      if (!_allowedPort(current)) return null;
      if (isBlockedPreviewHost(current.host)) return null;
      final addrs = await _resolveSafe(current.host);
      if (addrs == null || addrs.isEmpty) return null;
      final client = _newClient(addrs);
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = _ua
          ..headers['Accept'] = accept;
        final remaining = deadline.difference(DateTime.now());
        final streamed = await client
            .send(request)
            .timeout(remaining.isNegative ? Duration.zero : remaining);
        final status = streamed.statusCode;
        if (status >= 300 && status < 400) {
          final location = streamed.headers['location'];
          try {
            await streamed.stream.drain<void>().timeout(_chunkTimeout);
          } catch (_) {
            // corps de redirection sans intérêt : on a déjà lu ce qu'on veut.
          }
          if (location == null || location.isEmpty) return null;
          final next = current.resolve(location);
          if (next.scheme != 'http' && next.scheme != 'https') return null;
          current = next;
          continue;
        }
        if (status ~/ 100 != 2) return null;
        final bytes = <int>[];
        await for (final chunk in streamed.stream.timeout(_chunkTimeout)) {
          bytes.addAll(chunk);
          if (bytes.length >= maxBytes) break;
          if (DateTime.now().isAfter(deadline)) break;
        }
        return _GuardedResponse(
          status,
          streamed.headers['content-type'] ?? '',
          bytes,
        );
      } on TimeoutException {
        return null;
      } catch (_) {
        return null;
      } finally {
        client.close();
      }
    }
    return null;
  }

  /// Uniquement les ports standards 80/443 ([Uri.port] vaut déjà le port par
  /// défaut du schéma quand l'URL n'en porte pas).
  static bool _allowedPort(Uri uri) => uri.port == 80 || uri.port == 443;

  /// Adresses dialables pour [host] : les réponses du DNS une par une —
  /// **toute** réponse interne fait rejeter l'hôte entier (un seul enregistrement
  /// `A 127.0.0.1` suffit à annuler le filtre sinon). Les littéraux d'adresse
  /// sont déjà passés par [isBlockedPreviewHost] en amont.
  Future<List<InternetAddress>?> _resolveSafe(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];
    try {
      final answers = await _lookup(host);
      if (answers.isEmpty) return null;
      if (answers.any(isBlockedIpAddress)) return null;
      return answers;
    } catch (_) {
      return null;
    }
  }

  /// Minimal GET returning the decoded body (capped) or null on any failure.
  Future<String?> _get(String url, {required String accept}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final r = await _guardedFetch(
      uri,
      accept: accept,
      maxBytes: _maxBytes,
      maxRedirects: 3,
    );
    if (r == null) return null;
    return utf8.decode(r.bytes, allowMalformed: true);
  }

  LinkPreviewData? _parse(String url, String html) {
    String? meta(String property) {
      // <meta property="og:title" content="...">  (property or name, any order)
      final re = RegExp(
        '<meta[^>]+(?:property|name)=["\']$property["\'][^>]+content=["\']([^"\']*)["\']',
        caseSensitive: false,
      );
      final m = re.firstMatch(html);
      if (m != null) return _decode(m.group(1));
      // content before property variant
      final re2 = RegExp(
        '<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']$property["\']',
        caseSensitive: false,
      );
      return _decode(re2.firstMatch(html)?.group(1));
    }

    var title = meta('og:title');
    if (title == null || title.isEmpty) {
      final t = RegExp(
        r'<title[^>]*>([^<]*)</title>',
        caseSensitive: false,
      ).firstMatch(html);
      title = _decode(t?.group(1));
    }
    final image = _absolute(url, meta('og:image'));
    final data = LinkPreviewData(
      url: url,
      title: title,
      description: meta('og:description'),
      imageUrl: image,
      siteName: meta('og:site_name'),
    );
    return data.hasContent ? data : null;
  }

  String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  String? _absolute(String base, String? maybe) {
    if (maybe == null || maybe.isEmpty) return null;
    final m = Uri.tryParse(maybe);
    if (m == null) return null;
    if (m.hasScheme) return maybe;
    return Uri.tryParse(base)?.resolve(maybe).toString();
  }

  String? _decode(String? s) {
    if (s == null) return null;
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .trim();
  }
}

/// Vrai quand [host] désigne le téléphone lui-même ou son réseau local : une
/// miniature ne doit jamais aller gratter une adresse interne (un SMS malveillant
/// peut contenir n'importe quel lien, et un lien public peut rediriger vers
/// `http://127.0.0.1:…`). Les noms de domaine ne sont jamais testés ici — seuls
/// les littéraux d'adresse, qui sont la voie directe vers l'interne.
@visibleForTesting
bool isBlockedPreviewHost(String host) {
  var h = host.toLowerCase();
  if (h.isEmpty) return true;
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final ip = InternetAddress.tryParse(h);
  if (ip != null) return isBlockedIpAddress(ip);
  // Une écriture numérique ou hexadécimale du tout (2130706433, 0x7f000001) est
  // une adresse IP sous une forme que certains résolveurs acceptent : jamais un
  // nom de domaine légitime.
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(h)) return true;
  if (RegExp(r'^[0-9.]+$').hasMatch(h)) return true;
  return false;
}

@visibleForTesting
bool isBlockedIpAddress(InternetAddress ip) {
  if (ip.isMulticast) return true;
  final b = ip.rawAddress;
  if (b.length == 4) return _blockedV4(b);
  // Adresses "a IPv4 incorporee" : mappee ::ffff:a.b.c, compat depreciee
  // ::a.b.c, ou prefixe 0/ffff fourre (::ffff:0:a.b.c, releve par l'audit).
  // Tout prefixe compose uniquement de zeros et de 0xff porte de l'IPv4 dans
  // les 4 derniers octets : c'est cette IPv4 qu'il faut juger.
  if (b.sublist(0, 12).every((x) => x == 0 || x == 0xff)) {
    return _blockedV4(b.sublist(12));
  }
  if (ip.isLoopback || ip.isLinkLocal) return true;
  if (b.every((x) => x == 0)) return true; // ::
  // ULA fc00::/7 (equivalent prive du v6).
  if ((b[0] & 0xfe) == 0xfc) return true;
  // Traductions et tunnels : NAT64 64:ff9b::/96 (porte vers de l'IPv4, juge
  // comme tel), Teredo 2001:0000::/32, 6to4 2002::/16, discard 100::/64. Sur
  // Android ces prefixes ne sont jamais de vrais sites web.
  if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
    return _blockedV4(b.sublist(12)); // NAT64 well-known
  }
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) {
    return true; // Teredo 2001:0000::/32
  }
  if (b[0] == 0x20 && b[1] == 0x02) return true; // 6to4 2002::/16
  if (b[0] == 0x01 && b[1] == 0x00) return true; // discard 100::/64
  return false;
}

bool _blockedV4(List<int> b) {
  final a = b[0];
  if (a == 0 || a == 10 || a == 127) return true;
  if (a == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT 100.64/10
  if (a == 169 && b[1] == 254) return true; // link-local
  if (a == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (a == 192 && b[1] == 168) return true;
  if (a >= 224) return true; // multicast et réservé
  return false;
}

/// Réponse d'un `_guardedFetch` : corps **déjà lu**, borné en taille et en
/// temps par le pipeline.
class _GuardedResponse {
  const _GuardedResponse(this.status, this.contentType, this.bytes);

  final int status;
  final String contentType;
  final List<int> bytes;
}
