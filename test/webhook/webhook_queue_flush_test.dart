import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late Directory appDir;

File get queueFile => File('${appDir.path}/webhook_queue.json');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('vox_queue_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  group('flush — concurrence', () {
    test(
      'deux flush concurrents ne postent pas le même corps deux fois',
      () async {
        final inFlight = Completer<void>();
        final release = Completer<bool>();
        var posts = 0;
        final queue = WebhookQueue.forTest(
          postRaw: (body) {
            posts++;
            if (posts == 1) {
              inFlight.complete();
              return release.future;
            }
            return Future.value(true);
          },
        );
        addTearDown(queue.stop);

        await queue.add('{"event_id":"dup"}');
        final first = queue.flush(force: true);
        await inFlight.future;

        // Tick périodique (ou appui sur « Réessayer ») pendant l'envoi en vol.
        final second = await queue.flush(force: true);
        expect(
          posts,
          1,
          reason: 'le corps a été POSTé pendant un envoi déjà en cours',
        );
        expect(
          second,
          isFalse,
          reason: 'le flush ignoré doit le signaler à l\'appelant',
        );

        release.complete(true);
        await first;
        expect(queue.length, 0);
      },
    );

    test('un flush normal renvoie true', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => true);
      addTearDown(queue.stop);
      await queue.add('{"event_id":"a"}');
      expect(await queue.flush(force: true), isTrue);
    });
  });

  group('persistante sur disque', () {
    test('un échec survit à un redémarrage de l app', () async {
      final first = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(first.stop);
      await first.add('{"event_id":"keep"}');
      await first.flush(force: true);
      expect(first.length, 1);

      // même fichier, instance neuve : la file doit reprendre
      final restarted = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(restarted.stop);
      await restarted.flush(force: true);
      expect(restarted.length, 1);
    });

    test('une réussite retire le corps de la file et du fichier', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => true);
      addTearDown(queue.stop);
      await queue.add('{"event_id":"ok"}');
      await queue.flush(force: true);
      expect(queue.length, 0);
      expect(jsonDecode(queueFile.readAsStringSync()), isEmpty);
    });

    test('deux écritures concurrentes laissent un fichier valide', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      await Future.wait([
        queue.add('{"event_id":"a"}'),
        queue.add('{"event_id":"b"}'),
      ]);
      final decoded = jsonDecode(queueFile.readAsStringSync());
      expect(decoded, isA<List>());
      expect(decoded.length, 2);
    });

    test(
      'un fichier corrompu est préservé, jamais écrasé — et rien n est '
      'accepté tant que la sauvegarde est coupée (audit 557ca0bb, F3)',
      () async {
        queueFile.writeAsStringSync('ceci n est pas du json');
        final queue = WebhookQueue.forTest(postRaw: (_) async => false);
        addTearDown(queue.stop);
        expect(
          await queue.add('{"event_id":"new"}'),
          isFalse,
          reason:
              'add() ne promet plus une mise en file impossible : un '
              'vrai faux « en file » était la perte silencieuse',
        );
        await queue.flush(force: true);

        expect(
          queueFile.readAsStringSync(),
          'ceci n est pas du json',
          reason:
              'persister une file mémoire amputée perdrait les envois : '
              'l épave reste intacte jusqu au clear explicite',
        );
        expect(queue.saveDisabled, isTrue);
        expect(queue.length, 0);
      },
    );

    test('« vider maintenant » purge même un fichier illisible', () async {
      queueFile.writeAsStringSync('garbage');
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      await queue.add('{"event_id":"x"}');
      await queue.clear();
      // Le fichier illisible est remplacé par une file vide valide : l'user a
      // explicitement demandé la purge.
      expect(jsonDecode(queueFile.readAsStringSync()), isEmpty);
      expect(queue.length, 0);
    });

    test(
      'au-dela du budget, le nouvel entrant est rebuté, pas les anciens',
      () async {
        final queue = WebhookQueue.forTest(postRaw: (_) async => false);
        addTearDown(queue.stop);
        // 3 × 9 Mo > maxQueuedBytes : le troisième ne passe plus.
        // Politique « zéro éviction » (audit 8960c5cc) : c'est LUI qui est
        // refusé, les deux premiers restent, rien n'est purgé pour lui faire
        // de la place.
        final gros = 'x' * (9 * 1024 * 1024);
        expect(await queue.add(gros), isTrue);
        expect(await queue.add(gros), isTrue);
        expect(
          await queue.add(gros),
          isFalse,
          reason: 'au-dessus du budget global : rejet explicite',
        );
        expect(queue.length, 2);
        expect(queue.droppedCount, 1);
        expect(queue.lastRejectReason, contains('budget'));
        // Le fichier, lui, porte bien les deux survivants.
        final decoded = jsonDecode(queueFile.readAsStringSync());
        expect((decoded as List).length, 2);
      },
    );

    test('les orphelins .part d un crash sont purgés au chargement', () async {
      final orphelin = File('${appDir.path}/webhook_queue.json.part.123456');
      orphelin.writeAsStringSync('restes d un crash');
      final queue = WebhookQueue.forTest(postRaw: (_) async => true);
      addTearDown(queue.stop);
      await queue.add('{"event_id":"a"}');
      expect(
        orphelin.existsSync(),
        isFalse,
        reason: 'le fichier temporaire orphelin doit être nettoyé',
      );
    });

    test('la cadence de premier réessai est décalée, pas immédiate', () async {
      final queue = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(queue.stop);
      await queue.add('{"event_id":"later"}');
      await queue.flush(); // sans force : le backoff doit protéger le serveur
      expect(queue.length, 1);
    });
  });
}
