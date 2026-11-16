import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// A cheap animated aurora backdrop for conversation screens.
///
/// Replaces the previous full-screen `AuroraEffect` fragment shader — which
/// recomputed every pixel of the viewport on every frame and tanked the frame
/// budget behind the timeline (violating the CYBERCORE perf contract: no shader
/// behind a scrolling list).
///
/// ## Comment on évite de saturer le thread raster (mesuré 2026-11-16)
///
/// Deux pièges successifs, chacun mesuré sur Pixel 10 Pro XL :
///
/// 1. Un `CustomPaint` derrière la timeline est **re-joué à chaque image
///    produite** (le display list d'un RepaintBoundary n'est pas une texture :
///    l'engine rejoue les 4 dégradés radiaux plein écran ~7 ms, y compris
///    pendant le scroll). Un ticker `repeat()` à 120 Hz produit 120 images/s
///    => ~90 % du thread raster EN REPOS derrière une conversation, et le
///    scroll rame (« rame dans les conversations », mesuré : 88 % raster au
///    repos, frames présentées toutes les 30-80 ms).
/// 2. Quantifier l'offset à 24 fps ne suffit PAS : le ticker produit quand même
///    une image par vsync, et chaque image rejoue la scène complète.
///
/// D'où le design actuel :
/// - le calque est **pré-rasterisé UNE fois dans un [ui.Image]** (les dégradés
///   ne sont peints qu'au changement de thème/taille) ; chaque image ne coûte
///   plus qu'un blit de texture (~0,5 ms) ;
/// - la dérive est cadencée par un [Timer.periodic] à [_fps] images/s (8) et
///   non par un ticker vsync : entre deux pas, AUCUNE image n'est programmée,
///   le raster dort (0 % au repos). À 22 px de dérive sur 60 s, 8 img/s reste
///   visuellement continu (0,37 px/pas).
///
/// Honours reduce-motion: renders the static image with no timer.
class AuroraBackground extends StatefulWidget {
  /// Opacity applied to the whole backdrop (default matches the previous 0.22).
  final double opacity;

  /// Duration of one full cycle of the drift loop.
  final Duration period;

  /// Cadence de la dérive ambiante. La dérive est lente (22 px / 60 s) : 8
  /// images/s suffisent et laissent le budget raster à la timeline.
  static const int fps = 8;

  const AuroraBackground({
    this.opacity = 0.22,
    this.period = const Duration(seconds: 60),
    super.key,
  });

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> {
  ui.Image? _image;
  Timer? _drift;
  int _step = 0;

  // Anti-rebond du re-rastérisation : pendant une animation de resize
  // (clavier, rotation, drag desktop) les contraintes changent à chaque
  // image ; on ne rappelle _render() qu'une fois la taille stabilisée.
  Timer? _resizeDebounce;
  bool _resizeSettled = false;

  // Signature de la dernière image pré-rasterisée (taille + thème).
  Size _imageSize = Size.zero;
  Color? _c1, _c2, _c3;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Le timer suit reduce-motion : aucun cadencement quand l'OS demande la
    // sobriété animée.
    if (CyberMotion.reduced(context)) {
      _drift?.cancel();
      _drift = null;
    } else {
      _drift ??= Timer.periodic(
        Duration(milliseconds: 1000 ~/ AuroraBackground.fps),
        (_) {
          if (!mounted) return;
          setState(() => _step = (_step + 1) % _stepsPerCycle());
        },
      );
    }
  }

  @override
  void dispose() {
    _drift?.cancel();
    _resizeDebounce?.cancel();
    _image?.dispose();
    super.dispose();
  }

  int _stepsPerCycle() =>
      (widget.period.inMicroseconds * AuroraBackground.fps / 1000000)
          .round()
          .clamp(1, 1 << 30);

  /// Déplacement seul (une rotation ferait grossir les bornes du calque et
  /// forcerait un repaint complet) ; positions déterministes du pas.
  Offset _offsetFor(int step) {
    final t = step / _stepsPerCycle() * 2 * math.pi;
    return Offset(math.sin(t) * 22, math.cos(t * 0.7) * 18);
  }

  ui.Image _render(Size size, double dpr, CyberpunkTheme cyber) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _AuroraPainter(
      cyan: cyber.cyan,
      violet: cyber.violet,
      magenta: cyber.magenta,
      opacity: widget.opacity,
    ).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (size.width * dpr).ceil(),
      (size.height * dpr).ceil(),
    );
    picture.dispose();
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();
        if (_image == null ||
            _c1 != cyber.cyan ||
            _c2 != cyber.violet ||
            _c3 != cyber.magenta) {
          _resizeDebounce?.cancel();
          _resizeSettled = false;
          _image?.dispose();
          _image = _render(size, dpr, cyber);
          _imageSize = size;
          _c1 = cyber.cyan;
          _c2 = cyber.violet;
          _c3 = cyber.magenta;
        } else if (_imageSize != size) {
          if (_resizeSettled) {
            // Taille stabilisée (le debounce a tiré) : re-rastérisation unique.
            _resizeSettled = false;
            _image?.dispose();
            _image = _render(size, dpr, cyber);
            _imageSize = size;
          } else {
            // Resize en cours (clavier qui glisse, rotation, drag desktop) :
            // les contraintes changent à CHAQUE image de l'animation.
            // Re-peindre le calque plein écran par image (~7 ms + ~18 Mo
            // realloqués) sature le thread raster pendant la transition
            // (audit ultracode #19). On affiche l'ancienne texture étirée
            // (blit pur via BoxFit.fill) et on ne re-rastérise qu'une fois
            // la taille stabilisée.
            _resizeDebounce?.cancel();
            _resizeDebounce = Timer(const Duration(milliseconds: 150), () {
              if (mounted) setState(() => _resizeSettled = true);
            });
          }
        }
        return Transform.translate(
          offset: _offsetFor(_step),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: RawImage(image: _image, fit: BoxFit.fill),
          ),
        );
      },
    );
  }
}

/// Paints the aurora as a handful of soft radial gradients — cheap polygon
/// fills instead of a per-pixel fragment shader. Invoked ONCE per theme/size
/// into the cached [ui.Image], never per frame.
class _AuroraPainter extends CustomPainter {
  final Color cyan;
  final Color violet;
  final Color magenta;

  /// Global opacity baked into every alpha (replaces the former full-screen
  /// `Opacity` wrapper, whose offscreen layer cost a recomposite per frame).
  final double opacity;

  const _AuroraPainter({
    required this.cyan,
    required this.violet,
    required this.magenta,
    this.opacity = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Base wash so the viewport is never fully transparent.
    final base = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          cyan.withValues(alpha: 0.05 * opacity),
          violet.withValues(alpha: 0.08 * opacity),
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
          color.withValues(alpha: 0.30 * intensity * opacity),
          color.withValues(alpha: 0.12 * intensity * opacity),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.cyan != cyan ||
      old.violet != violet ||
      old.magenta != magenta ||
      old.opacity != opacity;
}
