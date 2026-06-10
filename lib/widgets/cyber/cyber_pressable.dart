import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// CYBERCORE tactile feedback wrapper: scales its [child] down to
/// [pressedScale] while pressed (via [AnimatedScale], [FluffyDurations.instant])
/// and fires a light haptic impact on tap.
///
/// Two modes:
/// - **Active** ([onTap] non-null): owns the tap gesture via a
///   [GestureDetector] and triggers the haptic + callback itself.
/// - **Passive** ([onTap] null): only mirrors the press visually through a
///   raw [Listener], so an inner [InkWell]/button keeps its own tap handling
///   and ripple untouched. Add the haptic in the inner callback if wanted.
///
/// Respects reduce-motion: when `MediaQuery.disableAnimations` is true the
/// scale stays at 1.0 (no animation) but the haptic feedback is kept.
class CyberPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool haptics;
  final double pressedScale;

  const CyberPressable({
    required this.child,
    this.onTap,
    this.haptics = true,
    this.pressedScale = 0.96,
    super.key,
  });

  @override
  State<CyberPressable> createState() => _CyberPressableState();
}

class _CyberPressableState extends State<CyberPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final scaled = AnimatedScale(
      scale: _pressed && !reduceMotion ? widget.pressedScale : 1.0,
      duration: FluffyDurations.instant,
      curve: FluffyCurves.standard,
      child: widget.child,
    );
    if (widget.onTap != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: () {
          if (widget.haptics) HapticFeedback.lightImpact();
          widget.onTap!();
        },
        child: scaled,
      );
    }
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: scaled,
    );
  }
}
