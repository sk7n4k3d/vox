import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Horizontal scrollable list of Material 3 Expressive shape-morphing pills.
///
/// Selected pill: full stadium (radius 28) on `colorScheme.primary`.
/// Unselected pill: squircle (radius 12) on `surfaceContainerHigh`.
/// Transition: 280 ms with [Curves.easeInOutCubicEmphasized].
class ChatListFilterPills extends StatelessWidget {
  static const double height = 52.0;

  final ChatListController controller;

  /// Optional list of filters to show. Defaults to the canonical 5.
  final List<ActiveFilter>? filters;

  const ChatListFilterPills({
    super.key,
    required this.controller,
    this.filters,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveFilters = filters ??
        const [
          ActiveFilter.allChats,
          ActiveFilter.unread,
          ActiveFilter.messages,
          ActiveFilter.groups,
          ActiveFilter.spaces,
        ];

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: effectiveFilters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = effectiveFilters[index];
          final selected = filter == controller.activeFilter;
          return _FilterPill(
            label: filter.toLocalizedString(context),
            selected: selected,
            onTap: () {
              HapticFeedback.selectionClick();
              controller.setActiveFilter(filter);
            },
          );
        },
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  static const Duration _duration = Duration(milliseconds: 280);
  static const Curve _curve = Curves.easeInOutCubicEmphasized;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final backgroundColor = selected
        ? colorScheme.primary
        : colorScheme.surfaceContainerHigh;
    final foregroundColor = selected
        ? colorScheme.onPrimary
        : colorScheme.onSurfaceVariant;
    final borderRadius = BorderRadius.circular(selected ? 28.0 : 12.0);

    return AnimatedContainer(
      duration: _duration,
      curve: _curve,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: borderRadius,
        border: selected
            ? null
            : Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 1,
              ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: AnimatedContainer(
            duration: _duration,
            curve: _curve,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: AnimatedDefaultTextStyle(
              duration: _duration,
              curve: _curve,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: foregroundColor,
                letterSpacing: 0.1,
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

/// SliverPersistentHeader delegate to use [ChatListFilterPills] inside a
/// CustomScrollView while keeping it pinned under the AppBar.
class ChatListFilterPillsDelegate extends SliverPersistentHeaderDelegate {
  final ChatListController controller;
  final Color? backgroundColor;

  ChatListFilterPillsDelegate({
    required this.controller,
    this.backgroundColor,
  });

  @override
  double get minExtent => ChatListFilterPills.height;

  @override
  double get maxExtent => ChatListFilterPills.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: backgroundColor ??
          Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
      child: ChatListFilterPills(controller: controller),
    );
  }

  @override
  bool shouldRebuild(covariant ChatListFilterPillsDelegate oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
