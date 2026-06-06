import 'dart:async';

import 'package:http/http.dart' as http;

/// Open-Graph / HTML metadata for a URL, used to render an inline link preview.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  bool get hasContent =>
      (title != null && title!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty);
}

/// Fetches link previews (og:title / og:image / og:description) with sane
/// safety limits. NOT a naive fetch: short timeout, capped response size, only
/// http(s), and a neutral UA. SSRF note — the OS resolves DNS; we still avoid
/// obviously-internal hosts. Results are cached per-URL for the session.
class LinkPreviewService {
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  static const Duration _timeout = Duration(seconds: 6);
  static const int _maxBytes = 256 * 1024; // only need the <head>

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
    try {
      final client = http.Client();
      try {
        final request = http.Request('GET', uri)
          ..followRedirects = true
          ..maxRedirects = 5
          ..headers['User-Agent'] =
              'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 VOXLinkPreview/1.0'
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
        final html = String.fromCharCodes(bytes);
        final data = _parse(url, html);
        return data;
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
