// Sonde blue-team : budget octets de la file webhook (fix F3, commit 44a9f683).
// Cas limite réel : maxWebhookMediaBytes = 16 Mo de média → corps base64 ≈
// 21.3 Mo > maxQueuedBytes = 20 Mo. Si un tel corps entre en file (échec
// d'envoi, Hermes muet), l'éviction FIFO vide TOUT, y compris les messages
// antérieurs qui tenaient dans le budget.

import 'dart:io';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('vox_wipe_probe');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('un corps > budget ne doit PAS vider les entrées antérieures',
      () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    // 1 Mo × 5 = 5 Mo en file : largement sous le budget.
    for (var i = 0; i < 5; i++) {
      await queue.add('${'m$i|'.padRight(1024 * 1024, 'x')}');
    }
    expect(queue.length, 5);
    // Puis un message média 21 Mo (rejeté par Hermes hors-ligne → enqueue).
    final oversized = 'video|' + 'B' * (21 * 1024 * 1024);
    await queue.add(oversized);
    // Attendu par conception raisonnable : soit l'oversized est seul gardé
    // (les anciens chassés pour lui faire place), soit il est rejeté et les
    // 5 anciens survivent. L'inacceptable : tout perdre.
    // ignore: avoid_print
    print('length apres oversized = ${queue.length}');
    expect(queue.length, greaterThan(0),
        reason: 'la file ne doit pas finir intégralement vidée : '
            'perte sèche des messages non envoyés');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
