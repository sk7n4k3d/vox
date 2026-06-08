import 'package:fluffychat/utils/screen_effects/screen_effect.dart';

/// Détecte un effet plein écran à partir du corps d'un message. Ne déclenche que
/// si le message EST exactement un emoji festif ou un mot-clé connu (rien autour).
/// Fonction pure → testable sans Flutter.
abstract class ScreenEffectDetector {
  static const Map<String, ScreenEffect> _byEmoji = {
    '🎉': ScreenEffect.confetti,
    '🎊': ScreenEffect.confetti,
    '🎂': ScreenEffect.balloons,
    '🎈': ScreenEffect.balloons,
    '🎆': ScreenEffect.fireworks,
    '🎇': ScreenEffect.fireworks,
    '❤️': ScreenEffect.hearts,
    '😍': ScreenEffect.hearts,
    '🥰': ScreenEffect.hearts,
    '❄️': ScreenEffect.snow,
    '🎄': ScreenEffect.snow,
    '☃️': ScreenEffect.snow,
    '🥳': ScreenEffect.celebration,
    '🍾': ScreenEffect.celebration,
    '🥂': ScreenEffect.celebration,
    '🔥': ScreenEffect.fire,
    '💪': ScreenEffect.fire,
  };

  static const Map<String, ScreenEffect> _byKeyword = {
    'joyeux anniversaire': ScreenEffect.balloons,
    'happy birthday': ScreenEffect.balloons,
    'félicitations': ScreenEffect.confetti,
    'felicitations': ScreenEffect.confetti,
    'bravo': ScreenEffect.confetti,
    'congratulations': ScreenEffect.confetti,
    'bonne année': ScreenEffect.fireworks,
    'bonne annee': ScreenEffect.fireworks,
    'happy new year': ScreenEffect.fireworks,
    "je t'aime": ScreenEffect.hearts,
    'i love you': ScreenEffect.hearts,
    'joyeux noël': ScreenEffect.snow,
    'joyeux noel': ScreenEffect.snow,
    'merry christmas': ScreenEffect.snow,
    'ça déchire': ScreenEffect.fire,
    'ca dechire': ScreenEffect.fire,
    'tu gères': ScreenEffect.fire,
    'santé': ScreenEffect.celebration,
    'cheers': ScreenEffect.celebration,
  };

  static ScreenEffect? detect(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    // Emoji seul (exactement le cluster, espaces déjà retirés).
    final emoji = _byEmoji[trimmed];
    if (emoji != null) return emoji;
    // Mot-clé seul (insensible à la casse).
    return _byKeyword[trimmed.toLowerCase()];
  }
}
