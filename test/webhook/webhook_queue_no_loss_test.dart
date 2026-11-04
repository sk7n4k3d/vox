// Audit 8960c5cc — politique « zéro perte silencieuse » de la file webhook :
// aucun élément existant n'est supprimé pour faire de la place ; ce qui ne
// tient pas est REFUSÉ avec motif + compteur observables ; le média nominal
// (16 MiB en base64) tient toujours ; le comptage est en vrais octets UTF-8 ;
// un item en vol n'est jamais perdu, même si l'échec tombe après un ajout
// concurrent ou un clear.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('vox_noloss');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  Future<List<Object?>> readQueueFile() async {
    final f = File('${appDir.path}/webhook_queue.json');
    if (!await f.exists()) return const [];
    return jsonDecode(await f.readAsString()) as List<Object?>;
  }

  test('média nominal 16 MiB en base64 : entre en file vide et survit au '
      'redémarrage', () async {
    // 16 777 216 o de binaire → 22 369 624 o de base64 : c'est LE corps
    // qu'Hermes accepte (maxWebhookMediaBytes). À l'ancien budget de 20 MiB
    // il était structurellement rejetable ; il doit désormais passer.
    final nominal = 'md|' + 'k' * (22369624 - 3);
    expect(utf8.encode(nominal).length, 22369624);
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    expect(await queue.add(nominal), isTrue);
    expect(queue.droppedCount, 0);
    // rechargement depuis le fichier : l'entrée est intégralement là
    final restarted = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(restarted.stop);
    final onDisk = await readQueueFile();
    expect(onDisk.length, 1);
    final body = (onDisk.single as Map)['raw_body'] as String;
    expect(body.length, nominal.length);
    expect(body, nominal);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('comptage en octets UTF-8 réels, pas en unités UTF-16', () async {
    // 12 058 624 × « é » = 24 117 248 OCTETS = exactement le plafond par
    // entrée ; un de plus déborde — alors que .length (unités UTF-16) des
    // deux corps reste bien sous le plafond. L'ancien comptage les aurait
    // laissés passer et la file aurait pesé ~2 × le budget sur disque.
    final exact = 'é' * (WebhookQueue.maxQueuedItemBytes ~/ 2);
    final over = 'é' * (WebhookQueue.maxQueuedItemBytes ~/ 2 + 1);
    expect(exact.length, lessThan(WebhookQueue.maxQueuedItemBytes));
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    expect(await queue.add(exact), isTrue,
        reason: 'pile au plafond en octets : accepté');
    expect(await queue.add(over), isFalse,
        reason: 'un caractère de trop en UTF-8 : refusé au total (budget) '
            'et au moins compté en vrais octets');
    expect(queue.droppedCount, 1);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('compteur d entrées saturé : le nouvel entrant est refusé, aucun '
      'ancien chassé', () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    for (var i = 0; i < WebhookQueue.maxItems; i++) {
      expect(await queue.add('{"event_id":"e$i"}'), isTrue);
    }
    expect(queue.length, WebhookQueue.maxItems);
    expect(await queue.add('{"event_id":"de trop"}'), isFalse);
    expect(queue.length, WebhookQueue.maxItems);
    expect(queue.lastRejectReason, contains('saturée'));
    // le tout premier corps est toujours sur disque, en tête
    final onDisk = await readQueueFile();
    expect((onDisk.first as Map)['raw_body'], '{"event_id":"e0"}');
    expect(queue.droppedCount, 1);
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('file héritée hors budget : purge AU CHARGEMENT, puis add sans '
      'éviction', () async {
    // 2 × 14 Mo > budget : la purge fronce une fois au chargement (plus
    // tard, ce n'est pas le premier add — même minuscule — qui déclenche
    // la perte).
    final raw = List.generate(2, (i) {
      return <String, Object?>{
        'raw_body': 'h$i|'.padRight(14 * 1024 * 1024, 'z'),
        'created_at_ms': 1,
        'attempts': 0,
        'next_attempt_at_ms': 0,
      };
    });
    File('${appDir.path}/webhook_queue.json').writeAsStringSync(
      jsonEncode(raw),
    );
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    final accepted = await queue.add('ne|petit');
    expect(accepted, isTrue);
    expect(queue.length, 2, reason: 'h1 survécu + le petit ; h0 purgé au '
        'chargement, compté, journalisé');
    expect(queue.droppedCount, 1);
    final onDisk = await readQueueFile();
    final heads = onDisk
        .cast<Map>()
        .map((m) => (m['raw_body'] as String).substring(0, 2))
        .toList(growable: false);
    expect(heads, ['h1', 'ne']);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('item en vol qui RÉUSSIT : retiré mémoire et disque, les ajouts '
      'concurrents intacts', () async {
    final gate = Completer<bool>();
    var posts = 0;
    final queue = WebhookQueue.forTest(postRaw: (body) {
      posts++;
      return gate.future;
    });
    addTearDown(queue.stop);
    await queue.add('{"event_id":"vol"}');
    final flushing = queue.flush(force: true);
    while (posts == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // ajout pendant l'envoi : coexiste, rien n'est chassé
    expect(await queue.add('{"event_id":"suite"}'), isTrue);
    gate.complete(true);
    await flushing;
    expect(queue.length, 1);
    final onDisk = await readQueueFile();
    expect((onDisk.single as Map)['raw_body'], '{"event_id":"suite"}');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('clear() pendant un envoi : un échec ultérieur ne ressuscite pas le '
      'corps', () async {
    final gate = Completer<bool>();
    var posts = 0;
    final queue = WebhookQueue.forTest(postRaw: (body) {
      posts++;
      return gate.future;
    });
    addTearDown(queue.stop);
    await queue.add('{"event_id":"fantome"}');
    final flushing = queue.flush(force: true);
    while (posts == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await queue.clear(); // demande explicite pendant l'envoi
    gate.complete(false); // l'échec tombe APRÈS le clear
    await flushing;
    expect(queue.length, 0, reason: 'le clear demandé par l user prime');
    expect(await readQueueFile(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('rejet observable côté service : compteur dropped + lastError de l UI',
      () async {
    final before = WebhookService.instance.stats.value.dropped;
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.add('x' * (WebhookQueue.maxQueuedItemBytes + 1));
    final stats = WebhookService.instance.stats.value;
    expect(stats.dropped, before + 1,
        reason: 'le rebut doit apparaître sur la page de réglages, pas '
            'seulement dans le journal debug');
    expect(stats.lastError, contains('plafond'));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
