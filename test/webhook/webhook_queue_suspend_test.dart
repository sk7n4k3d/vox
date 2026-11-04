// Mandat 2026-11-05 (audit 6c8a1439, finding HIGH) : TTL et plafond de
// tentatives ne doivent PLUS supprimer d'événements jamais envoyés. Ils
// SUSPENDENT : l'entrée reste en mémoire et sur le disque, marque
// « suspended », jamais re-POSTée, et ne sort de cet état que par
// resumeSuspended() (bouton « Reprendre ») ou clear() explicite.
// Ces tests verrouillent : suspension non destructive, persistance du
// drapeau au redémarrage, non-réexpédition, reprise, ordre relatif des
// réinscriptions après échecs multiples, préservation byte-à-byte des
// éléments invalides avec copie de secours.

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  File queueFile() => File('${appDir.path}/webhook_queue.json');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    appDir = await Directory.systemTemp.createTemp('vox_suspend');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  List<Object?> readQueueFile() =>
      (jsonDecode(queueFile().readAsStringSync()) as List).cast<Object?>();

  List<String> heads() => readQueueFile()
      .cast<Map>()
      .map((m) => (m['raw_body'] as String).substring(0, 2))
      .toList(growable: false);

  Map<String, Object?> diskEntry(String prefix) => readQueueFile()
      .cast<Map<String, Object?>>()
      .firstWhere((m) => (m['raw_body'] as String).startsWith(prefix));

  Map<String, Object?> seedItem(
    String prefix, {
    required int createdAtMs,
    int attempts = 0,
  }) => <String, Object?>{
    'raw_body': '$prefix|sms',
    'created_at_ms': createdAtMs,
    'attempts': attempts,
    'next_attempt_at_ms': 0,
  };

  group('expiration — suspendre, jamais détruire', () {
    test('TTL dépassée : l événement jamais envoyé RESTE en mémoire et sur '
        'le disque, marqué suspended, et n est plus posté', () async {
      final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
      queueFile().writeAsStringSync(
        jsonEncode([seedItem('vx', createdAtMs: aged)]),
      );
      var posts = 0;
      final queue = WebhookQueue.forTest(
        postRaw: (_) async {
          posts++;
          return false;
        },
      );
      addTearDown(queue.stop);

      await queue.flush(force: true); // exactement ce que fait le boot

      expect(posts, 0, reason: 'expiré = plus d envoi');
      expect(queue.length, 1, reason: 'mais PAS de suppression : suspendu');
      expect(queue.suspendedCount, 1);
      expect(diskEntry('vx')['suspended'], isTrue);
      expect(
        queueFile().readAsStringSync(),
        contains('vx|sms'),
        reason: 'le corps reste intégralement dans le fichier',
      );
      // et il n est plus jamais retenté, même aux passages suivants
      await queue.flush(force: true);
      expect(posts, 0);
    });

    test('plafond de tentatives : dernière tentative ratée SUSPEND au lieu '
        'de supprimer', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 4 tentatives déjà faites ; la 5e (plafond par défaut) doit suspendre.
      queueFile().writeAsStringSync(
        jsonEncode([seedItem('ab', createdAtMs: now, attempts: 4)]),
      );
      var posts = 0;
      final queue = WebhookQueue.forTest(
        postRaw: (_) async {
          posts++;
          return false;
        },
      );
      addTearDown(queue.stop);
      await queue.flush(force: true);

      expect(posts, 1, reason: 'la 5e tentative a bien eu lieu');
      expect(queue.length, 1);
      expect(queue.suspendedCount, 1);
      expect(diskEntry('ab')['suspended'], isTrue);
      expect(diskEntry('ab')['attempts'], 5);
    });

    test('le drapeau survit au redémarrage ; un fresh (non expiré) reste '
        'actif — migration : absent = actif', () async {
      final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
      final now = DateTime.now().millisecondsSinceEpoch;
      queueFile().writeAsStringSync(
        jsonEncode([
          seedItem('vx', createdAtMs: aged),
          seedItem('nf', createdAtMs: now),
        ]),
      );
      final first = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(first.stop);
      await first.flush(force: true);
      expect(first.suspendedCount, 1);
      expect(first.length, 2);

      // « redémarrage » : nouvelle instance sur le même fichier.
      var postsAfterBoot = 0;
      final restarted = WebhookQueue.forTest(
        postRaw: (_) async {
          postsAfterBoot++;
          return false;
        },
      );
      addTearDown(restarted.stop);
      await restarted.flush(force: true);
      expect(restarted.suspendedCount, 1);
      expect(
        restarted.length,
        2,
        reason: 'vx suspendu + nf échoué, rien de perdu au boot',
      );
      expect(
        postsAfterBoot,
        1,
        reason:
            'seul le frais est retenté ; le suspendu ne repart jamais '
            'sans reprise explicite',
      );
    });

    test(
      'resumeSuspended : remise en file, cycle neuf, puis envoi réussi',
      () async {
        final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
        queueFile().writeAsStringSync(
          jsonEncode([seedItem('vx', createdAtMs: aged)]),
        );
        final queue = WebhookQueue.forTest(postRaw: (_) async => false);
        addTearDown(queue.stop);
        await queue.flush(force: true);
        expect(queue.suspendedCount, 1);

        final resumed = await queue.resumeSuspended();
        expect(resumed, 1);
        expect(queue.suspendedCount, 0);
        expect(
          queue.length,
          1,
          reason:
              'toujours la même entrée, juste plus '
              'suspendue — pas de recréation',
        );
        expect(
          diskEntry('vx')['suspended'],
          isNot(true),
          reason:
              'le reset est persisté : pas de zombie suspendu après '
              'reprise',
        );
        // la reprise redonne un cycle complet (attempts remis à 0)
        expect((diskEntry('vx')['attempts'] as num).toInt(), 0);

        final online = WebhookQueue.forTest(postRaw: (_) async => true);
        addTearDown(online.stop);
        await online.flush(force: true);
        expect(online.length, 0, reason: 'envoyé : seule voie de disparition');
      },
    );

    test('service : la suspension est comptée, pas un rejet d ajout', () async {
      final before = WebhookService.instance.stats.value;
      final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
      queueFile().writeAsStringSync(
        jsonEncode([seedItem('vx', createdAtMs: aged)]),
      );
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      await queue.flush(force: true);
      final after = WebhookService.instance.stats.value;
      expect(
        after.suspended,
        before.suspended + 1,
        reason:
            'la page Réglages voit la suspension (« en suspens ») — '
            'compteur séparé de rebuté',
      );
      expect(
        after.dropped,
        before.dropped,
        reason: 'dropped ne compte QUE les refus d ajout depuis ce commit',
      );
    });
  });

  group('ordre et intégrité', () {
    test('plusieurs échecs d une même passe : ordre relatif conservé '
        '(verrouille requeuedAtHead)', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      for (final t in ['aa', 'bb', 'cc']) {
        await queue.add('$t|msg');
      }
      await queue.flush(force: true);
      expect(queue.length, 3);
      expect(
        heads(),
        ['aa', 'bb', 'cc'],
        reason:
            'la passe précédente inversait l ordre (insert(0) '
            'répété) — rien dans un FIFO ne doit changer d ordre sans envoi',
      );
    });

    test('redémarrage après échecs multiples : l ordre repris sur disque '
        'est le même', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      for (final t in ['x1', 'x2', 'x3']) {
        await queue.add('$t|msg');
      }
      await queue.flush(force: true);
      final onDisk = heads();

      final restarted = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(restarted.stop);
      await restarted.flush(force: true);
      expect(
        heads(),
        onDisk,
        reason:
            'le FIFO lu du disque doit retrouver le même ordre, sinon '
            'un SMS peut partir avant un SMS plus ancien',
      );
      expect(heads(), ['x1', 'x2', 'x3']);
    });
  });

  group('corruption partielle : préserver, pas réparer', () {
    test('éléments invalides : conservés byte-à-byte, copie de secours, '
        'valides traités normalement', () async {
      final initial = jsonEncode(<Object?>[
        seedItem('ok', createdAtMs: DateTime.now().millisecondsSinceEpoch),
        42,
        <String, Object?>{'attempts': 1},
        'pas un objet',
      ]);
      queueFile().writeAsStringSync(initial);
      final queue = WebhookQueue.forTest(postRaw: (_) async => true);
      addTearDown(queue.stop);
      await queue.flush(force: true);

      final after = readQueueFile();
      expect(
        after,
        containsAll(<Object>[42, 'pas un objet']),
        reason:
            'la corruption externe est réécrite TELLE QUELLE : la file '
            'ne supprime ni n invente ce qu elle ne lit pas',
      );
      expect(
        after.where((e) => e is Map).map((e) => (e as Map)['attempts']),
        contains(1),
        reason: 'le JSON valide mais incomplet est lui aussi préservé',
      );
      expect(queue.length, 3);
      expect(queue.invalidCount, 3);

      final backups = appDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrompu.'))
          .toList();
      expect(
        backups.length,
        1,
        reason:
            'copie de secours des octets d origine avant le premier '
            'réencodage',
      );
      expect(
        backups.single.readAsStringSync(),
        initial,
        reason:
            'la copie porte l état EXACT d avant, pas une '
            'reconstruction',
      );
    });

    test('corruption : un fichier déjà corrompu n est jamais le siége d une '
        'perte au deuxième réencodage (backup unique)', () async {
      queueFile().writeAsStringSync(jsonEncode([42]));
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      await queue.add('ne|ajout'); // persist déclenche backup + réencodé
      await queue.add('de|second'); // second persist : pas de 2e backup
      final backups = appDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrompu.'))
          .toList();
      expect(backups.length, 1);
      expect(queue.length, 3, reason: 'le 42 est toujours là, en tête');
      expect(readQueueFile().first, 42);
    });

    test(
      'corruption partielle : le compteur corrupt est séparé des rejets',
      () async {
        final before = WebhookService.instance.stats.value;
        queueFile().writeAsStringSync(jsonEncode([42]));
        final queue = WebhookQueue.forTest(postRaw: (_) async => false);
        addTearDown(queue.stop);
        await queue.clear(); // déclenche le chargement
        expect(WebhookService.instance.stats.value.corrupt, before.corrupt + 1);
      },
    );
  });
}
