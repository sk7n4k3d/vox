import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';
import 'package:glow_effects/glow_effects.dart';

/// CYBERCORE motion layer — wraps the `glow_effects` GPU library behind
/// reduce-motion-safe helpers. Every animated effect degrades to a static
/// fallback when the user enables "reduce motion", and shader-heavy effects are
/// only ever used on STATIC surfaces (never behind a scrolling list) to keep
/// the 120 fps budget the perf audit demands.
class CyberMotion {
  const CyberMotion._();

  /// True when the OS asks us to minimise animation. Read once per build.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}

/// A neon-glow shader frame around [child]. Static fallback = a hairline glow
/// border. Use on buttons, cards, avatars — NOT inside scrolling lists.
class CyberNeonFrame extends StatelessWidget {
  final Widget child;
  final Color? color;
  final double glowRadius;
  final bool enabled;

  const CyberNeonFrame({
    required this.child,
    this.color,
    this.glowRadius = 0.04,
    this.enabled = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final glowColor = color ?? cyber.cyan;
    if (!enabled || CyberMotion.reduced(context)) {
      // Static fallback: soft glow shadow, no shader.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: FluffyRadius.brMd,
          boxShadow: FluffyElevation.glowCyan(glowColor, alpha: 0.3),
        ),
        child: child,
      );
    }
    return GKWidget(
      effect: NeonGlowEffect(glowColor: glowColor, glowRadius: glowRadius),
      trigger: GKTrigger.auto,
      child: child,
    );
  }
}

/// Animated heading text: glitch-reveal on first paint, then static. Falls back
/// to a plain [Text] under reduce-motion. Used for app-bar / hero titles.
class CyberGlitchText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final GKTextEffectType effect;
  final Duration duration;

  const CyberGlitchText(
    this.text, {
    this.style,
    this.effect = GKTextEffectType.glitchReveal,
    this.duration = FluffyDurations.xslow,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = style ??
        FluffyTypography.headlineM.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        );
    if (CyberMotion.reduced(context)) {
      return Text(text, style: resolved);
    }
    return GKTextEffect(
      text: text,
      effect: effect,
      style: resolved,
      duration: duration,
    );
  }
}

/// A perf-managed effect host: auto-downscales effect intensity when FPS drops.
/// Renders only [child] (no shader) under reduce-motion. Use to host a heavier
/// background [effect] so it never tanks the frame budget.
class CyberManaged extends StatelessWidget {
  final GKEffect effect;
  final Widget? child;
  const CyberManaged({required this.effect, this.child, super.key});

  @override
  Widget build(BuildContext context) {
    if (CyberMotion.reduced(context)) return child ?? const SizedBox.shrink();
    return GKManagedWidget(effect: effect, child: child);
  }
}

/// Cyber page transition (warp), with a fade fallback under reduce-motion.
/// Mirrors [MaterialPageRoute] usage but with the CYBERCORE feel. GKPageRoute
/// already falls back to fade internally when the OS requests reduced motion.
Route<T> cyberRoute<T>(Widget page) =>
    GKPageRoute<T>(page: page, type: GKTransitionType.warp);
