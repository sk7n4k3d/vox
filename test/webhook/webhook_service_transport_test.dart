// Audit 557ca0bb — transport et signature : F9 (http:// partait en clair
// sans TLS) et F10 (panne Keystore → envois NON SIGNÉS silencieux). Contrat
// désormais : HTTPS requis sauf interrupteur LAN explicite ; panne de secret
// = envoi refusé et compté, pas envoi nu.

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:fluffychat/utils/webhook/webhook_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  Future<void> configure(String url) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    await AppSettings.webhookUrl.setItem(url);
  }

  void mockSecret(String? Function(MethodCall call) read) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => read(call));
  }

  setUp(() {
    WebhookService.instance.httpClientFactory = _EchoClient.new;
  });

  group('F9 — transport', () {
    test('http:// est refusé par défaut : rien ne part en clair', () async {
      await configure('http://hermes.lan:8080/hook');
      mockSecret((call) => 'secret');
      final before = WebhookService.instance.stats.value.failed;
      final ok = await WebhookService.instance.postRaw('{"a":1}');
      expect(ok, isFalse);
      expect(
        WebhookService.instance.stats.value.failed,
        before + 1,
        reason: 'le refus est compté, pas silencieux',
      );
      expect(WebhookService.instance.stats.value.lastError, contains('http'));
      expect(
        _EchoClient.sent,
        isEmpty,
        reason: 'aucune requête ne doit quitter l\'appareil',
      );
    });

    test('l\'interrupteur LAN autorise http:// explicitement', () async {
      await configure('http://hermes.lan:8080/hook');
      await AppSettings.webhookAllowInsecureHttp.setItem(true);
      mockSecret((call) => 'secret');
      expect(await WebhookService.instance.postRaw('{"a":1}'), isTrue);
      expect(
        _EchoClient.sent.single.url.scheme,
        'http',
        reason:
            'la configuration existante en http + interrupteur reste '
            'fonctionnelle : rien ne casse sans geste explicite',
      );
    });

    test(
      'https:// et les autres schémas : https passe, ftp/file refusés',
      () async {
        mockSecret((call) => 'secret');
        await configure('https://hermes.example/hook');
        expect(await WebhookService.instance.postRaw('{"a":1}'), isTrue);
        await configure('file:///tmp/exfil.json');
        expect(await WebhookService.instance.postRaw('{"a":2}'), isFalse);
        await configure('ftp://hermes.example/hook');
        expect(await WebhookService.instance.postRaw('{"a":3}'), isFalse);
      },
    );
  });

  group('F10 — secret', () {
    test('panne secure storage : envoi REFUSÉ et compté, jamais nu', () async {
      await configure('https://hermes.example/hook');
      _EchoClient.sent.clear();
      mockSecret((call) {
        if (call.method == 'read') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      final before = WebhookService.instance.stats.value.failed;
      final ok = await WebhookService.instance.postRaw('{"a":1}');
      expect(
        ok,
        isFalse,
        reason:
            'sans secret lisible, mieux vaut un envoi refusé et '
            'ré-essayable qu\'un envoi non signé falsifiable',
      );
      expect(_EchoClient.sent, isEmpty);
      expect(WebhookService.instance.stats.value.failed, before + 1);
      expect(
        WebhookService.instance.stats.value.lastError,
        contains('secure storage'),
      );
    });

    test(
      'secret vide choisi (pas de panne) : envoi non signé autorisé',
      () async {
        await configure('https://hermes.example/hook');
        _EchoClient.sent.clear();
        mockSecret((call) => null); // lu, absent : choix explicite de l\'user
        expect(await WebhookService.instance.postRaw('{"a":1}'), isTrue);
        expect(
          _EchoClient.sent.single.headers['x-webhook-signature-v2'],
          isNull,
        );
      },
    );
  });

  group('loadSecretOrFailure', () {
    test('null = panne, string = valeur (vide compris)', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      mockSecret((call) {
        if (call.method == 'read') throw PlatformException(code: 'boom');
        return null;
      });
      expect(await WebhookStore.instance.loadSecretOrFailure(), isNull);
      mockSecret((call) => '');
      expect(await WebhookStore.instance.loadSecretOrFailure(), '');
      // la vue ancienne (loadSecret) ne casse pas : panne vaut champ vide
      mockSecret((call) {
        if (call.method == 'read') throw PlatformException(code: 'boom');
        return null;
      });
      expect(await WebhookStore.instance.loadSecret(), '');
    });
  });
}

class _EchoClient extends http.BaseClient {
  static final sent = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    return http.StreamedResponse(Stream.value(<int>[]), 200);
  }

  @override
  void close() {}
}
