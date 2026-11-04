// Sonde blue-team (audit 8960c5cc) — non-régression et préservation des
// données après le fix de budget octets de la file webhook.
// Cible en lecture seule : tout tourne dans cette copie.
//
// ADAPTATION 2026-11-04 (directive « zéro éviction ») : P1, P3, P5 et P6
// sont verts TELS QUELS contre le nouveau code. P2 et P4 ont dû être
// RÉÉCRITS : leurs assertions codifiaient la politique que l'audit vient de
// qualifier de perte de données — P2 exigeait l'éviction des anciens pour
// loger un corps au budget, P4 AFFIRMAIT la perte de l'item en vol
// (`isFalse` sur sa présence disque). Ces deux cas testent désormais la
// garantie inverse : rien n'est supprimé pour faire de la place, le rejet
// est explicite et observable, l'item en vol survit à l'échec.

import 'dart:async';
import 'dart:convert';
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
    appDir = await Directory.systemTemp.createTemp('vox_q_probe2');
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

  List<String> heads(List<Object?> l) => l
      .cast<Map>()
      .map((m) => (m['raw_body'] as String).substring(0, 2))
      .toList(growable: false);

  test('P1 — oversized écarté : file intacte EN MÉMOIRE et SUR DISQUE',
      () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    for (var i = 0; i < 5; i++) {
      await queue.add('${'m$i|'.padRight(1024 * 1024, 'x')}');
    }
    await queue.add('video|${'B' * (21 * 1024 * 1024)}');
    expect(queue.length, 5);
    final onDisk = await readQueueFile();
    expect(onDisk.length, 5, reason: 'le disque doit porter les 5 evenements');
    expect(heads(onDisk), ['m0', 'm1', 'm2', 'm3', 'm4']);
    final bodies = onDisk
        .cast<Map>()
        .map((m) => m['raw_body'] as String)
        .toList(growable: false);
    for (var i = 0; i < 5; i++) {
      expect(bodies[i].length, 1024 * 1024, reason: 'corps $i troncque');
    }
    final parts = appDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.part'))
        .toList();
    expect(parts, isEmpty, reason: 'rejet = pas decriture parasite');
    expect(queue.pending.value, 5);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('P2 — zéro éviction : un gros corps NE chasse jamais les anciens',
      () async {
    // RÉÉCRIT (voir en-tête) : l'original exigeait « accepte, evicte les
    // anciens ». Nouveau contrat : on ne supprime AUCUN élément existant
    // pour faire de la place ; ce qui ne tient pas est refusé avec motif
    // observable.
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.add('oa|${'o' * (1024 * 1024)}');
    // Corps exactement au plafond par entrée, sur file quasi vide : accepté,
    // l'ancien survivant + lui tiennent dans le budget (1 + 23 ≤ 26 MiB).
    final itemMax = 'xx' * 1 + 'z' * (WebhookQueue.maxQueuedItemBytes - 2);
    expect(await queue.add(itemMax), isTrue);
    expect(queue.length, 2, reason: 'les deux coexistent, rien n est chassé');
    var onDisk = await readQueueFile();
    expect(heads(onDisk), ['oa', 'xx']);
    // Corps au-dessus du plafond par entrée : REJETÉ, file inchangée.
    expect(
      await queue.add('x' * (WebhookQueue.maxQueuedItemBytes + 1)),
      isFalse,
    );
    expect(queue.length, 2);
    onDisk = await readQueueFile();
    expect(heads(onDisk), ['oa', 'xx'], reason: 'le rejet ne doit rien ecraser');
    // Et le rejet est OBSERVABLE : retour booléen, compteur, motif.
    expect(queue.droppedCount, 1);
    expect(queue.lastRejectReason, isNotNull);
    expect(queue.lastRejectBody!.length, WebhookQueue.maxQueuedItemBytes + 1);
    // Corps qui ne tient plus dans le budget global : refusé aussi, sans
    // toucher aux existants (P1 en donne la version 21 Mo).
    expect(await queue.add('x' * (3 * 1024 * 1024)), isFalse);
    expect(queue.length, 2);
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('P3 — file héritée déjà hors budget : un add en chasse une partie',
      () async {
    // File d une build antérieure a 44a9f683 (pas de budget octets) :
    // 3 x 9 Mo = 27 Mo > maxQueuedBytes, jamais re-validee au chargement.
    final raw = List.generate(3, (i) {
      return <String, Object?>{
        'raw_body': 'l$i|'.padRight(9 * 1024 * 1024, 'y'),
        'created_at_ms': 1,
        'attempts': 0,
        'next_attempt_at_ms': 0,
      };
    });
    File('${appDir.path}/webhook_queue.json')
        .writeAsStringSync(jsonEncode(raw));
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.add('ne|petit');
    final onDisk = await readQueueFile();
    // ignore: avoid_print
    print('P3: 3 x 9 Mo + 1 petit -> length ${queue.length}, '
        'survies ${heads(onDisk)}');
    expect(queue.length, 3,
        reason: 'eviction FIFO : l0 parti, l1 + l2 + nouveau = 18 Mo');
    expect(heads(onDisk), ['l1', 'l2', 'ne']);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('P4 — eviction en vol impossible : echec apres adds = evenement garde',
      () async {
    // RÉÉCRIT (voir en-tête) : l'original AFFIRMAIT la perte (`isFalse` sur
    // la présence du corps en vol sur disque) — c'était la preuve du bug.
    // Nouveau contrat : l'item envoyé reste dans la file et sur le fichier
    // pendant l'envoi ; un échec tardif ne le perd pas, il le remonte en tête.
    final gate = <String, Completer<bool>>{};
    final queue = WebhookQueue.forTest(postRaw: (body) {
      final key = body.substring(0, 2);
      gate[key] ??= Completer<bool>();
      return gate[key]!.future;
    });
    addTearDown(queue.stop);
    await queue.add('aa|${'A' * (1024 * 1024)}');
    final flushing = queue.flush(force: true);
    for (var i = 0; i < 100 && !gate.containsKey('aa'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(gate.containsKey('aa'), isTrue, reason: "l'envoi doit etre demarre");
    // File remplie PENDANT l'envoi : les 5 × 4 Mo tiennent sous le budget
    // élargi (26 MiB) — et surtout aucun n'est chassé, aa non plus.
    for (var i = 0; i < 5; i++) {
      expect(await queue.add('b$i|${'B' * (4 * 1024 * 1024)}'), isTrue);
    }
    expect(queue.length, 6, reason: 'aa protege en vol + b0..b4, zero eviction');
    gate['aa']!.complete(false); // l'envoi échoue APRÈS les adds concurrents
    await flushing;
    final onDisk = (await readQueueFile()).cast<Map>();
    // ignore: avoid_print
    print('P4: length ${queue.length}, disque ${onDisk.length}, '
        'tetes ${heads(onDisk)}');
    expect(
      onDisk.any((m) => (m['raw_body'] as String).startsWith('aa')),
      isTrue,
      reason: "l'evenement en vol a echoue : il doit etre refile, en memoire "
          'et sur disque, et remonte en tete pour la prochaine passe',
    );
    expect(heads(onDisk).first, 'aa');
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('P5 — clear() puis add : pas de regression', () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    for (var i = 0; i < 3; i++) {
      await queue.add('c$i|petit');
    }
    await queue.clear();
    expect(queue.length, 0);
    expect(await readQueueFile(), isEmpty);
    await queue.add('c9|apres');
    expect(queue.length, 1);
  });

  test('P6 — un seul corps lourd vide la file des événements non envoyés',
      () async {
    // 19 événements texte déjà en file (19 Mo, sous le budget), puis un MMS
    // de 19,5 Mo qui passe le garde-fous (< budget) : l éviction anticipée
    // chasse TOUT pour le loger.
    final raw = List.generate(19, (i) {
      return <String, Object?>{
        'raw_body': 'tx'.padRight(1024 * 1024, 't'),
        'created_at_ms': 1,
        'attempts': 0,
        'next_attempt_at_ms': 0,
      };
    });
    File('${appDir.path}/webhook_queue.json')
        .writeAsStringSync(jsonEncode(raw));
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.add('mm|${'M' * (19500 * 1024)}');
    // ignore: avoid_print
    print('P6: 19 evenements texte + 1 MMS 19,5 Mo -> length ${queue.length}');
    expect(queue.length, greaterThan(1),
        reason: 'les 19 événements non envoyés sont supprimés par un seul '
            'corps média qui tient pourtant dans le budget');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
