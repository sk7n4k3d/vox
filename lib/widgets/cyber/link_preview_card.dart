import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// Inline link-preview card shared by the SMS and Matrix message renderers.
/// Fetches og: metadata for [url] and shows a compact title/site/image card.
/// Renders nothing while loading or when no usable metadata exists. Tap calls
/// [onOpen] (the caller decides how to open the link).
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

  @override
  void initState() {
    super.initState();
    _load(widget.url);
  }

  @override
  void didUpdateWidget(LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load(widget.url);
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
        onTap: widget.onOpen,
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
              if (data.imageUrl != null && data.imageUrl!.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: Image.network(
                    data.imageUrl!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    loadingBuilder: (ctx, child, progress) =>
                        progress == null ? child : const SizedBox.shrink(),
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
          ),
        ),
      ),
    );
  }
}
