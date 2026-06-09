import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect_detector.dart';

void main() {
  test('emoji festif seul → effet', () {
    expect(ScreenEffectDetector.detect('🎉'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('🎂'), ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('🎆'), ScreenEffect.fireworks);
    expect(ScreenEffectDetector.detect('❤️'), ScreenEffect.hearts);
    expect(ScreenEffectDetector.detect('❄️'), ScreenEffect.snow);
    expect(ScreenEffectDetector.detect('🥳'), ScreenEffect.celebration);
    expect(ScreenEffectDetector.detect('🔥'), ScreenEffect.fire);
    expect(ScreenEffectDetector.detect('🌧️'), ScreenEffect.rain);
    expect(ScreenEffectDetector.detect('✨'), ScreenEffect.sparkle);
    expect(ScreenEffectDetector.detect('💋'), ScreenEffect.kiss);
    expect(ScreenEffectDetector.detect('🎁'), ScreenEffect.party);
  });

  test('emoji entouré d\'espaces toléré', () {
    expect(ScreenEffectDetector.detect('  🎉 '), ScreenEffect.confetti);
  });

  test('mot-clé FR/EN seul → effet', () {
    expect(ScreenEffectDetector.detect('Joyeux anniversaire'),
        ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('happy birthday'),
        ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('Félicitations'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('BRAVO'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('Bonne année'), ScreenEffect.fireworks);
  });

  test('texte autour du trigger → null', () {
    expect(ScreenEffectDetector.detect('bravo à tous'), isNull);
    expect(ScreenEffectDetector.detect('regarde 🎉 ce truc'), isNull);
  });

  test('contenu non festif → null', () {
    expect(ScreenEffectDetector.detect('bonjour'), isNull);
    expect(ScreenEffectDetector.detect('😀'), isNull);
    expect(ScreenEffectDetector.detect(''), isNull);
  });
}
