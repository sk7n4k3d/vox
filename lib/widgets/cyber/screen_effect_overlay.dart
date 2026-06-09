import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/widgets/cyber/burning_overlay.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:lottie/lottie.dart';

/// Joue les effets plein écran avec throttle, unicité et respect du reduce-motion.
/// Retourne true si l'effet a été lancé, false s'il a été ignoré (throttle /
/// déjà actif / animations désactivées). Non-widget : un par ChatController.
class ScreenEffectController {
  final Duration throttle;
  DateTime? _lastPlayed;
  OverlayEntry? _activeEntry;
  AnimationController? _activeAnim;

  ScreenEffectController({this.throttle = const Duration(seconds: 3)});

  bool play(BuildContext context, ScreenEffect effect) {
    if (MediaQuery.of(context).disableAnimations) return false;
    if (_activeEntry != null) return false;
    final now = DateTime.now();
    if (_lastPlayed != null && now.difference(_lastPlayed!) < throttle) {
      return false;
    }
    _lastPlayed = now;

    if (effect.render == ScreenEffectRender.particles) {
      final cyber = CyberColors.of(context);
      // « Grande fête » = bien plus de particules, large dispersion.
      final isParty = effect == ScreenEffect.party;
      Confetti.launch(
        context,
        options: ConfettiOptions(
          particleCount: isParty ? 200 : 80,
          spread: isParty ? 160 : 70,
          startVelocity: isParty ? 55 : 45,
          y: 0.6,
          colors: isParty
              ? [
                  cyber.cyan,
                  cyber.magenta,
                  cyber.violet,
                  const Color(0xFFFFE066),
                  Colors.white,
                ]
              : [cyber.cyan, cyber.magenta, Colors.white],
        ),
      );
      return true;
    }

    if (effect.render == ScreenEffectRender.rainfall) {
      // Pluie : fines gouttes bleutées lâchées du haut, chute rapide et droite.
      Confetti.launch(
        context,
        options: const ConfettiOptions(
          particleCount: 200,
          angle: 270,
          spread: 30,
          startVelocity: 45,
          gravity: 1.2,
          drift: 0.2,
          decay: 1.0,
          ticks: 400,
          scalar: 0.6,
          x: 0.5,
          y: 0,
          flat: true,
          colors: [Color(0xFF4FA8FF), Color(0xFF7FC4FF), Color(0xFFBFE3FF)],
        ),
      );
      return true;
    }

    if (effect.render == ScreenEffectRender.sparkle) {
      // Paillettes : éclats dorés/cyan qui jaillissent du centre et scintillent.
      final cyber = CyberColors.of(context);
      Confetti.launch(
        context,
        options: ConfettiOptions(
          particleCount: 120,
          spread: 360, // toutes directions
          startVelocity: 28,
          gravity: 0.3,
          decay: 0.92,
          ticks: 300,
          scalar: 0.8,
          y: 0.45,
          colors: [
            const Color(0xFFFFE066),
            const Color(0xFFFFD700),
            cyber.cyan,
            Colors.white,
          ],
        ),
      );
      return true;
    }

    if (effect.render == ScreenEffectRender.snowfall) {
      // Vraie neige plein écran : des flocons lâchés depuis le haut, sur toute
      // la largeur, qui tombent doucement (gravité faible + drift latéral).
      Confetti.launch(
        context,
        options: const ConfettiOptions(
          particleCount: 140,
          angle: 270, // vers le bas
          spread: 120,
          startVelocity: 16,
          gravity: 0.25,
          drift: 1.2,
          decay: 1.0,
          ticks: 600, // dure longtemps (chute lente jusqu'en bas)
          x: 0.5,
          y: 0, // depuis le haut de l'écran
          flat: true,
          colors: [Colors.white, Color(0xFFB3ECFF), Color(0xFFE0F7FF)],
        ),
      );
      return true;
    }

    if (effect.render == ScreenEffectRender.burning) {
      // « L'app prend feu » : flammes montantes + lueur, overlay custom.
      final overlay = Overlay.of(context, rootOverlay: true);
      final entry = OverlayEntry(
        builder: (_) => IgnorePointer(
          child: BurningOverlay(onDone: _clearActive),
        ),
      );
      _activeEntry = entry;
      overlay.insert(entry);
      return true;
    }

    // Lottie plein écran en overlay, IgnorePointer, auto-dismiss.
    final overlay = Overlay.of(context, rootOverlay: true);
    final anim = AnimationController(vsync: overlay);
    _activeAnim = anim;
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: SizedBox.expand(
          child: Lottie.asset(
            effect.assetPath,
            controller: anim,
            // contain + centré : l'animation entière reste visible et centrée,
            // quel que soit son ratio (carré, portrait, paysage). cover zoomait
            // les anims carrées (feu, feux d'artifice) jusqu'à les faire sortir
            // de l'écran sur un format portrait.
            fit: BoxFit.contain,
            alignment: Alignment.center,
            onLoaded: (composition) {
              anim
                ..duration = composition.duration
                ..forward().whenComplete(_clearActive);
            },
            errorBuilder: (errorContext, error, stack) {
              // Asset manquant/corrompu : on annule proprement après ce frame.
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _clearActive());
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
    return true;
  }

  void _clearActive() {
    _activeEntry?.remove();
    _activeEntry = null;
    _activeAnim?.dispose();
    _activeAnim = null;
  }

  void dispose() => _clearActive();
}

/// Bottom-sheet de choix manuel : tape un effet → insère son emoji déclencheur
/// dans le composer (détection locale → l'effet se joue chez les deux).
Future<ScreenEffect?> showScreenEffectPicker(BuildContext context) {
  return showModalBottomSheet<ScreenEffect>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final e in ScreenEffect.values)
              InkWell(
                key: ValueKey('effect_${e.name}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).pop(e);
                },
                child: Container(
                  width: 92,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(e.emoji, style: const TextStyle(fontSize: 28)),
                      const SizedBox(height: 6),
                      Text(
                        e.label,
                        style: Theme.of(context).textTheme.labelSmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
