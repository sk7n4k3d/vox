import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Audit 2026-11-04 — F4 : http.post suivait les redirections ; un 302 pris
/// depuis le serveur d'en-face rejouait le corps ET l'en-tête signé HMAC vers
/// la cible du redirect. Ces tests tournent sur de vrais serveurs loopback :
/// ils prouvent que la cible du 302 ne reçoit RIEN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer front; // reçoit le POST, répond 302
  late HttpServer victim; // cible du 302 — doit rester silencieuse
  late List<String> frontHeaders;
  late List<String> victimHits;

  setUp(() async {
    // TestWidgetsFlutterBinding installe un HttpOverrides qui moque TOUT
    // HttpClient par un 400 sans socket. Ces tests exigent des vrais serveurs
    // loopback : on retire l'override pour la durée du fichier.
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    // ces tests montent de vrais serveurs loopback en http : l'envoi HTTPS-
    // only (audit 557ca0bb F9) est précisément la porte qu'ils exercent via
    // l'interrupteur LAN, activé ici comme un utilisateur le ferait.
    await AppSettings.webhookAllowInsecureHttp.setItem(true);
    // le secret vient du flutter_secure_storage : canal simulé
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'hmac-test-secret' : null,
        );

    frontHeaders = [];
    victimHits = [];
    victim = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    victim.listen((r) async {
      victimHits.add('${r.method} ${r.uri.path}');
      r.response.statusCode = 200;
      await r.response.close();
    });
    front = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    front.listen((r) async {
      if (r.uri.path == '/hook') {
        frontHeaders.add(r.headers.value('x-webhook-signature-v2') ?? '');
        await r.drain<void>();
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${victim.port}/steal',
        );
        await r.response.close();
        return;
      }
      r.response.statusCode = 200;
      await r.response.close();
    });
  });

  tearDown(() async {
    await front.close(force: true);
    await victim.close(force: true);
  });

  Future<void> configureUrl(String path) =>
      AppSettings.webhookUrl.setItem('http://127.0.0.1:${front.port}$path');

  test('un 302 ne rejoue ni le corps ni la signature vers la cible', () async {
    await configureUrl('/hook');
    final ok = await WebhookService.instance.postRaw('{"secret":"contenu"}');

    expect(
      ok,
      isFalse,
      reason: '3xx = échec: ${WebhookService.instance.stats.value.lastError}',
    );
    expect(
      frontHeaders.length,
      1,
      reason:
          'erreur envoyée: ${WebhookService.instance.stats.value.lastError}',
    );
    expect(
      frontHeaders.first,
      isNotEmpty,
      reason: 'le POST signé doit bien avoir porté la signature',
    );
    expect(
      victimHits,
      isEmpty,
      reason: 'la cible du redirect ne doit rien recevoir (corps ni en-tête)',
    );
  });

  test('un 200 direct reste un succès', () async {
    await configureUrl('/ok');
    expect(await WebhookService.instance.postRaw('{"a":1}'), isTrue);
    expect(victimHits, isEmpty);
  });
}
