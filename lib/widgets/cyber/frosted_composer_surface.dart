import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';

/// Pilule frosted glass réutilisable pour la composer : blur opaque, hairline
/// néon, glow cyan animé quand [focused], bordure magenta quand [recording].
class FrostedComposerSurface extends StatelessWidget {
  final Widget child;
  final bool focused;
  final bool recording;

  const FrostedComposerSurface({
    required this.child,
    this.focused = false,
    this.recording = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final borderColor = recording
        ? cyber.magenta.withValues(alpha: 0.7)
        : focused
            ? cyber.cyan.withValues(alpha: 0.7)
            : cyber.violet.withValues(alpha: 0.45);
    final glowColor = recording ? cyber.magenta : cyber.cyan;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AnimatedContainer(
          duration: FluffyDurations.fast,
          curve: FluffyCurves.decelerated,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: (focused || recording)
                ? [
                    BoxShadow(
                      color: glowColor.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
