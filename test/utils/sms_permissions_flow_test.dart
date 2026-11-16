import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/launch_permissions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pilote le canal `eu.devlabz.vox/sms` : état des permissions + dernier
/// résultat de la demande système, avec comptage des dialogues affichés.
/// `rationale` simule l'état persistant du système : vrai = l'utilisateur a
/// refusé une fois et Android montrerait encore le dialogue ; faux = jamais
/// demandé ou refus permanent (« ne plus demander »).
class _FakeSmsChannel {
  _FakeSmsChannel({
    required this.granted,
    required this.grantedAfterRequest,
    this.rationale = false,
  });

  bool granted;

  /// Ce que renvoie la native une fois la demande soldée (résultat utilisateur).
  final bool grantedAfterRequest;
  final bool rationale;
  int requestCount = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('eu.devlabz.vox/sms'),
          (call) async => switch (call.method) {
            'hasSmsPermissions' => granted,
            'requestSmsPermissions' => _onRequest(),
            'shouldShowSmsPermissionRationale' => rationale,
            _ => null,
          },
        );
  }

  Future<bool> _onRequest() async {
    requestCount++;
    granted = grantedAfterRequest;
    return granted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    // Le store est statique : reset entre les tests pour repartir de zéro.
    await AppSettings.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('eu.devlabz.vox/sms'),
          null,
        );
  });

  group('shouldAskSmsPermissions — reprise après refus', () {
    test('jamais demandée -> on demande (premier lancement en mode SMS)', () {
      expect(
        shouldAskSmsPermissions(askedBefore: false, rationale: false),
        isTrue,
      );
    });

    test('refus simple (rationale) -> on redemande', () {
      expect(
        shouldAskSmsPermissions(askedBefore: true, rationale: true),
        isTrue,
      );
    });

    test('refus permanent (plus de rationale) -> on ne harcèle pas', () {
      expect(
        shouldAskSmsPermissions(askedBefore: true, rationale: false),
        isFalse,
      );
    });

    test('entrée volontaire (force) après process tué pendant le dialogue : '
        'on réévalue — asked=true + rationale faux est l\'état laissé par une '
        'interruption, pas la preuve d\'un refus permanent (audit F2)', () {
      expect(
        shouldAskSmsPermissions(
          askedBefore: true,
          rationale: false,
          force: true,
        ),
        isTrue,
      );
    });

    test('force ne change rien aux deux autres cas', () {
      expect(
        shouldAskSmsPermissions(
          askedBefore: false,
          rationale: false,
          force: false,
        ),
        isTrue,
      );
      expect(
        shouldAskSmsPermissions(
          askedBefore: true,
          rationale: true,
          force: false,
        ),
        isTrue,
      );
    });
  });

  group('ensureSmsPermissions — pilotage réel', () {
    test('hors mode SMS seul : aucune demande', () async {
      final fake = _FakeSmsChannel(granted: false, grantedAfterRequest: false)
        ..install();
      expect(await ensureSmsPermissions(), isFalse);
      expect(fake.requestCount, 0);
    });

    test(
      'mode SMS seul sans permissions : la demande part (audit '
      '2026-11-05 : morte par le drapeau one-shot au 1er lancement)',
      () async {
        await AppSettings.smsOnlyMode.setItem(true);
        final fake = _FakeSmsChannel(granted: false, grantedAfterRequest: true)
          ..install();
        expect(await ensureSmsPermissions(), isTrue);
        expect(fake.requestCount, 1);
        expect(AppSettings.smsPermissionsAsked.value, isTrue);
      },
    );

    test('permissions déjà accordées : pas de dialogue', () async {
      await AppSettings.smsOnlyMode.setItem(true);
      final fake = _FakeSmsChannel(granted: true, grantedAfterRequest: true)
        ..install();
      expect(await ensureSmsPermissions(), isTrue);
      expect(fake.requestCount, 0);
    });

    test('refus simple : le lancement suivant redemande', () async {
      await AppSettings.smsOnlyMode.setItem(true);
      final first = _FakeSmsChannel(granted: false, grantedAfterRequest: false)
        ..install();
      expect(await ensureSmsPermissions(), isFalse);
      expect(first.requestCount, 1);

      // Même état au lancement suivant (rôle non repris) : rationale=true,
      // on a le droit de re-solliciter.
      final second = _FakeSmsChannel(
        granted: false,
        grantedAfterRequest: true,
        rationale: true,
      )..install();
      expect(await ensureSmsPermissions(), isTrue);
      expect(second.requestCount, 1);
    });

    test('refus permanent : plus aucune relance (respect Android)', () async {
      await AppSettings.smsOnlyMode.setItem(true);
      final asked = _FakeSmsChannel(granted: false, grantedAfterRequest: false)
        ..install();
      await ensureSmsPermissions();
      expect(asked.requestCount, 1);
      expect(AppSettings.smsPermissionsAsked.value, isTrue);

      // L'utilisateur a coche « ne plus demander » : le natif ne signale plus
      // de rationale -> les lancements suivants ne relancent rien.
      final muted = _FakeSmsChannel(granted: false, grantedAfterRequest: false)
        ..install();
      expect(await ensureSmsPermissions(), isFalse);
      expect(muted.requestCount, 0);
    });

    test(
      'process tué pendant le dialogue (asked=true, rationale jamais '
      'réévaluée) : l\'entrée volontaire relance la demande (audit F2)',
      () async {
        await AppSettings.smsOnlyMode.setItem(true);
        // État laissé par l'interruption : drapeau posé avant la demande,
        // jamais soldée -> rationale pas évaluée (fausse côté fake).
        await AppSettings.smsPermissionsAsked.setItem(true);
        final fake = _FakeSmsChannel(granted: false, grantedAfterRequest: true)
          ..install();
        expect(await ensureSmsPermissions(userInitiated: true), isTrue);
        expect(fake.requestCount, 1);
      },
    );

    test('même état interrompu : le chemin lancement (non volontaire) ne '
        'relance pas de dialogue parasite', () async {
      await AppSettings.smsOnlyMode.setItem(true);
      await AppSettings.smsPermissionsAsked.setItem(true);
      final fake = _FakeSmsChannel(granted: false, grantedAfterRequest: false)
        ..install();
      expect(await ensureSmsPermissions(), isFalse);
      expect(fake.requestCount, 0);
    });
  });
}
