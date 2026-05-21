import 'dart:ui';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Liquid Glass AppBar — Material 3 Expressive style.
///
/// Blurred translucent surface (BackdropFilter sigma 20), hairline border,
/// large display title with optional greeting subtitle, and right-aligned
/// action icons (search, new chat).
///
/// Designed to be used with `Scaffold(extendBodyBehindAppBar: true)` so that
/// the scrolling content is visible under the blur.
class LiquidGlassAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  /// Total visual height of the bar (excludes status bar — that's handled
  /// internally via SafeArea top padding).
  static const double _barHeight = 64.0;

  /// Optional greeting line height (added when [showGreeting] is true).
  static const double _greetingHeight = 28.0;

  /// Called when the user taps the search icon.
  final VoidCallback? onSearchTap;

  /// Called when the user taps the new-chat icon.
  final VoidCallback? onNewChatTap;

  /// Whether to render a greeting line ("Bonjour, $userName") under the title.
  final bool showGreeting;

  const LiquidGlassAppBar({
    super.key,
    this.onSearchTap,
    this.onNewChatTap,
    this.showGreeting = false,
  });

  @override
  Size get preferredSize => Size.fromHeight(
        showGreeting ? _barHeight + _greetingHeight : _barHeight,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;

    final totalHeight = preferredSize.height + topPadding;

    return RepaintBoundary(
      child: SizedBox(
        height: totalHeight,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.65),
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.15),
                    width: 0.5,
                  ),
                ),
              ),
              padding: EdgeInsets.only(top: topPadding),
              child: SafeArea(
                top: false,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: _barHeight,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                L10n.of(context).chats,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.onSurface,
                                  letterSpacing: -0.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _AppBarIconButton(
                              icon: Icons.search_outlined,
                              tooltip: L10n.of(context).search,
                              onPressed: onSearchTap,
                            ),
                            const SizedBox(width: 4),
                            _AppBarIconButton(
                              icon: Icons.add_rounded,
                              tooltip: L10n.of(context).newChat,
                              onPressed: onNewChatTap,
                            ),
                          ],
                        ),
                      ),
                      if (showGreeting)
                        SizedBox(
                          height: _greetingHeight,
                          child: _GreetingLine(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppBarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _AppBarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 24),
      style: IconButton.styleFrom(
        foregroundColor: colorScheme.onSurface,
        backgroundColor: colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.4,
        ),
        shape: const CircleBorder(),
        padding: const EdgeInsets.all(10),
      ),
    );
  }
}

class _GreetingLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;

    return FutureBuilder<Profile?>(
      future: client.isLogged() ? client.fetchOwnProfile() : null,
      builder: (context, snapshot) {
        final displayName = snapshot.data?.displayName ??
            client.userID?.localpart ??
            '';
        final greeting = _greetingForHour(DateTime.now().hour);
        final fullText =
            displayName.isEmpty ? greeting : '$greeting, $displayName';
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            fullText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w400,
            ),
          ),
        );
      },
    );
  }

  String _greetingForHour(int hour) {
    if (hour < 6) return 'Bonne nuit';
    if (hour < 12) return 'Bonjour';
    if (hour < 18) return 'Bon après-midi';
    return 'Bonsoir';
  }
}
