// Sondes blue-team (audit ade1b6ba), versions dépôt — btp3 : verrou
// inter-processus réversible, .part déjà consolidé, erreurs d'archive
// visibles, échec de persistance honnête.
//
// PROVENANCE : les originaux (H1b, H4b, H12, H13, H14) documentaient le
// défaut — leurs assertions passaient quand la perte ou le blocage
// existait. Le correctif les retourne : ce fichier asserte la garantie
// inverse (rapport §1 findings 2/3, §2, §3).

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
    appDir = await Directory.systemTemp.createTemp('vox_btp3');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    await Process.run('chmod', ['755', appDir.path]);
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  Map<String, Object?> item(
    String body, {
    int? createdAt,
    int attempts = 0,
    bool? suspended,
  }) => <String, Object?>{
    'raw_body': body,
    'created_at_ms': createdAt ?? DateTime.now().millisecondsSinceEpoch,
    'attempts': attempts,
    'next_attempt_at_ms': 0,
    if (suspended == true) 'suspended': true,
  };

  Future<Process> startLockHolder(String lockPath) async {
    final holder = await Process.start('python3', [
      '-c',
      '''
import fcntl, sys, time
fd = open(sys.argv[1], "a+")
fcntl.lockf(fd, fcntl.LOCK_EX)
print("LOCKED", flush = True)
time.sleep(120)
''',
      lockPath,
    ]);
    final first = await holder.stdout.transform(const Utf8Decoder()).first;
    if (!first.contains('LOCKED')) throw StateError('preneur de verrou mort');
    return holder;
  }

  test('H1b (contrat) : un .part dont le fichier principal a déjà tout absorbé '
      'est consolidé PUIS supprimé — plus jamais de redélivrance au boot '
      'suivant', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('A|sms'), item('B|sms')]),
    );
    File(
      '${appDir.path}/webhook_queue.json.part.3.$fresh',
    ).writeAsStringSync(jsonEncode(<Object?>[item('A|sms'), item('B|sms')]));
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(posted, ['A|sms', 'B|sms'], reason: 'une seule délivrance');

    final partRestant = Directory(
      appDir.path,
    ).listSync().whereType<File>().any((f) => f.path.contains('.part.'));
    expect(
      partRestant,
      isFalse,
      reason:
          'merged == 0 ne dispense PLUS de supprimer : laissé sur le disque, '
          'le .part était relu au boot et redélivrait (l originale mesurait '
          'redelivre=[A,B] recovered=2, finding 2)',
    );

    // boot suivant : fichier principal vidé par les envois — le .part ne
    // doit rien faire revenir
    final posted2 = <String>[];
    final reboot = WebhookQueue.forTest(
      postRaw: (b) async {
        posted2.add(b);
        return true;
      },
    );
    addTearDown(reboot.stop);
    await reboot.flush(force: true);
    expect(posted2, isEmpty);
    expect(reboot.recoveredCount, 0);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H4b (contrat) : le pair qui meurt rend la main — l instance en retrait '
      'se réactive sans redémarrage', () async {
    final lock = File('${appDir.path}/webhook_queue.json.lock')..createSync();
    final holder = await startLockHolder(lock.path);
    addTearDown(() {
      try {
        holder.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
    queueFile().writeAsStringSync('[]');
    final q = WebhookQueue.forTest(
      postRaw: (_) async => true,
      desktopLock: true,
    );
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(q.saveDisabled, isTrue, reason: 'pair vivant : retrait');
    expect(
      await q.add('pendant|sms'),
      isFalse,
      reason:
          'rien n est accepté pendant que le pair écrit (pas d écrasement '
          'croisé)',
    );

    // le pair part (SIGKILL : le noyau rend les verrous fcntl)
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 9,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // et cette instance REPREND la main — l originale restait en retrait
    // jusqu au redémarrage de l app, chaque message refusé étant perdu
    // côté dispatch (finding 3)
    expect(
      await q.add('apres|sms'),
      isTrue,
      reason: 'la reprise du verrou se retente à chaque ajout et chaque passe',
    );
    expect(q.saveDisabled, isFalse);
    expect(
      q.length,
      1,
      reason: 'l état du fichier a bien été rechargé après la reprise',
    );
    await q.flush(force: true);
    expect(q.length, 0, reason: 'et le message part vraiment');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H12 (contrat) : archive inaccessible → retour 0 compté, exception '
      'jamais laissée remonter jusqu au bouton', () async {
    // un RÉPERTOIRE nommé comme l'archive : toute écriture échoue au
    // renommage final
    Directory('${appDir.path}/webhook_queue.archive.json').createSync();
    final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('V|sms', createdAt: aged)]),
    );
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true); // TTL -> suspendu
    expect(q.suspendedCount, 1);

    final before = WebhookService.instance.stats.value.dropped;
    final ret = await q.archiveSuspended(); // ne doit PAS lever
    expect(ret, 0);
    expect(q.length, 1, reason: 'rien n a bougé, rien n est perdu');
    expect(q.suspendedCount, 1);
    expect(
      WebhookService.instance.stats.value.dropped,
      greaterThan(before),
      reason:
          'l échec est compté (visible dans « rebuté(s) ») au lieu '
          'de remonter en exception avalée par le geste UI en release '
          '(la sonde originale mesurait thrown=FileSystemException)',
    );
    expect(
      File('${appDir.path}/webhook_queue.archive.json.tmp').existsSync(),
      isFalse,
      reason:
          'le temporaire de l écriture ratée ne traîne pas de corps en '
          'clair sur le disque',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H13 (contrat) : échec d écriture → saveDisabled vrai tant que rien ne '
      'réussit, faux dès la reprise', () async {
    queueFile().writeAsStringSync('[]');
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.add('premier|sms'); // écriture saine
    expect(q.saveDisabled, isFalse);
    expect(q.persistErrorCount, 0);

    // répertoire en lecture seule : plus aucun temporaire créable
    Process.runSync('chmod', ['555', appDir.path]);
    final added = await q.add('bloque|sms');
    Process.runSync('chmod', ['755', appDir.path]);

    // l ajout est accepté EN MÉMOIRE (la file vivante continue de jouer
    // son rôle de tampon) — mais la sauvegarde est officiellement coupée
    expect(added, isTrue);
    expect(q.persistErrorCount, greaterThan(0));
    expect(
      q.saveDisabled,
      isTrue,
      reason:
          'la sonde originale mesurait add=true persistErrors=1 '
          'saveDisabled=false : « ajouté » sans écriture possible, jamais '
          'affiché (finding 7, sauvegarde fantôme)',
    );

    await q.add('revenu|sms'); // réécrit tout : une écriture saine réussit
    expect(
      q.saveDisabled,
      isFalse,
      reason:
          'l indicateur doit retomber dès qu une écriture réussit — un '
          'bandeau qui ment après récupération est un faux négatif',
    );
    final onDisk = queueFile().readAsStringSync();
    expect(onDisk, contains('bloque|sms'));
    expect(onDisk, contains('revenu|sms'));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
