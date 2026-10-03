import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  static const Duration _timeout = Duration(seconds: 6);
  static const int _maxBytes = 256 * 1024; // only need the <head>
  static const String _ua =
      'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 VOXLinkPreview/1.0';

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
    if (_isBlockedHost(uri.host)) {
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
        (segs.first == 'shorts' || segs.first == 'embed' || segs.first == 'v')) {
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
    try {
      final client = http.Client();
      try {
        final request = http.Request('GET', uri)
          ..followRedirects = true
          ..maxRedirects = 5
          ..headers['User-Agent'] = _ua
          ..headers['Accept'] = 'text/html,application/xhtml+xml,*/*';
        final streamed = await client.send(request).timeout(_timeout);
        if (streamed.statusCode ~/ 100 != 2) return null;
        final ct = streamed.headers['content-type'] ?? '';
        if (ct.isNotEmpty && !ct.contains('html')) {
          return null;
        }
        // Read at most _maxBytes — the <head> is all we need.
        final bytes = <int>[];
        await for (final chunk in streamed.stream) {
          bytes.addAll(chunk);
          if (bytes.length >= _maxBytes) break;
        }
        final html = utf8.decode(bytes, allowMalformed: true);
        return _parse(uri.toString(), html);
      } finally {
        client.close();
      }
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Minimal GET returning the decoded body (capped) or null on any failure.
  Future<String?> _get(String url, {required String accept}) async {
    try {
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url))
          ..followRedirects = true
          ..maxRedirects = 3
          ..headers['User-Agent'] = _ua
          ..headers['Accept'] = accept;
        final streamed = await client.send(request).timeout(_timeout);
        if (streamed.statusCode ~/ 100 != 2) return null;
        final bytes = <int>[];
        await for (final chunk in streamed.stream) {
          bytes.addAll(chunk);
          if (bytes.length >= _maxBytes) break;
        }
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        client.close();
      }
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
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

  bool _isBlockedHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' ||
        h.startsWith('127.') ||
        h.startsWith('10.') ||
        h.startsWith('192.168.') ||
        h.startsWith('169.254.') ||
        h == '::1' ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h);
  }
}
