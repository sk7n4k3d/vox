import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bouton rond détaché à droite de la composer. Avec du texte → bouton SEND
/// (avion, glow cyan→magenta, morph spring). Sans texte → délègue au slot micro
/// fourni par [micBuilder] (le VoiceRecordButton existant, geste inchangé).
class MorphingSendButton extends StatelessWidget {
  final bool hasText;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onSend;
  final VoidCallback onScheduleSend;
  final WidgetBuilder micBuilder;

  const MorphingSendButton({
    required this.hasText,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onSend,
    required this.onScheduleSend,
    required this.micBuilder,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber =
        Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    return SizedBox(
      width: 48,
      height: 48,
      child: AnimatedSwitcher(
        duration: FluffyDurations.fast,
        switchInCurve: FluffyCurves.decelerated,
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: hasText
            ? GestureDetector(
                key: const ValueKey('send'),
                onLongPress: onScheduleSend,
                child: Material(
                  key: const Key('morph_send_button'),
                  color: Colors.transparent,
                  child: InkResponse(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSend();
                    },
                    radius: 26,
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [cyber.cyan, cyber.magenta],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: cyber.cyan.withValues(alpha: 0.45),
                            blurRadius: 16,
                          ),
                        ],
                      ),
                      child: Icon(Icons.send_rounded, color: foregroundColor),
                    ),
                  ),
                ),
              )
            : KeyedSubtree(
                key: const ValueKey('mic'),
                child: micBuilder(context),
              ),
      ),
    );
  }
}
