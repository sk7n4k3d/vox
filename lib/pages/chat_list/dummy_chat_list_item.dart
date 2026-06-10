import 'package:fluffychat/widgets/cyber/cyber_skeleton.dart';
import 'package:flutter/material.dart';

/// Placeholder row shown while the chat list is loading (or behind the
/// empty-state illustration). Rendered with [CyberSkeleton] shimmer boxes —
/// [animate] drives the shimmer (frozen automatically under reduce-motion).
class DummyChatListItem extends StatelessWidget {
  final double opacity;
  final bool animate;

  const DummyChatListItem({
    required this.opacity,
    required this.animate,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: ListTile(
        leading: CyberSkeleton(
          width: 40,
          height: 40,
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          animate: animate,
        ),
        title: Row(
          children: [
            Expanded(
              child: CyberSkeleton(height: 14, animate: animate),
            ),
            const SizedBox(width: 36),
            CyberSkeleton(
              width: 14,
              height: 14,
              borderRadius: const BorderRadius.all(Radius.circular(7)),
              animate: animate,
            ),
            const SizedBox(width: 12),
            CyberSkeleton(
              width: 14,
              height: 14,
              borderRadius: const BorderRadius.all(Radius.circular(7)),
              animate: animate,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(right: 22),
          child: CyberSkeleton(height: 12, animate: animate),
        ),
      ),
    );
  }
}
