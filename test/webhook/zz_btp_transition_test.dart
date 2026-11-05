// Contrats « fenêtre de transition de verrou » (revue ab0a82b4, HIGH).
//
// PROVENANCE : reprises des sondes blue-team BTP5/BTP6/BTP7c/BTP7d/BTP8
// écrites sur la copie d'audit. Le défaut : après la mort du pair, le premier
// add() déclenche la reprise du verrou ; la bascule `_lockedByPeer = false`
// était observable AVANT l'invalidation de la mémo de charge — un second
// appelant tenant la mémo périmée (la charge « en retrait », qui a tout rasé
// sans rien lire) obtenait la permission d'écrire et renommait sa table
// partielle par-dessus un fichier pas encore relu. Mesuré sur le dépôt avant
// le correctif, reproduction locale : hops=0 -> 10/10 pertes
// (`bodies=[transitionneur|sms]`), hops=1 -> 10/10 perte + doublon
// (`bodies=[victime|sms, victime|sms, transitionneur|sms]`) — identicalites
// avec la mesure de la revue (BTP10, dans son propre fichier).
//
// Le correctif a trois pièces, toutes nécessaires (mesure revue : la bascule
// atomique seule laisse 10/10 pertes) : flip + drapeau + invalidation +
// recharge dans le MÊME bloc synchrone ; attente du second appelant ; et
// garde sur le RENAME lui-même (`_writeSnapshot` refuse tant que la
// relecture n'est pas faite).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  File queueFile() => File('${appDir.path}/webhook_queue.json');
  File lockFile() => File('${appDir.path}/webhook_queue.json.lock');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    appDir = await Directory.systemTemp.createTemp('vox_btptr');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  Map<String, Object?> item(String body) => <String, Object?>{
    'raw_body': body,
    'created_at_ms': DateTime.now().millisecondsSinceEpoch,
    'attempts': 0,
    'next_attempt_at_ms': 0,
  };

  List<String> bodiesOnDisk() {
    final decoded = jsonDecode(queueFile().readAsStringSync()) as List;
    return decoded.map((e) => (e as Map)['raw_body'].toString()).toList();
  }

  Future<Process> startExternalHolder() async {
    const script =
        'import fcntl, sys, time\n'
        'fd = open(sys.argv[1], "a+")\n'
        'fcntl.lockf(fd, fcntl.LOCK_EX)\n'
        'print("LOCKED", flush = True)\n'
        'time.sleep(120)\n';
    final h = await Process.start('python3', ['-c', script, lockFile().path]);
    final first = await h.stdout.transform(const Utf8Decoder()).first;
    if (!first.contains('LOCKED')) throw StateError('preneur pas prêt');
    return h;
  }

  Future<void> freshSeed(List<String> bodies) async {
    if (queueFile().existsSync()) queueFile().deleteSync();
    queueFile().writeAsStringSync(jsonEncode(bodies.map(item).toList()));
  }

  test('BTP6 (échelle de microtasks, hops 0-2 x 15 essais) : le second add() '
      'arrivant APRÈS la bascule doit quand même attendre la recharge — '
      'jamais d écrasement ni de doublon', () async {
    for (final hops in [0, 1, 2]) {
      var dup = 0, loss = 0;
      for (var t = 0; t < 15; t++) {
        await freshSeed(['g|sms']);
        final holder = await startExternalHolder();
        final q = WebhookQueue.forTest(
          postRaw: (_) async => false,
          desktopLock: true,
        );
        await q.flush(force: true); // pair vivant -> en retrait
        holder.kill(ProcessSignal.sigkill);
        await holder.exitCode.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 5));

        unawaited(q.add('transitionneur|sms'));
        var victim = Future<void>.value();
        for (var k = 0; k < hops; k++) {
          victim = victim.then((_) => Future<void>.microtask(() {}));
        }
        await victim.then((_) => q.add('victime|sms'));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final bodies = bodiesOnDisk();
        if (bodies.toSet().length != bodies.length) dup++;
        if (!bodies.contains('g|sms') ||
            !bodies.contains('transitionneur|sms') ||
            !bodies.contains('victime|sms')) {
          loss++;
        }
        q.stop();
      }
      expect(dup, 0, reason: '$dup doublons à hops=$hops');
      expect(loss, 0, reason: '$loss pertes à hops=$hops');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('BTP5 (rafale 4 adds + 2 flush sur la reprise x 25 essais) : un seul '
      'transitionneur, zéro doublon persisté, zéro perte', () async {
    var sawDup = 0, sawLoss = 0;
    for (var t = 0; t < 25; t++) {
      await freshSeed(['graine|sms']);
      final holder = await startExternalHolder();
      final q = WebhookQueue.forTest(
        postRaw: (_) async => false,
        desktopLock: true,
      );
      await q.flush(force: true);
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await Future.wait<void>(<Future<void>>[
        q.add('a1|sms'),
        q.add('a2|sms'),
        q.add('a3|sms'),
        q.add('a4|sms'),
        q.flush(force: true),
        q.flush(force: true),
      ]);

      final bodies = bodiesOnDisk();
      if (bodies.toSet().length != bodies.length) sawDup++;
      for (final want in [
        'graine|sms',
        'a1|sms',
        'a2|sms',
        'a3|sms',
        'a4|sms',
      ]) {
        if (!bodies.contains(want)) {
          sawLoss++;
          break;
        }
      }
      q.stop();
    }
    expect(sawDup, 0, reason: '$sawDup/25 essais avec doublon persisté');
    expect(sawLoss, 0, reason: '$sawLoss/25 essais avec perte');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('BTP5b : redémarrage après la rafale = livraison EXACTEMENT une fois '
      'chacun (aucune double livraison héritée de doublons)', () async {
    await freshSeed(['graine|sms']);
    final holder = await startExternalHolder();
    final q = WebhookQueue.forTest(
      postRaw: (_) async => false,
      desktopLock: true,
    );
    await q.flush(force: true);
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await Future.wait<void>([q.add('a1|sms'), q.add('a2|sms')]);
    q.stop();

    final posted = <String>[];
    final reboot = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(reboot.stop);
    await reboot.flush(force: true);
    expect(
      posted.toSet().length,
      3,
      reason:
          'les trois corps, chacun une '
          'fois : $posted',
    );
    expect(posted.length, 3);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('BTP7c : panne qui tombe PENDANT la reprise du verrou — le verrou est '
      'pris mais la charge échoue : add refusé, fichier intact octet à octet, '
      'récupération au prochain appel (cas que X4d ne couvre pas : sa panne '
      'tombe sur une charge ordinaire)', () async {
    await freshSeed(['g|sms']);
    final pristine = queueFile().readAsBytesSync();
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
      desktopLock: true,
    );
    addTearDown(q.stop);
    final holder = await startExternalHolder();
    await q.flush(force: true); // pair vivant -> en retrait
    expect(q.saveDisabled, isTrue);

    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // la panne arme la recharge que la TRANSITION va lancer
    q.debugFailNextLoad();
    expect(
      await q.add('pendant-transition|sms'),
      isFalse,
      reason:
          'transition acquiert puis charge -> panne : add ne doit PAS '
          'promettre true sur une table vide/chargée à moitié',
    );
    expect(
      queueFile().readAsBytesSync(),
      equals(pristine),
      reason: 'fichier intact : rien n est écrit sur une charge inconnue',
    );
    expect(posted, isEmpty);

    // et la vie continue : l appel suivant recharge vraiment et écrit
    expect(await q.add('apres-reprise|sms'), isTrue, reason: 'récupération');
    expect(q.saveDisabled, isFalse);
    expect(
      bodiesOnDisk(),
      containsAll(<String>['g|sms', 'apres-reprise|sms']),
      reason: 'rien perdu de ce qui était sur le disque',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('BTP7d : épave + .part survivant sous le nouvel « inconnu » — la '
      'récupération garde sa parole (le garde ne doit pas bloquer l adoption '
      'ni la livraison)', () async {
    queueFile().writeAsStringSync('{ ceci n est pas du json');
    final part = File(
      '${queueFile().path}.part.99.${DateTime.now().microsecondsSinceEpoch}',
    )..writeAsStringSync(jsonEncode(<Object?>[item('part|sms')]));
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(
      posted,
      contains('part|sms'),
      reason: 'le .part décodable est adopté puis livré malgré l épave',
    );
    expect(q.saveDisabled, isFalse, reason: 'adoption = état connu');
    expect(part.existsSync(), isFalse, reason: '.part absorbé puis supprimé');
    expect(
      bodiesOnDisk(),
      isEmpty,
      reason: 'livré = retiré, pas de résurgence',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('BTP8 (contrôle positif) : recharge immobilisée sur un appel d I/O — '
      'tout appelant qui arrive PENDANT la recharge (mémo déjà installée) '
      'attend et ne peut rien écraser : la graine survit, le nouveau corps '
      'aussi, sans doublon', () async {
    await freshSeed(['g|sms']);
    final pristine = queueFile().readAsBytesSync();
    final holder = await startExternalHolder();
    final q = WebhookQueue.forTest(
      postRaw: (_) async => false,
      desktopLock: true,
    );
    addTearDown(q.stop);
    await q.flush(force: true); // en retrait
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final gate = Completer<String>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            calls++;
            if (calls == 2) return gate.future; // chemin de la recharge
            return appDir.path;
          },
        );
    try {
      unawaited(q.add('transitionneur|sms'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // la mémo de recharge est installée : ce second appelant attend
      // cette Future — on ne l'await PAS avant d'ouvrir la gate
      final arriving = q.add('arrivant|sms');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // et pendant tout ce temps, rien n a touché le fichier :
      expect(
        queueFile().readAsBytesSync(),
        equals(pristine),
        reason:
            'la table rasée en mémoire ne doit jamais atteindre le disque '
            'avant la lecture',
      );
      gate.complete(appDir.path);
      expect(
        await arriving,
        isTrue,
        reason:
            'l arrivant a été retenu, pas perdu : il écrit après la '
            'lecture',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } finally {
      if (!gate.isCompleted) gate.complete(appDir.path);
    }
    final bodies = bodiesOnDisk();
    expect(
      bodies,
      containsAll(<String>['g|sms', 'arrivant|sms']),
      reason: 'graine et arrivant coexistent : $bodies',
    );
    expect(bodies.toSet().length, bodies.length);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
