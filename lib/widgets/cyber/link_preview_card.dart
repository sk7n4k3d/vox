import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Inline link-preview card shared by the SMS and Matrix message renderers.
/// Fetches og: metadata for [url] and shows a compact title/site/image card.
/// Renders nothing while loading or when no usable metadata exists.
///
/// Tap on a media link (YouTube/TikTok/Instagram) swaps the THUMBNAIL for the
/// player IN PLACE, inside the bubble — no bottom sheet. Tap again to collapse
/// back to the card. Generic links call [onOpen].
class LinkPreviewCard extends StatefulWidget {
  final String url;
  final VoidCallback onOpen;

  const LinkPreviewCard({
    required this.url,
    required this.onOpen,
    super.key,
  });

  /// First http(s) URL in [body], or null. Shared helper so callers detect the
  /// preview target identically.
  static final RegExp _urlRe =
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
  static String? firstUrl(String body) => _urlRe.firstMatch(body)?.group(0);

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  LinkPreviewData? _data;
  bool _done = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load(widget.url);
  }

  @override
  void didUpdateWidget(LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _expanded = false;
      _load(widget.url);
    }
  }

  void _load(String url) {
    final svc = LinkPreviewService.instance;
    // Already fetched (cache hit) → render synchronously, NO loading state.
    // This is what kills the flicker when a list cell is recycled on scroll.
    if (svc.isResolved(url)) {
      _data = svc.resolved(url);
      _done = true;
      return;
    }
    _data = null;
    _done = false;
    svc.fetch(url).then((d) {
      if (!mounted) return;
      setState(() {
        _data = d;
        _done = true;
      });
    });
  }

  bool get _isPlayable {
    final data = _data;
    if (data == null) return false;
    return switch (data.kind) {
      LinkPreviewKind.youtube => true,
      LinkPreviewKind.tiktok => true,
      LinkPreviewKind.instagram =>
        data.embedHtml != null && data.embedHtml!.isNotEmpty,
      LinkPreviewKind.generic => false,
    };
  }

  /// Tap: playable media → expand the player in place; anything else → the
  /// caller's default open (external browser / app).
  void _open() {
    final data = _data;
    if (data == null) return;
    if (!_isPlayable) {
      widget.onOpen();
      return;
    }
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (!_done || data == null || !data.hasContent) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: FluffyRadius.brMd,
        onTap: _open,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.6),
            borderRadius: FluffyRadius.brMd,
            border: Border(
              left: BorderSide(color: cyber.cyan, width: 3),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_expanded)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _InlinePlayer(
                    data: data,
                    onClose: () => setState(() => _expanded = false),
                  ),
                )
              else ...[
                if (data.imageUrl != null && data.imageUrl!.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: Stack(
                      fit: StackFit.passthrough,
                      children: [
                        Image.network(
                          data.imageUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          loadingBuilder: (ctx, child, progress) =>
                              progress == null ? child : const SizedBox.shrink(),
                        ),
                        if (_isPlayable)
                          Positioned.fill(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: cyber.cyan,
                                  size: 32,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(FluffySpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (data.siteName != null && data.siteName!.isNotEmpty)
                        Text(
                          data.siteName!.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FluffyTypography.labelM.copyWith(
                            color: cyber.cyan,
                            letterSpacing: 0.8,
                          ),
                        ),
                      if (data.title != null && data.title!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            data.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: FluffyTypography.bodyM.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (data.description != null &&
                          data.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            data.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: FluffyTypography.bodyS.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// In-place player that replaces the thumbnail: YouTube via the iframe player,
/// TikTok via the official /player/v1 embed, Instagram via its oEmbed HTML.
/// Owns and closes its controller. A small close chip collapses back to the
/// card.
class _InlinePlayer extends StatefulWidget {
  final LinkPreviewData data;
  final VoidCallback onClose;

  const _InlinePlayer({required this.data, required this.onClose});

  @override
  State<_InlinePlayer> createState() => _InlinePlayerState();
}

class _InlinePlayerState extends State<_InlinePlayer> {
  YoutubePlayerController? _yt;
  WebViewController? _web;

  @override
  void initState() {
    super.initState();
    final d = widget.data;
    switch (d.kind) {
      case LinkPreviewKind.youtube:
        final id = d.videoId;
        if (id != null && id.isNotEmpty) {
          _yt = YoutubePlayerController.fromVideoId(
            videoId: id,
            autoPlay: true,
            params: const YoutubePlayerParams(
              showControls: true,
              showFullscreenButton: true,
            ),
          );
        }
      case LinkPreviewKind.tiktok:
        final id = d.videoId;
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.black)
          ..loadRequest(
            Uri.parse(
              id != null && id.isNotEmpty
                  ? 'https://www.tiktok.com/player/v1/$id'
                  : d.url,
            ),
          );
      case LinkPreviewKind.instagram:
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.black)
          ..loadHtmlString(d.embedHtml ?? '', baseUrl: 'https://www.instagram.com');
      case LinkPreviewKind.generic:
        break;
    }
  }

  @override
  void dispose() {
    _yt?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final yt = _yt;
    final web = _web;
    final cyber = CyberColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: yt != null
              ? YoutubePlayer(controller: yt, aspectRatio: 16 / 9)
              : (web != null
                  ? WebViewWidget(controller: web)
                  : const SizedBox.shrink()),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.close_rounded,
                color: cyber.cyan,
                size: 18,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
