import 'dart:math' as math;

import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// A cheap animated aurora backdrop for conversation screens.
///
/// Replaces the previous full-screen `AuroraEffect` fragment shader — which
/// recomputed every pixel of the viewport on every frame and tanked the frame
/// budget behind the timeline (violating the CYBERCORE perf contract: no shader
/// behind a scrolling list). This variant paints the aurora ONCE into a
/// [RepaintBoundary] and animates it with a single [Transform] (rotation +
/// drift), so the GPU only applies a matrix per frame: the blobs are never
/// re-rasterised.
///
/// Honours reduce-motion: the backdrop renders statically with no animation and
/// no ticker.
class AuroraBackground extends StatefulWidget {
  /// Opacity applied to the whole backdrop (default matches the previous 0.22).
  final double opacity;

  /// Duration of one full cycle of the drift/rotation loop.
  final Duration period;

  const AuroraBackground({
    this.opacity = 0.22,
    this.period = const Duration(seconds: 60),
    super.key,
  });

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ticker lifecycle follows reduce-motion: never keep one alive when the OS
    // asks us to minimise animation.
    final reduced = CyberMotion.reduced(context);
    if (reduced) {
      _ctrl?.dispose();
      _ctrl = null;
    } else {
      _ctrl ??= AnimationController(vsync: this, duration: widget.period)
        ..repeat();
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    // Overscan: the layer is painted larger than the viewport and shifted by
    // the animation, so its edges never slide into view. 1.6 covers the
    // rotation of the largest blob plus the drift.
    final painted = RepaintBoundary(
      child: Transform.scale(
        scale: 1.6,
        child: CustomPaint(
          painter: _AuroraPainter(
            cyan: cyber.cyan,
            violet: cyber.violet,
            magenta: cyber.magenta,
          ),
        ),
      ),
    );

    final ctrl = _ctrl;
    if (ctrl == null) {
      // Reduce-motion: static, no ticker, no transform rebuild per frame.
      return Opacity(opacity: widget.opacity, child: painted);
    }

    return Opacity(
      opacity: widget.opacity,
      child: AnimatedBuilder(
        animation: ctrl,
        // Child is hoisted: the aurora layer is painted once and only wrapped in
        // the Transform below, never rebuilt by the ticker.
        child: painted,
        builder: (context, child) {
          final t = ctrl.value * 2 * math.pi;
          // Slow breathing drift + a gentle rotation of the whole layer.
          final dx = math.sin(t) * 36;
          final dy = math.cos(t * 0.7) * 28;
          final angle = math.sin(t * 0.5) * 0.09;
          return Transform.translate(
            offset: Offset(dx, dy),
            child: Transform.rotate(angle: angle, child: child),
          );
        },
      ),
    );
  }
}

/// Paints the aurora as a handful of soft radial gradients — cheap polygon
/// fills instead of a per-pixel fragment shader. The [CustomPaint] is sized to
/// the viewport; the parent scales it up so the blobs bleed past the edges.
class _AuroraPainter extends CustomPainter {
  final Color cyan;
  final Color violet;
  final Color magenta;

  const _AuroraPainter({
    required this.cyan,
    required this.violet,
    required this.magenta,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Base wash so the viewport is never fully transparent.
    final base = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          cyan.withValues(alpha: 0.05),
          violet.withValues(alpha: 0.08),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, base);

    // A few large, soft radial blobs. Radii are fractions of the larger
    // dimension so the composition scales with the screen.
    final r = size.longestSide;
    _blob(canvas, size, cyan, const Alignment(-0.45, -0.55), r * 0.85, 0.95);
    _blob(canvas, size, violet, const Alignment(0.55, -0.15), r * 0.95, 0.85);
    _blob(canvas, size, magenta, const Alignment(-0.10, 0.75), r * 0.80, 0.75);
  }

  void _blob(
    Canvas canvas,
    Size size,
    Color color,
    Alignment align,
    double radius,
    double intensity,
  ) {
    final center = align.withinRect(Offset.zero & size);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.30 * intensity),
          color.withValues(alpha: 0.12 * intensity),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.cyan != cyan || old.violet != violet || old.magenta != magenta;
}
