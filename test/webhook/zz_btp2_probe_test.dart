// Sondes blue-team (audit ade1b6ba), versions dépôt — btp2 : permissions
// des copies, conflit d'état entre instantanés, atomicité de l'archive.
//
// PROVENANCE : les originaux (H3, H4, H6, H11, H14) documentaient le
// DEFAUT — leurs assertions passaient quand la perte existait. Le correctif
// les retourne : ce fichier asserte la garantie inverse (rapport §1
// findings 4/5/6). Le cas H4 (verrou entre deux fichiers du MÊME processus)
// est tombé : le verrou dart:io est de sémantique fcntl et ne se conflictue
// pas intra-processus ; le conflit réel inter-processus est couvert par la
// sonde H4b (preneur python fcntl) du fichier zz_btp3.

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
    appDir = await Directory.systemTemp.createTemp('vox_btp2');
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

  int modeOf(File f) => f.statSync().mode & 0x1ff;
  void chmod(FileSystemEntity f, String mode) =>
      Process.runSync('chmod', [mode, f.path]);

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

  test('H3 (contrat) : les copies tournantes passent en 600 même quand la '
      'source est en 644 — corps en clair jamais exposés au-delà du '
      'propriétaire', () async {
    // fichier principal écrit par une build antérieure à la baseline 600,
    // donc en 644, portant un élément invalide qui déclenche la copie de
    // secours au premier persist (sauvegarde « corrompu »)
    final main = queueFile()..writeAsStringSync(jsonEncode(<Object?>[42]));
    chmod(main, '644');
    expect(modeOf(main), 0x1a4); // 644 : la contamination est bien là
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.add('u1|sms'); // premier persist -> rotation « corrompu »

    final backup = File('${appDir.path}/webhook_queue.json.corrompu.1');
    expect(backup.existsSync(), isTrue);
    expect(
      modeOf(backup),
      0x180,
      reason:
          'la copie tournante porte les mêmes corps de SMS en clair : 600 '
          'QUEL QUE SOIT le mode de la source (la sonde originale mesurait '
          '644, finding 4)',
    );
    expect(
      modeOf(main),
      0x180,
      reason: 'et l écriture vivante est durcie dès la création du temporaire',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H6 (contrat) : entre fichier principal (ancien) et .part (récent), '
      'les champs d ÉTAT du plus récent gagnent — un suspendu ne reprend '
      'pas du service après crash', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(jsonEncode(<Object?>[item('X|sms')]));
    File('${appDir.path}/webhook_queue.json.part.11.$fresh').writeAsStringSync(
      jsonEncode(<Object?>[item('X|sms', attempts: 4, suspended: true)]),
    );
    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);
    expect(q.length, 1);
    expect(
      q.suspendedCount,
      1,
      reason:
          'la suspension du snapshot le plus récent survit à la fusion '
          '(l originale mesurait suspended=0 : le plafond de tentatives '
          'était contourné après crash, finding 6)',
    );
    expect(posted, isEmpty, reason: 'suspendu = jamais reposté');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H11 (contrat) : la deuxième archive ROTATE la première — la seule '
      'copie du passé n est jamais tronquée sur place', () async {
    final aged = DateTime.now().millisecondsSinceEpoch - 25 * 3600 * 1000;
    final archive = File('${appDir.path}/webhook_queue.archive.json')
      ..writeAsStringSync(
        jsonEncode(<Object?>[
          item('avant|sms', createdAt: aged, attempts: 5, suspended: true),
        ]),
      );
    chmod(archive, '600');
    // lot du jour : un âgé (se suspend au flush) + un actif (reste)
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[
        item('maintenant|sms', createdAt: aged),
        item('garde|sms'),
      ]),
    );
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.flush(force: true); // l'âgé passe suspendu (TTL 24 h)
    expect(q.suspendedCount, 1);
    expect(await q.archiveSuspended(), 1);
    expect(q.length, 1, reason: 'l actif ne doit pas être archivé');

    expect(archive.existsSync(), isTrue);
    expect(archive.readAsStringSync(), contains('maintenant|sms'));
    expect(modeOf(archive), 0x180);
    final rotated = File('${archive.path}.archive.1');
    expect(
      rotated.existsSync(),
      isTrue,
      reason:
          'l archive préexistante est copiée AVANT réécriture : une coupure '
          'pendant l écriture ne peut plus emporter le passé (l originale '
          'ne trouvait qu un seul fichier, zéro copie, finding 5)',
    );
    expect(rotated.readAsStringSync(), contains('avant|sms'));
    expect(modeOf(rotated), 0x180);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H14 (contrat) : le chemin d écriture ne transite plus par un fichier '
      '644 — le temporaire est durci AVANT le contenu, la source alimente '
      'des copies déjà saines', () async {
    final q = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(q.stop);
    await q.add('u|sms');
    expect(
      modeOf(queueFile()),
      0x180,
      reason:
          'la sonde originale mesurait 644 le temps du write : la fenêtre '
          'exposait les corps en clair via les copies tournantes',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
