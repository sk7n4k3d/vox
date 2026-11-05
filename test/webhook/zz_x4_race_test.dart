// Sonde X4 (revue 3f5a8f1d, item au risque le plus élevé), version dépôt.
//
// PROVENANCE : la sonde originale (et ma première copie sur HEAD) démontrait
// la récours de première lecture — un add() concurrent du chargement
// persistait AVANT la lecture et écrasait le fichier : reproduit
// déterministement ici avec le mock path_provider qui immobilise le premier
// appel sur un Completer (mesuré sur 3f5a8f1d : onDisk=[pendant|sms,
// pendant|sms], avant1/avant2 perdus sans jamais passer en mémoire). Ce
// fichier asserte désormais la garantie inverse : la charge est une Future
// partagée que tout entrant attend.

import 'dart:async';
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
    appDir = await Directory.systemTemp.createTemp('vox_x4');
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

  test('X4 (contrat) : add() pendant la première lecture attend la fin du '
      'chargement — jamais de persist avant que le fichier ait été lu '
      '(gâchette : premier appel de chemin bloqué sur un Completer)', () async {
    final gate = Completer<String>();
    var first = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (first) {
              first = false;
              return gate.future; // premier appel : chargé immobilisé
            }
            return appDir.path;
          },
        );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(appDir.path);
    });
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('avant1|sms'), item('avant2|sms')]),
    );

    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    final load = q.flush(force: true); // chargement bloqué en vol
    await Future<void>.delayed(Duration.zero);
    var addDone = false;
    final second = q.add('pendant|sms').then((v) {
      addDone = true;
      return v;
    });
    // fenêtre de course : si add pouvait écrire maintenant, le fichier
    // serait déjà [pendant] seul — dans le code corrigé, add attend sa
    // propre Future de chargement et ne peut pas aboutir
    for (var i = 0; i < 40 && !addDone; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final current = queueFile().readAsStringSync();
      if (!current.contains('avant1')) {
        fail('fichier écrasé pendant la lecture : ${bodiesOnDisk()}');
      }
    }
    gate.complete(appDir.path);
    await load;
    expect(await second, isTrue);

    final bodies = bodiesOnDisk();
    expect(
      bodies,
      containsAll(<String>['avant1|sms', 'avant2|sms']),
      reason:
          'les événements de la session précédente survivent à la '
          'course (l original mesurait onDisk=[pendant|sms])',
    );
    expect(bodies, contains('pendant|sms'));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('X4b (contrat) : écritures simultanées — trois add() en Future.wait sur '
      'une file portant déjà un événement : un seul chargement, fichier = '
      'union, et livraison exactement une fois après redémarrage', () async {
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('graine|sms')]));
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    final results = await Future.wait([
      q.add('a|sms'),
      q.add('b|sms'),
      q.add('c|sms'),
    ]);
    expect(results, [true, true, true]);
    expect(
      bodiesOnDisk(),
      containsAll(<String>['graine|sms', 'a|sms', 'b|sms', 'c|sms']),
      reason:
          'aucun persist concurrent ne peut partir d une mémoire '
          'préchargement — la charge est partagée',
    );
    expect(q.length, 4);
    q.stop();

    // redémarrage : tout part, exactement une fois chacun
    final posted = <String>[];
    final reboot = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(reboot.stop);
    await reboot.flush(force: true);
    expect(posted.toSet().length, 4);
    expect(
      posted.length,
      4,
      reason:
          'pas de doublon : la mémoire unique '
          'a été rechargée depuis le fichier une seule fois',
    );
    expect(bodiesOnDisk(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test(
    'X4c (borne) : panne de chargement inattendue ne pas mémoïsée — le '
    'prochain appel retente (un seul échec ne doit pas empoisonner la file)',
    () async {
      queueFile().writeAsStringSync(jsonEncode(<Object?>[item('vivant|sms')]));
      final q = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(q.stop);
      expect(await q.add('u|sms'), isTrue);
      // deuxième add : charge déjà faite (future complétée), pas de replay
      expect(await q.add('u2|sms'), isTrue);
      expect(q.length, 3);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('MULTIBOOT (contrat) : échec d envoi -> retry aux boots suivants, puis '
      'livraison exactement une fois, plus de résurgence au 4e boot '
      '(mandat « conserver retry après échec et synchronisation »)', () async {
    final posted = <String>[];
    // boot 1 : ajout
    final q1 = WebhookQueue.forTest(postRaw: (_) async => false);
    expect(await q1.add('tardif|sms'), isTrue);
    q1.stop();
    // boot 2 : envoi échoue — l événement reste et le fichier est synchrone
    final q2 = WebhookQueue.forTest(postRaw: (_) async => false);
    await q2.flush(force: true);
    q2.stop();
    expect(jsonDecode(queueFile().readAsStringSync()), hasLength(1));
    // boot 3 : ça passe — livré une fois
    final q3 = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    await q3.flush(force: true);
    q3.stop();
    expect(posted, ['tardif|sms']);
    // boot 4 : rien de résiduel
    final q4 = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    await q4.flush(force: true);
    q4.stop();
    expect(
      posted,
      ['tardif|sms'],
      reason:
          'aucune double livraison ni '
          'clou après succès — la consolidation est écrite et vérifiée',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('STALE-TRONQUÉ (contrat, cas documenté revue 3f5a8f1d) : un .part '
      'tronqué marqué « ancien » par le watermark est ARCHIVÉ, pas supprimé '
      'sec — seul le décodable prouvé consolidé disparaît sans copie '
      '(l original mesurait corruptCount=0, zéro trace restante)', () async {
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('vivant|sms')]));
    File('${appDir.path}/webhook_queue.json.wm').writeAsStringSync('9 999');
    // tronqué ET ancien : le sous-ensemble n est pas prouvable -> copie
    File(
      '${appDir.path}/webhook_queue.json.part.3.111',
    ).writeAsStringSync('[{"raw_body":"tronque|sms","created_at_ms":1');
    // décodable ET ancien : prouvé consolidé -> supprimé sans adoption
    File(
      '${appDir.path}/webhook_queue.json.part.4.222',
    ).writeAsStringSync(jsonEncode(<Object?>[item('vivant|sms')]));
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true);
    final archived = File('${appDir.path}/webhook_queue.json.part-illisible.1');
    expect(
      archived.existsSync(),
      isTrue,
      reason:
          'la copie précède la disparition, même pour un ancien — la promesse '
          'PRIVACY.md « archived rather than deleted » ne conditionnelle plus',
    );
    expect(archived.readAsStringSync(), contains('tronque|sms'));
    expect(
      File('${appDir.path}/webhook_queue.json.part.4.222').existsSync(),
      isFalse,
    );
    expect(q.corruptCount, greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('CLEAR-COPIE (contrat) : la rotation « avant-vidage » échoue -> le '
      'vidage est REFUSÉ et compté, le fichier reste intact (le catch vide '
      'd origine laissait détruire l état sans copie promise)', () async {
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('a|sms')]));
    // gâchette déterministe : la destination de la copie est un répertoire
    Directory('${appDir.path}/webhook_queue.json.avant-vidage.1').createSync();
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.add('b|sms'); // chargement + état en place
    final before = WebhookService.instance.stats.value.dropped;
    await q.clear();
    expect(
      queueFile().readAsStringSync(),
      contains('a|sms'),
      reason:
          'pas de vidage sans copie : la voie destructive confirmée '
          'resterait une destruction silencieuse sinon',
    );
    expect(q.length, 2, reason: 'la mémoire navance pas sur le disque refusé');
    expect(
      WebhookService.instance.stats.value.dropped,
      greaterThan(before),
      reason: 'le refus est visible (« rebuté(s) »), pas avalé',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('X5 (contrat, revue 7edef530 MEDIUM) : reprise du verrou sous deux '
      'add() simultanés = UN SEUL transitionneur — pas de double chargement '
      'parallèle, donc jamais de doublons persistés ni de double livraison '
      '(mesure de l audit avec pair fcntl externe : loads=3, fichier '
      '[g1,g1,g2,g2,x1,x2])', () async {
    final lock = File('${appDir.path}/webhook_queue.json.lock')..createSync();
    const script =
        'import fcntl, sys, time\n'
        'fd = open(sys.argv[1], "a+")\n'
        'fcntl.lockf(fd, fcntl.LOCK_EX)\n'
        'print("LOCKED", flush = True)\n'
        'time.sleep(120)\n';
    final holder = await Process.start('python3', ['-c', script, lock.path]);
    final first = await holder.stdout.transform(const Utf8Decoder()).first;
    expect(first, contains('LOCKED'));
    addTearDown(() {
      try {
        holder.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('graine|sms')]));
    final q = WebhookQueue.forTest(
      postRaw: (_) async => false,
      desktopLock: true,
    );
    addTearDown(q.stop);
    await q.flush(force: true); // pair vivant -> retrait
    expect(q.saveDisabled, isTrue);

    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // les deux adds passent le garde de _refreshLock DANS LE MÊME TICK :
    // la reprise ne doit être tentée qu une fois, par un seul
    // transitionneur
    final results = await Future.wait([q.add('x1|sms'), q.add('x2|sms')]);
    expect(results, [true, true]);
    expect(
      q.length,
      3,
      reason:
          'deux _loadOnce parallèles se foulaient la table rasée et '
          'réinjetaient la graine deux fois : memory=6 mesuré',
    );
    final bodies = bodiesOnDisk();
    expect(
      bodies.toSet().length,
      bodies.length,
      reason: 'aucun doublon sur le disque : $bodies',
    );
    expect(bodies, containsAll(<String>['graine|sms', 'x1|sms', 'x2|sms']));

    // et le boot suivant livre exactement une fois chacun
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
      posted.length,
      reason: 'double livraison au boot : $posted',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
  test(
    'X4d (contrat, revue 7edef530 LOW-1) : faute échappée de la charge '
    '(injectée au seam debugFailNextLoad, levée là où une exception réelle '
    'échapperait) — la charge devient officiellement inconnue : ni envoi ni '
    'écriture dessus ; le prochain appel recharge le contenu réel du disque',
    () async {
      final posted = <String>[];
      queueFile().writeAsStringSync(jsonEncode(<Object?>[item('g1|sms')]));
      final q = WebhookQueue.forTest(
        postRaw: (b) async {
          posted.add(b);
          return true;
        },
      );
      addTearDown(q.stop);
      // témoin : lit saveDisabled AU MOMENT de la notification, donc pendant
      // que le wrapper vient de poser l état inconnu
      var vuBlocage = false;
      q.uiTick.addListener(() {
        if (q.saveDisabled) vuBlocage = true;
      });
      q.debugFailNextLoad();
      await q.flush(force: true); // load -> faute échappée

      expect(
        vuBlocage,
        isTrue,
        reason:
            'la charge inconnue doit être POSÉE et NOTIFIÉE, pas avalée : '
            'avant le correctif les appelants repartaient « comme si c '
            'était chargé » (mesure revue : add=true saveDisabled=false, '
            'écrasement sans copie)',
      );
      expect(
        posted,
        isEmpty,
        reason:
            'g1 dormait dans une mémoire issue d une charge inconnue : la '
            'poster puis la retirer sans pouvoir réécrire le fichier est '
            'une voie de perte',
      );

      // le disque change de mains pendant le blackout : seule une vraie
      // relecture peut le voir — et écrire sans écraser
      queueFile().deleteSync();
      queueFile().writeAsStringSync(jsonEncode(<Object?>[item('g2|sms')]));
      expect(await q.add('nouveau|sms'), isTrue);
      expect(
        q.saveDisabled,
        isFalse,
        reason:
            'une relecture + écriture saines effacent l état inconnu — sinon '
            'un accident unique condamnerait la session à vie',
      );
      expect(
        queueFile().readAsStringSync(),
        contains('g2|sms'),
        reason:
            'la retente a RECHARGÉ avant d écrire : la mémo était bien '
            'relâchée',
      );
      await q.flush(force: true);
      expect(
        posted,
        containsAll(<String>['g2|sms', 'nouveau|sms']),
        reason: 'la reprise livre le contenu réel du disque',
      );
      expect(
        posted,
        isNot(contains('g1|sms')),
        reason:
            'rien de fantôme : g1 n était plus sur le disque au rechargement',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
