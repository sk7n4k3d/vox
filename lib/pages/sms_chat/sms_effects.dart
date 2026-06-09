import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect_detector.dart';
import 'package:fluffychat/widgets/cyber/animated_emoji_text.dart';

/// Effet plein écran à jouer pour le corps [body] d'un message SMS, ou null.
/// Respecte le réglage commun [effectsEnabled] (= AppSettings.screenEffectsEnabled),
/// puis délègue la détection emoji/mot-clé au détecteur partagé avec Matrix.
ScreenEffect? smsScreenEffectFor(String body, {required bool effectsEnabled}) {
  if (!effectsEnabled) return null;
  return ScreenEffectDetector.detect(body);
}

/// Vrai si la bulle SMS doit rendre le corps en gros emoji animé (jumbomoji) :
/// le message ne porte aucun média ET son corps est 1-3 emojis animables.
/// Même critère que le chemin Matrix (AnimatedEmojiText.hasAnimatable).
bool smsShouldJumbo({required String body, required bool hasMedia}) {
  if (hasMedia) return false;
  if (body.isEmpty) return false;
  return AnimatedEmojiText.hasAnimatable(body);
}
