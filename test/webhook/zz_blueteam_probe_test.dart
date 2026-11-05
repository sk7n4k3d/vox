// Contrat « zéro perte » version dépôt — issu des sondes blue-team de
// l'audit 557ca0bb (P1..P6 originaux dans le rapport ; leur passage sur le
// code corrigé est consigné dans le commit). Chaque cas asserte la GARANTIE
// inverse du risque démontré :
//   P1 → les suspendus ne bouchent plus la porte d'entrée (part active) ;
//   P2 → un .part plus récent est RÉCUPÉRÉ, pas purgé (union, zéro doublon) ;
//   P3 → fichier illisible : add() répond false, compté, épave préservée ;
//   P4 → un champ mal typé ne contamine plus le fichier entier, pas de
//        double envoi après redémarrage ;
//   P5 → corps vide refusé à l'entrée, et un corps vide déjà présent reste
//        un élément VALIDE qui repart ;
//   P6 → copie de secours à ROTATION BORNÉE (≤ 3), plus une copie pleine en
//        clair par démarrage.

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    appDir = await Directory.systemTemp.createTemp('vox_contrat');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  Map<String, Object?> item(String body, {int createdAt = 0}) =>
      <String, Object?>{
        'raw_body': body,
        'created_at_ms': createdAt,
        'attempts': 0,
        'next_attempt_at_ms': 0,
      };

  List<Object?> disk() =>
      (jsonDecode(queueFile().readAsStringSync()) as List).cast<Object?>();

  test('P1 (contrat) : suspendus nombreux — le neuf est accepté tant que la '
      'PART ACTIVE tient, et « Archiver » libère le fichier sans rien '
      'détruire', () async {
    final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
    final big = 'a' * (9 * 1024 * 1024);
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[
        item('1|$big', createdAt: aged),
        item('2|$big', createdAt: aged),
        item('3|$big', createdAt: aged),
      ]),
    );
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true); // expirent -> suspendus
    expect(q.suspendedCount, 3);

    // l'audit démontrait : add refusé À PERPÉTUITÉ. Le budget d'entrée se
    // juge désormais sur la part active — ici vide.
    expect(
      await q.add('nouvel|sms'),
      isTrue,
      reason: 'le suspendu ne mange plus le budget du neuf',
    );
    expect(q.overBudget, isFalse);

    // et la sortie NON destructive existe : l'archivage déplace suspendus
    // et corrompus dans un fichier archive — plus de poids mort dans la
    // file vivante, rien de supprimé du disque.
    final archived = await q.archiveSuspended();
    expect(archived, 3);
    expect(q.length, 1, reason: 'seul le neuf reste dans la file vivante');
    final archive = File('${appDir.path}/webhook_queue.archive.json');
    expect(archive.existsSync(), isTrue);
    final archivedEntries = jsonDecode(archive.readAsStringSync()) as List;
    expect(
      archivedEntries.length,
      3,
      reason: 'les trois jamais-envoyés sont conservés dans l\'archive',
    );
    for (var i = 1; i <= 3; i++) {
      expect(
        archive.readAsStringSync(),
        contains('$i|'),
        reason: 'aucun corps archivé pas perdu',
      );
    }
    // et le fichier principal ne porte plus que le neuf
    expect(queueFile().readAsStringSync(), contains('nouvel|sms'));
    expect(queueFile().readAsStringSync(), isNot(contains('|aaaa')));
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('P2 (contrat) : .part valide plus récent = RÉCUPÉRÉ, union sans '
      'doublon, envoyé une fois', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('ancien|sms', createdAt: fresh)]),
    );
    final part = File(
      '${appDir.path}/webhook_queue.json.part.7.'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    part.writeAsStringSync(
      jsonEncode(<Object?>[
        item('ancien|sms', createdAt: fresh),
        item('nouveau|sms', createdAt: fresh),
      ]),
    );
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (body) async {
        posted.add(body);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);

    expect(
      posted,
      containsAll(['ancien|sms', 'nouveau|sms']),
      reason:
          'l\'instantané .part est des événements, pas des orphelins : '
          'il est absorbé (l\'audit prouvait sa destruction pure et simple)',
    );
    expect(
      posted.where((b) => b == 'ancien|sms').length,
      1,
      reason: 'union par corps : ancien (principal ∩ .part) envoyé UNE fois',
    );
    expect(
      part.existsSync(),
      isFalse,
      reason: 'consolidé puis supprimé — dans cet ordre',
    );
    expect(disk(), isEmpty, reason: 'tout est parti : fichier vidé');

    // et un redémarrage ne rejoue rien
    var posts2 = 0;
    final reboot = WebhookQueue.forTest(
      postRaw: (_) async {
        posts2++;
        return true;
      },
    );
    addTearDown(reboot.stop);
    await reboot.flush(force: true);
    expect(posts2, 0);
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('P2b : .part garbage (non décodable) est ARCHIVÉ en copie '
      '« part-illisible », jamais perdu ; le fichier principal intact '
      '(politique révisée audit ade1b6ba, finding 1 : un tronqué porte '
      'peut-être des messages jamais envoyés)', () async {
    queueFile().writeAsStringSync(jsonEncode([item('ok|sms', createdAt: 1)]));
    final garbage = File('${appDir.path}/webhook_queue.json.part.3.999')
      ..writeAsStringSync('restes d un crash');
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(garbage.existsSync(), isFalse);
    final archived = File('${appDir.path}/webhook_queue.json.part-illisible.1');
    expect(
      archived.existsSync(),
      isTrue,
      reason: 'déplacé, pas détruit : les octets survivent en copie durcie',
    );
    expect(archived.readAsStringSync(), 'restes d un crash');
    expect(q.corruptCount, greaterThanOrEqualTo(1));
    expect(
      q.recoveredCount,
      0,
      reason: 'rien récupéré : le garbage ne se décodait pas',
    );
    expect(queueFile().readAsStringSync(), contains('ok|sms'));
  });

  test('P3 (contrat) : fichier illisible → add() dit FALSE, compté, épave '
      'préservée ; un « Vider » avec copie relance tout', () async {
    queueFile().writeAsStringSync('[{"raw_body": "x');
    final wreck = queueFile().readAsStringSync();
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    expect(
      await q.add('en RAM|sms'),
      isFalse,
      reason:
          'promettre true sans écriture possible était un mensonge '
          'avec perte au boot (l\'audit le démontrait)',
    );
    expect(q.droppedCount, 1);
    expect(q.saveDisabled, isTrue);
    expect(
      q.length,
      0,
      reason:
          'rien n\'est accepté en mémoire derrière '
          'une persistance morte',
    );
    await q.flush(force: true);
    expect(
      queueFile().readAsStringSync(),
      wreck,
      reason: 'l\'épave n\'est jamais écrasée silencieusement',
    );

    await q.clear(); // « Vider » — la copie avant-vidage est créée par clear
    expect(queueFile().readAsStringSync(), '[]');
    expect(q.saveDisabled, isFalse);
    expect(await q.add('reprise|sms'), isTrue);
    expect(queueFile().readAsStringSync(), contains('reprise|sms'));
    final preClear = appDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.avant-vidage.'))
        .toList();
    expect(preClear.length, 1);
    expect(
      preClear.single.readAsStringSync(),
      wreck,
      reason:
          'même la destruction sur demande garde une copie : un tap '
          'ne doit être irréversible sans trace (audit F5)',
    );
  });

  test('P4 (contrat) : un champ numérique mal typé ne contamine QUE son '
      'élément — pas de double envoi après redémarrage', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[
        item('a|sms', createdAt: fresh),
        <String, Object?>{
          'raw_body': 'b|sms',
          'created_at_ms': 1,
          'attempts': 0,
          'next_attempt_at_ms': 0,
          'bytes': '12',
        },
      ]),
    );
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (body) async {
        posted.add(body);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(posted, contains('a|sms'));
    expect(
      q.saveDisabled,
      isFalse,
      reason:
          'plus de « tout le fichier déclaré illisible » : la '
          'persistance continue, seul l\'élément tordu suit le sort brut',
    );

    // redémarrage : l'envoyé ne repart PAS (c'était la preuve du doublon)
    final posted2 = <String>[];
    final reboot = WebhookQueue.forTest(
      postRaw: (body) async {
        posted2.add(body);
        return true;
      },
    );
    addTearDown(reboot.stop);
    await reboot.flush(force: true);
    expect(
      posted2.where((b) => b == 'a|sms'),
      isEmpty,
      reason:
          'a était bien retiré du fichier après envoi : plus de '
          'livraison en double côté Hermes',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('P5 (contrat) : corps vide refusé à l\'entrée ; un corps vide déjà '
      'dans le fichier n\'est plus un « corrompu » sans avenir', () async {
    final q1 = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q1.stop);
    expect(
      await q1.add(''),
      isFalse,
      reason: 'added: un poids mort vide ne doit plus entrer',
    );

    // et l'entrée vide écrite par les versions antérieures : valide, elle
    // repart (l'audit prouvait posts=0 invalid=1 = jamais renvoyé)
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[
        item('', createdAt: DateTime.now().millisecondsSinceEpoch),
      ]),
    );
    var posts = 0;
    final q2 = WebhookQueue.forTest(
      postRaw: (_) async {
        posts++;
        return true;
      },
    );
    addTearDown(q2.stop);
    await q2.flush(force: true);
    expect(
      posts,
      1,
      reason:
          'raw_body vide = événement (vide), pas '
          'corruption : il est posté et part',
    );
    expect(q2.invalidCount, 0);
  });

  test('P6 (contrat, rév. audit 3ca417b0 F2) : copies de secours conservées '
      'SANS plafond — aucune éviction au boot ; la purge est un geste '
      'explicite qui ne touche que les copies', () async {
    queueFile().writeAsStringSync(jsonEncode(<Object?>[42]));
    for (var boot = 1; boot <= 6; boot++) {
      final q = WebhookQueue.forTest(postRaw: (_) async => false);
      await q.add('u$boot|sms');
      q.stop();
    }
    // un inventaire passe par une instance vivante
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    // ancien contrat : rotation bornée à 3, « preuve » de la fin de
    // l\'accumulation. Faux compromis : la 3e épave effacée était peut-être
    // la seule copie d\'un message jamais envoyé. La rétention est désormais
    // totale et la surface disque rendue visible + purgeable à la demande.
    final copies = await q.listCopies();
    final backups = copies.where((c) => c.name.contains('.corrompu.'));
    expect(
      backups.length,
      6,
      reason:
          'un boot = une copie, aucune détruite (l\'originale en gardait 3 sur '
          '6 en affirmant « jamais d\'un boot » dans son propre journal)',
    );
    // la purge explicite supprime les copies et RIEN D\'AUTRE
    final deleted = await q.purgeCopies();
    expect(deleted, greaterThanOrEqualTo(6));
    expect(await q.listCopies(), isEmpty);
    expect(
      queueFile().existsSync(),
      isTrue,
      reason: 'la file vivante survit à la purge des copies',
    );
    expect(queueFile().readAsStringSync(), contains('u6|sms'));
  }, timeout: const Timeout(Duration(seconds: 180)));
}

// F13 (desktop) : deux instances -> la seconde s efface, n ecrase rien.
// Test dans un fichier séparé pour ne pas mélanger les setups.
