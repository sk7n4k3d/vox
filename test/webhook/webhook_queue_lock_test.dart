// Audit 557ca0bb, F13 : sur les builds bureau, deux instances de l'app
// s'ignoraient et leur premier persist écrasait l'état mémoire de l'autre —
// perte croisée de file entière. Le verrou de fichier rend la seconde
// instance silencieuse (ni lecture, ni envoi, ni écriture) au lieu de
// destructive. Mobile : mono-processus, verrou jamais demandé.

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
    appDir = await Directory.systemTemp.createTemp('vox_lock');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  test('verrou pris par UN AUTRE PROCESSUS : cette instance se met en '
      'retrait (le lock dart:io est de sémantique fcntl : il ne se conflictue '
      'pas dans le même process — le conflit est précisément inter-processus, '
      'le seul qui compte, et c\'est lui qui est testé)', () async {
    final lockFile = File('${appDir.path}/webhook_queue.json.lock')
      ..createSync();
    // preneur de verrou fcntl externe (sémantique identique à Dart)
    final holder = await Process.start('python3', [
      '-c',
      '''
import fcntl, sys, time
fd = open(sys.argv[1], "a+")
fcntl.lockf(fd, fcntl.LOCK_EX)
print("LOCKED", flush = True)
time.sleep(30)
''',
      lockFile.path,
    ]);
    final firstLine = await holder.stdout.transform(const Utf8Decoder()).first;
    expect(firstLine, contains('LOCKED'));
    addTearDown(() {
      try {
        holder.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });

    final q = WebhookQueue.forTest(
      postRaw: (_) async {
        throw StateError('l instance verrouillée ne doit rien envoyer');
      },
      desktopLock: true,
    );
    addTearDown(q.stop);
    queueFile().writeAsStringSync('[]');
    await q.flush(force: true);
    expect(
      q.saveDisabled,
      isTrue,
      reason:
          'autre processus détenteur : ni lecture, ni envoi, ni '
          'écriture — pas d écrasement croisé',
    );
    expect(await q.add('b|sms'), isFalse);
    expect(q.length, 0);
    expect(
      queueFile().readAsStringSync(),
      '[]',
      reason: 'le fichier de l\'autre instance n\'a pas été touché',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('libération du verrou : la relève peut reprendre la main', () async {
    final first = WebhookQueue.forTest(
      postRaw: (_) async => true,
      desktopLock: true,
    );
    await first.add('premier|sms');
    first.stop();
    final second = WebhookQueue.forTest(
      postRaw: (_) async => true,
      desktopLock: true,
    );
    addTearDown(second.stop);
    await second.flush(force: true);
    expect(
      second.saveDisabled,
      isFalse,
      reason: 'après stop(), le verrou se libère — pas de blocage éternel',
    );
    expect(second.length, 0);
  });
}
