import 'dart:math';

import 'package:flutter/material.dart';

/// Effet « l'app prend feu » : des flammes montent du bas de l'écran sur toute
/// la largeur, surmontées d'une lueur orange/rouge qui pulse, par-dessus le chat.
/// Plein écran garanti (peint en fonction des contraintes réelles). S'auto-termine
/// au bout de [duration] en appelant [onDone].
class BurningOverlay extends StatefulWidget {
  final Duration duration;
  final VoidCallback onDone;

  const BurningOverlay({
    required this.onDone,
    this.duration = const Duration(milliseconds: 2600),
    super.key,
  });

  @override
  State<BurningOverlay> createState() => _BurningOverlayState();
}

class _BurningOverlayState extends State<BurningOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final List<_Flame> _flames;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    // 64 langues de feu réparties sur la largeur, hauteurs/vitesses variées.
    _flames = List.generate(64, (i) {
      return _Flame(
        x: _rng.nextDouble(),
        baseHeight: 0.22 + _rng.nextDouble() * 0.30,
        width: 0.04 + _rng.nextDouble() * 0.06,
        speed: 0.7 + _rng.nextDouble() * 0.8,
        phase: _rng.nextDouble() * pi * 2,
      );
    });
    _c
      ..forward()
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // Enveloppe : montée rapide (0→0.18), tenue, extinction (0.8→1).
        final t = _c.value;
        final envelope = t < 0.18
            ? t / 0.18
            : t > 0.8
                ? (1 - t) / 0.2
                : 1.0;
        return CustomPaint(
          painter: _FirePainter(
            progress: t,
            envelope: envelope.clamp(0.0, 1.0),
            flames: _flames,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Flame {
  final double x; // position horizontale 0..1
  final double baseHeight; // hauteur max relative 0..1
  final double width; // largeur relative
  final double speed; // facteur de scintillement
  final double phase;
  const _Flame({
    required this.x,
    required this.baseHeight,
    required this.width,
    required this.speed,
    required this.phase,
  });
}

class _FirePainter extends CustomPainter {
  final double progress;
  final double envelope;
  final List<_Flame> flames;

  _FirePainter({
    required this.progress,
    required this.envelope,
    required this.flames,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (envelope <= 0) return;
    final w = size.width;
    final h = size.height;

    // 1. Lueur de fond montant du bas (gradient orange→rouge→transparent).
    final glowRect = Rect.fromLTWH(0, h * 0.45, w, h * 0.55);
    final glow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          const Color(0xFFFF5A00).withValues(alpha: 0.55 * envelope),
          const Color(0xFFFF2E00).withValues(alpha: 0.28 * envelope),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(glowRect);
    canvas.drawRect(glowRect, glow);

    // 2. Vignette rouge sur les bords (l'écran « chauffe »).
    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.1,
        colors: [
          Colors.transparent,
          const Color(0xFFB31200).withValues(alpha: 0.22 * envelope),
        ],
        stops: const [0.6, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);

    // 3. Langues de feu qui montent du bas, scintillantes.
    for (final f in flames) {
      final flicker =
          0.78 + 0.22 * sin(progress * 18 * f.speed + f.phase).abs();
      final flameH = h * f.baseHeight * envelope * flicker;
      final cx = f.x * w;
      final fw = f.width * w;
      final top = h - flameH;

      final path = Path()
        ..moveTo(cx - fw / 2, h)
        ..quadraticBezierTo(cx - fw * 0.5, h - flameH * 0.5, cx, top)
        ..quadraticBezierTo(cx + fw * 0.5, h - flameH * 0.5, cx + fw / 2, h)
        ..close();

      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0xFFFFE066).withValues(alpha: 0.95 * envelope),
            const Color(0xFFFF7A00).withValues(alpha: 0.9 * envelope),
            const Color(0xFFFF2E00).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromLTWH(cx - fw, top, fw * 2, flameH))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_FirePainter old) =>
      old.progress != progress || old.envelope != envelope;
}
