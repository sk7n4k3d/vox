import 'dart:ui';

import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// CYBERCORE entrance shell for the project's custom Material dialogs.
///
/// Wraps an [AlertDialog] (or any dialog widget) with:
///  - a scale+fade opening transition ([FluffyDurations.fast] +
///    [FluffyCurves.emphasized]),
///  - a subtle full-bleed glass veil (backdrop blur + faint cyan tint) behind
///    the dialog, in line with the CyberGlass design language.
///
/// Strictly additive: content, texts and actions are untouched. On iOS/macOS
/// `AlertDialog.adaptive` renders the native Cupertino dialog, so the shell
/// passes the child through unchanged. Under reduce-motion the transition is
/// skipped entirely (static fallback, no animation).
class CyberDialogShell extends StatelessWidget {
  final Widget child;

  const CyberDialogShell({required this.child, super.key});

  static const double _beginScale = 0.94;

  @override
  Widget build(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        // Native Cupertino dialogs keep their platform look and motion.
        return child;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        break;
    }
    final cyber = CyberColors.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return Stack(
        children: [
          _GlassVeil(sigma: cyber.blurSigmaChip, tint: cyber.cyan),
          child,
        ],
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: FluffyDurations.fast,
      curve: FluffyCurves.emphasized,
      child: child,
      builder: (context, t, dialog) => Stack(
        children: [
          _GlassVeil(sigma: cyber.blurSigmaChip * t, tint: cyber.cyan),
          Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: _beginScale + (1.0 - _beginScale) * t,
              child: dialog,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-bleed blurred veil behind the dialog — wrapped in [IgnorePointer] so
/// barrier-dismiss taps keep working exactly as before.
class _GlassVeil extends StatelessWidget {
  final double sigma;
  final Color tint;

  const _GlassVeil({required this.sigma, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: ColoredBox(color: tint.withValues(alpha: 0.03)),
          ),
        ),
      ),
    );
  }
}
