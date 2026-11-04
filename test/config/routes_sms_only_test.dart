import 'package:fluffychat/config/routes.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('chatAccessible — porte du router', () {
    test('sans compte et sans mode SMS : le salon reste verrouillé', () {
      expect(
        AppRoutes.chatAccessible(loggedIn: false, smsOnly: false),
        isFalse,
      );
    });

    test('compte connecté : accès, mode SMS ou non', () {
      expect(AppRoutes.chatAccessible(loggedIn: true, smsOnly: false), isTrue);
      expect(AppRoutes.chatAccessible(loggedIn: true, smsOnly: true), isTrue);
    });

    test('mode SMS/MMS seul : accès sans compte Matrix', () {
      expect(AppRoutes.chatAccessible(loggedIn: false, smsOnly: true), isTrue);
    });
  });

  group('réglage smsOnlyMode — contract de compatibilité', () {
    test('la clé de stockage est figée (ne pas renommer : préférences '
        'existantes)', () {
      expect(AppSettings.smsOnlyMode.key, 'chat.fluffy.sms_only_mode');
    });

    test(
      'défaut false : aucune surprise pour les installations existantes',
      () async {
        SharedPreferences.setMockInitialValues({});
        await AppSettings.init();
        expect(AppSettings.smsOnlyMode.value, isFalse);
      },
    );

    test('aller-retour du drapeau', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      await AppSettings.smsOnlyMode.setItem(true);
      expect(AppSettings.smsOnlyMode.value, isTrue);
      await AppSettings.smsOnlyMode.setItem(false);
      expect(AppSettings.smsOnlyMode.value, isFalse);
    });
  });
}
