// Sondes blue-team (revue indépendante 3ca417b0), versions dépôt.
//
// PROVENANCE : les originaux (RB1..RB6, /tmp/opencode/probes3ca) documentaient
// le défaut — RB1/RB3/RB4 passaient quand la perte et le silence existaient,
// RB2/RB5/RB6 bornaient le diagnostic. Les assertions sont retournées ou
// renforcées : ce fichier asserte la garantie inverse (rapport §1 F1..F6,
// INFO-1/2).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;
  File queueFile() => File('${appDir.path}/webhook_queue.json');
  File watermarkFile() => File('${appDir.path}/webhook_queue.json.wm');
  int modeOf(File f) => f.statSync().mode & 0x1ff;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    appDir = await Directory.systemTemp.createTemp('vox_rb3ca');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    try {
      Process.runSync('chmod', ['755', appDir.path]);
    } catch (_) {}
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

  List<String> filesWith(String needle) => Directory(appDir.path)
      .listSync()
      .whereType<File>()
      .where((f) {
        try {
          return f.readAsStringSync().contains(needle);
        } catch (_) {
          return false;
        }
      })
      .map((f) => p.basename(f.path))
      .toList();

  test(
    'RB1 (contrat) : persist en échec (EISDIR) -> le .part consolidé est '
    'CONSERVÉ, le corps survit sur le disque et revient au boot suivant '
    '(audit 3ca417b0 F1 — l originale mesurait partVivant=false traces=[])',
    () async {
      // gâchette : le nom du fichier principal est occupé par un répertoire
      // -> rename du snapshot échoue (EISDIR), unlink du .part lui réussirait
      Directory('${appDir.path}/webhook_queue.json').createSync();
      final part = File('${appDir.path}/webhook_queue.json.part.5.111')
        ..writeAsStringSync(
          jsonEncode(<Object?>[item('corbrb1|sms', attempts: 2)]),
        );
      final q = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(q.stop);
      await q
          .resumeSuspended(); // déclenche _ensureLoaded -> adoption -> persist

      expect(
        part.existsSync(),
        isTrue,
        reason:
            'la consolidation na pas atteint le disque : le .part ne doit pas '
            'être supprimé (writeOk gating)',
      );
      expect(filesWith('corbrb1|sms'), isNotEmpty);
      expect(q.persistErrorCount, greaterThan(0));
      expect(q.saveDisabled, isTrue, reason: 'l échec est visible');
      expect(
        watermarkFile().existsSync(),
        isFalse,
        reason: 'pas de watermark sans renommage réussi',
      );

      // boot suivant : le .part est toujours là -> récupération réelle
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
        posted,
        ['corbrb1|sms'],
        reason:
            'le message jamais écrit sur le disque principal finit par partir',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('RB1b (contrat) : consolidation réussie -> le .part est supprimé, le '
      'watermark avance (le gating F1 ne transforme pas la rétention en '
      'clou permanent quand tout va bien)', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('A|sms')]));
    final part = File('${appDir.path}/webhook_queue.json.part.4.$fresh')
      ..writeAsStringSync(jsonEncode(<Object?>[item('A|sms'), item('B|sms')]));
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(
      part.existsSync(),
      isFalse,
      reason: 'persist vérifié OK : la consolidation nettoie comme avant',
    );
    expect(watermarkFile().existsSync(), isTrue);
    expect(q.persistErrorCount, 0);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('RB2 (borne) : répertoire 555 -> persist échoue ET le .part survit '
      'aussi (unlink interdit) : pas de perte dans ce cas', () async {
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('A|sms')]));
    final part = File('${appDir.path}/webhook_queue.json.part.9.222')
      ..writeAsStringSync(
        jsonEncode(<Object?>[item('A|sms'), item('nouveau|sms')]),
      );
    Process.runSync('chmod', ['555', appDir.path]);
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.resumeSuspended();
    Process.runSync('chmod', ['755', appDir.path]);
    expect(part.existsSync(), isTrue);
    expect(filesWith('nouveau|sms'), isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test(
    'RB3 (contrat) : 4 .part tronqués dans un seul boot -> 4 copies '
    'préservées, SANS éviction de la plus ancienne (audit 3ca417b0 F2 — '
    'l originale mesurait contenusPerdus=[perdu1] : la rotation tuait .3)',
    () async {
      for (var i = 1; i <= 4; i++) {
        File(
          '${appDir.path}/webhook_queue.json.part.$i.${100 + i}',
        ).writeAsStringSync('[{"raw_body":"perdu$i|sms","created_at_ms":1');
      }
      final q = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(q.stop);
      await q.resumeSuspended();
      final present =
          Directory(appDir.path)
              .listSync()
              .whereType<File>()
              .map((f) => p.basename(f.path))
              .where((n) => n.contains('part-illisible'))
              .toList()
            ..sort();
      expect(present.length, 4, reason: 'copies .1..4 toutes présentes');
      for (var i = 1; i <= 4; i++) {
        expect(
          filesWith('perdu$i|sms'),
          isNotEmpty,
          reason: 'le contenu du $i-e tronqué est retrouvé quelque part',
        );
      }
      expect(q.corruptCount, 4);
      // et la purge explicite, elle, les retire (compte exact)
      expect((await q.listCopies()).length, 4);
      expect(await q.purgeCopies(), 4);
      expect((await q.listCopies()).length, 0);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('RB4 (contrat) : uiTick notifié par le chargement lui-même — invalides '
      'et sursaturage visibles sans variation de pending (audit 3ca417b0 F3 : '
      'l originale mesurait ticksApresChargement=0)', () async {
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[42, 'pas-un-objet', item('vivant|sms')]),
    );
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    var ticks = 0;
    q.uiTick.addListener(() => ticks++);
    await q.resumeSuspended(); // _ensureLoaded seulement
    expect(
      ticks,
      greaterThan(0),
      reason:
          'la page Réglages déjà ouverte doit voir les compteurs « corrompu(s) '
          'préservé(s) » sans qu\'un autre événement ne force un tick',
    );
    expect(q.invalidCount, 2);
    expect(q.corruptCount, 2);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('RB5 (contrat) : la copie tournante est DURCIE AVANT CONTENU — aucune '
      'sonde ne surprend jamais la copie monde-lisible pendant la copie '
      '(audit 3ca417b0 F4 : File.copy créait la destination au mode de la '
      'source, 120 Mo en clair lisibles ~0,5 s)', () async {
    final main = queueFile();
    // corps de ~64 Mo en clair pour que la copie dure mesurablement
    main.writeAsStringSync(
      jsonEncode(<Object?>[
        <String, Object?>{
          'raw_body': 'x' * (64 * 1024 * 1024),
          'created_at_ms': 1,
          'attempts': 0,
          'next_attempt_at_ms': 0,
        },
      ]),
    );
    Process.runSync('chmod', ['644', main.path]);
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    final dst = File('${main.path}.avant-vidage.1');
    int? modeInterdit;
    var done = false;
    unawaited(q.clear().then((_) => done = true));
    for (var i = 0; i < 16000 && !done; i++) {
      if (dst.existsSync()) {
        final len = dst.lengthSync();
        final m = modeOf(dst);
        // la fenêtre tolérée est le fichier ENCORE VIDE entre create() et
        // chmod() : sans octets, rien n est exposé. Dès qu un octet de
        // corps apparaît, le mode doit être 600 — c est la vraie garantie.
        if (len > 0 && m != 0x180) {
          modeInterdit = m;
          break;
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    while (!done) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      modeInterdit,
      isNull,
      reason:
          'jamais la copie na été vue avec un mode autre que 600, pas même '
          'pendant l écriture depuis une source 644 '
          '(mesuré : ${modeInterdit?.toRadixString(8)})',
    );
    expect(modeOf(dst), 0x180);
    expect(
      dst.lengthSync(),
      greaterThan(1024 * 1024),
      reason: 'la fenêtre de sondage a bien couvert une copie en cours',
    );
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('RB6 (borne) : archivage concurrent — la rotation .archive.1 ne peut '
      'pas écraser le lot du passé', () async {
    final archive = File('${appDir.path}/webhook_queue.archive.json');
    final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
    archive.writeAsStringSync(
      jsonEncode(<Object?>[item('passeX|sms', createdAt: aged)]),
    );
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('lotAX|sms', createdAt: aged - 1)]),
    );
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true); // lotA -> suspendu (TTL)
    final r = await Future.wait([q.archiveSuspended(), q.archiveSuspended()]);
    expect(r, [1, 0]);
    final rotated = File('${archive.path}.archive.1');
    expect(rotated.existsSync(), isTrue);
    expect(rotated.readAsStringSync(), contains('passeX|sms'));
    expect(archive.readAsStringSync(), contains('lotAX|sms'));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('W1 (contrat) : watermark — un .part PLUS ANCIEN que le dernier fichier '
      'écrit ne réveille pas un suspendu (audit 3ca417b0 INFO-1 : après '
      'rename raté + mort avant delete, le .part écrasait l état le plus '
      'récent)', () async {
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('X|sms', attempts: 3, suspended: true)]),
    );
    // le principal a été écrit au (seq, ts) = (9, 999) : tout .part en
    // dessous est déjà consolidé
    watermarkFile().writeAsStringSync('9 999');
    File(
      '${appDir.path}/webhook_queue.json.part.5.111',
    ).writeAsStringSync(jsonEncode(<Object?>[item('X|sms', attempts: 0)]));
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
      q.suspendedCount,
      1,
      reason: 'la suspension du fichier principal SURVIT au .part plus vieux',
    );
    expect(posted, isEmpty);
    expect(
      File('${appDir.path}/webhook_queue.json.part.5.111').existsSync(),
      isFalse,
      reason: 'prouvé déjà écrit : supprimé sans rien adopter',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test(
    'W2 (contrat) : après redémarrage, le compteur de séquence reprend au-'
    'dessus du watermark — le prochain instantané écrit porte toujours un '
    'seq supérieur à ce que le disque a déjà porté (audit 3ca417b0 INFO-1)',
    () async {
      watermarkFile().writeAsStringSync('42 12345');
      queueFile().writeAsStringSync('[]');
      final q = WebhookQueue.forTest(postRaw: (_) async => false);
      addTearDown(q.stop);
      await q.add('u|sms'); // persist -> renommage réussi -> nouveau wm
      final wm = watermarkFile().readAsStringSync().trim().split(
        RegExp(r'\s+'),
      );
      expect(wm.length, 2);
      expect(
        int.parse(wm[0]),
        greaterThan(42),
        reason:
            'le seq du snapshot fraichement écrit doit dépasser le watermark '
            'hérité, sinon un futur .part serait pris pour un ancien',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('L1 (contrat) : verrou indisponible = lockUnavailable VISIBLE + tick, '
      'sans désactiver la sauvegarde (audit 3ca417b0 F5 : branche entièrement '
      'silencieuse)', () async {
    Process.runSync('chmod', ['555', appDir.path]);
    final q = WebhookQueue.forTest(
      postRaw: (_) async => true,
      desktopLock: true,
    );
    addTearDown(q.stop);
    var ticks = 0;
    q.uiTick.addListener(() => ticks++);
    await q.flush(force: true); // ouverture du .lock refusée
    Process.runSync('chmod', ['755', appDir.path]);
    expect(
      q.lockUnavailable,
      isTrue,
      reason: 'l FS sans verrou doit être appris par l UI, pas deviné',
    );
    expect(
      q.saveDisabled,
      isFalse,
      reason: 'ici l écriture fonctionne : ce n EST PAS une sauvegarde coupée',
    );
    expect(ticks, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('L2 (contrat) : instance en retrait — clear() et archiveSuspended() ne '
      'manœuvrent PAS les copies du pair (corollaire F5 : l instance bloquée '
      'pouvait évincer les rotations de l autre)', () async {
    final lock = File('${appDir.path}/webhook_queue.json.lock')..createSync();
    final holder = await Process.start('python3', [
      '-c',
      '''
import fcntl, sys, time
fd = open(sys.argv[1], "a+")
fcntl.lockf(fd, fcntl.LOCK_EX)
print("LOCKED", flush = True)
time.sleep(120)
''',
      lock.path,
    ]);
    final first = await holder.stdout.transform(const Utf8Decoder()).first;
    expect(first, contains('LOCKED'));
    addTearDown(() {
      try {
        holder.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
    final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[item('V|sms', createdAt: aged)]),
    );
    final q = WebhookQueue.forTest(
      postRaw: (_) async => false,
      desktopLock: true,
    );
    addTearDown(q.stop);
    await q.flush(force: true); // pair vivant -> retrait
    expect(q.saveDisabled, isTrue);
    expect(await q.archiveSuspended(), 0);
    await q.clear();
    expect(
      Directory(appDir.path).listSync().whereType<File>().any(
        (f) => f.path.contains('.avant-vidage.'),
      ),
      isFalse,
      reason:
          'pas de rotation déclenchée par une instance qui ne détient '
          'pas le fichier',
    );
    expect(
      File('${appDir.path}/webhook_queue.archive.json').existsSync(),
      isFalse,
    );
    expect(
      queueFile().readAsStringSync(),
      contains('V|sms'),
      reason: 'le fichier du pair est intact',
    );
    expect(
      WebhookService.instance.stats.value.dropped,
      greaterThan(0),
      reason: 'le report d archivage est compté donc visible',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
