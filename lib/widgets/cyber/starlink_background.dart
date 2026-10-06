import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// STARLINK — a moving constellation of electric-blue particles drifting
/// through space, linked by luminous filaments when they pass close to each
/// other, like a satellite mesh seen from the ground.
///
/// Perf contract (cyber_anim_contract):
/// - NO shader, NO per-pixel work: each frame is ~30 [drawCircle]s plus at
///   most a few dozen [drawLine]s — cheap vector primitives only.
/// - Motion is a PURE FUNCTION of the animation value: positions derive
///   deterministically from `t`, so the ticker never mutates state, never
///   calls setState, and repaints stay inside the [RepaintBoundary].
/// - Reduce-motion: renders the static `t = 0` constellation, no ticker.
class StarlinkBackground extends StatefulWidget {
  final double opacity;
  final Duration period;

  const StarlinkBackground({
    this.opacity = 0.55,
    this.period = const Duration(seconds: 48),
    super.key,
  });

  @override
  State<StarlinkBackground> createState() => _StarlinkBackgroundState();
}

class _StarlinkBackgroundState extends State<StarlinkBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    final ctrl = _ctrl;
    return RepaintBoundary(
      child: Opacity(
        opacity: widget.opacity,
        child: ctrl == null
            ? CustomPaint(
                painter: StarlinkPainter(
                  t: 0,
                  cyan: cyber.cyan,
                  violet: cyber.violet,
                  magenta: cyber.magenta,
                ),
              )
            : AnimatedBuilder(
                animation: ctrl,
                builder: (context, _) => CustomPaint(
                  painter: StarlinkPainter(
                    t: ctrl.value,
                    cyan: cyber.cyan,
                    violet: cyber.violet,
                    magenta: cyber.magenta,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Deterministic particle mesh, painted from scratch at animation value [t].
class StarlinkPainter extends CustomPainter {
  /// Progress in [0, 1) of the drift loop.
  final double t;
  final Color cyan;
  final Color violet;
  final Color magenta;

  const StarlinkPainter({
    required this.t,
    required this.cyan,
    required this.violet,
    required this.magenta,
  });

  /// Deterministic pseudo-random in [0, 1) from an integer seed (no storage).
  static double _rand(int i, int salt) {
    var x = (i * 374761393 + salt * 668265263) & 0x7FFFFFFF;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7FFFFFFF;
    return ((x ^ (x >> 16)) & 0x7FFFFFFF) / 0x7FFFFFFF;
  }

  /// Position of particle [i] at loop progress [t]. Particles wrap inside a
  /// box larger than the viewport so the wrap pop happens off-screen.
  static Offset _particle(int i, Size size, double t) {
    final margin = size.shortestSide * 0.15;
    final w = size.width + margin * 2;
    final h = size.height + margin * 2;
    final speed = 0.15 + _rand(i, 3) * 0.25; // fraction of the box per cycle
    final dx = (_rand(i, 1) * 2 - 1) * speed * w * t;
    final dy = (_rand(i, 2) * 2 - 1) * speed * h * t;
    final x = ((_rand(i, 4) * w + dx) % w + w) % w - margin;
    final y = ((_rand(i, 5) * h + dy) % h + h) % h - margin;
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 28 particules (au lieu de 42) : le coût est dominé par les halos, pas par
    // le nombre de particules, mais on garde de la marge.
    const count = 28;
    final linkDist = size.shortestSide * 0.19;
    final pts = List.generate(count, (i) => _particle(i, size, t));

    // Luminous filaments between close particles.
    final linkPaint = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      for (var j = i + 1; j < count; j++) {
        final d = (pts[i] - pts[j]).distance;
        if (d >= linkDist) continue;
        final a = (1 - d / linkDist) * 0.60;
        canvas.drawLine(
          pts[i],
          pts[j],
          linkPaint..color = cyan.withValues(alpha: a),
        );
      }
    }

    // Particles: a few bright 'satellites', the rest dim stars.
    //
    // Le halo était un MaskFilter.blur : 42 flous hors-écran par frame, chacun
    // avec son propre calque. Mesuré : 12 à 14 ms de raster par frame (73-82 fps
    // au lieu de 120). On le remplace par deux disques translucides concentriques
    // — mêmes ronds doux, sans calque ni blur.
    for (var i = 0; i < count; i++) {
      final bright = _rand(i, 7) > 0.7;
      final r = bright ? 2.8 : 1.5;
      final glowColor = cyan.withValues(alpha: bright ? 0.12 : 0.06);
      canvas.drawCircle(pts[i], r * 3.4, Paint()..color = glowColor);
      canvas.drawCircle(pts[i], r * 2.1, Paint()
        ..color = cyan.withValues(alpha: bright ? 0.18 : 0.09));
      final core = Paint()
        ..color = (bright ? violet : cyan).withValues(
          alpha: bright ? 1.0 : 0.75,
        );
      canvas.drawCircle(pts[i], r, core);
    }
  }

  @override
  bool shouldRepaint(StarlinkPainter old) =>
      old.t != t ||
      old.cyan != cyan ||
      old.violet != violet ||
      old.magenta != magenta;
}
