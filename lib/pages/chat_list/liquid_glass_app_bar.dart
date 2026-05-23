import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Process-wide cache of the logged-in user's [Profile]. Sprint 2 V2
/// finding-004: previously [LiquidGlassAppBar] re-fetched the profile via a
/// fresh FutureBuilder on every rebuild → flash + metered-data cost.
/// We memoize the first successful fetch and serve subsequent reads
/// synchronously. Cleared by [resetOwnProfileCache] on logout.
Future<Profile?>? _ownProfileFuture;

void resetOwnProfileCache() {
  _ownProfileFuture = null;
}

Future<Profile?> _ownProfileCached(Client client) {
  return _ownProfileFuture ??=
      client.isLogged() ? client.fetchOwnProfile() : Future.value(null);
}

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

  /// Called when the user taps the settings icon (avatar pill on the left).
  final VoidCallback? onSettingsTap;

  /// Optional avatar to show as a settings entry point (left of the title).
  final Widget? leadingAvatar;

  /// Whether to render a greeting line ("Bonjour, $userName") under the title.
  final bool showGreeting;

  const LiquidGlassAppBar({
    super.key,
    this.onSearchTap,
    this.onNewChatTap,
    this.onSettingsTap,
    this.leadingAvatar,
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
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;

    final totalHeight = preferredSize.height + topPadding;

    return RepaintBoundary(
      child: SizedBox(
        height: totalHeight,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: cyber.blurSigmaAppBar,
              sigmaY: cyber.blurSigmaAppBar,
            ),
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
                            if (leadingAvatar != null) ...[
                              InkWell(
                                onTap: onSettingsTap,
                                customBorder: const CircleBorder(),
                                child: leadingAvatar,
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Text(
                                L10n.of(context).chats,
                                style: FluffyTypography.display.copyWith(
                                  color: colorScheme.onSurface,
                                  fontSize: 26,
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
                            if (leadingAvatar == null) ...[
                              const SizedBox(width: 4),
                              _AppBarIconButton(
                                icon: Icons.settings_outlined,
                                tooltip: L10n.of(context).settings,
                                onPressed: onSettingsTap,
                              ),
                            ],
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
    final cyber = theme.extension<CyberpunkTheme>();
    final client = Matrix.of(context).client;

    // Sprint 2 V2 finding-004: profile served from process-wide memo.
    // First sync paint shows greeting without name; second rebuild fills it
    // in. No more re-fetch on every appbar rebuild.
    return FutureBuilder<Profile?>(
      future: _ownProfileCached(client),
      builder: (context, snapshot) {
        final displayName = snapshot.data?.displayName ??
            client.userID?.localpart ??
            '';
        final greeting = _greetingForHour(context, DateTime.now().hour);
        return Align(
          alignment: Alignment.centerLeft,
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: FluffyTypography.bodyM.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              children: [
                TextSpan(text: greeting),
                if (displayName.isNotEmpty) ...[
                  TextSpan(text: ', '),
                  TextSpan(
                    text: displayName,
                    style: FluffyTypography.title.copyWith(
                      color: cyber?.cyan ?? theme.colorScheme.primary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _greetingForHour(BuildContext context, int hour) {
    final l10n = L10n.of(context);
    if (hour < 6) return l10n.greetingNight;
    if (hour < 12) return l10n.greetingMorning;
    if (hour < 18) return l10n.greetingAfternoon;
    return l10n.greetingEvening;
  }
}
