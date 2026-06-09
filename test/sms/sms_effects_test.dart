import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/pages/sms_chat/sms_effects.dart';

void main() {
  group('smsScreenEffectFor', () {
    test('detects a festive emoji when effects are enabled', () {
      expect(smsScreenEffectFor('🎉', effectsEnabled: true), isNotNull);
    });
    test('returns null when effects are disabled (gate)', () {
      expect(smsScreenEffectFor('🎉', effectsEnabled: false), isNull);
    });
    test('returns null for a plain text message', () {
      expect(smsScreenEffectFor('salut ça va', effectsEnabled: true), isNull);
    });
    test('returns null for an empty body', () {
      expect(smsScreenEffectFor('', effectsEnabled: true), isNull);
    });
  });

  group('smsShouldJumbo', () {
    test('true for a lone animatable emoji without media', () {
      expect(smsShouldJumbo(body: '😀', hasMedia: false), isTrue);
    });
    test('false for plain text', () {
      expect(smsShouldJumbo(body: 'Bonjour tout le monde', hasMedia: false), isFalse);
    });
    test('false when the message carries media (MMS image)', () {
      expect(smsShouldJumbo(body: '😀', hasMedia: true), isFalse);
    });
  });
}
