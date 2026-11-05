// SONDE INDÉPENDANTE (blue-team, audit ab0a82b4), VERSION CONTRAT DU DÉPÔT —
// BTP10 : la fenêtre résiduelle COMBINÉE au disque lent. Rouge mesuré sur
// ab0a82b4 (hops=0 : 10/10 pertes ; hops=1 : 10/10 perte + doublon), vert
// avec le correctif (flip+mémo+drapeau synchrones, attente, garde rename).
//
// Un appelant dont `_ensureLoaded()` a résolu sur l'ANCIENNE mémo (charge
// « en retrait » déjà terminée, appelée juste avant le bascule du verrou) ne
// peut plus être rattrapé par la mémo de la recharge : il a déjà sa permission
// d'écrire. Si de plus la recharge est lente (disque occupé), son `_persist`
// renomme sa table partielle AVANT que la recharge ait lu le fichier ->
// perte de ce qui était sur le disque, sans que `add` ait menti.
//
// On balaye les décalages de microtasks ET on retarde l'appel de chemin de la
// recharge (2e appel), ce qui est une latence réelle possible, pas un état
// fabriqué.

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
    appDir = await Directory.systemTemp.createTemp('vox_btp10');
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

  const script =
      'import fcntl, sys, time\n'
      'fd = open(sys.argv[1], "a+")\n'
      'fcntl.lockf(fd, fcntl.LOCK_EX)\n'
      'print("LOCKED", flush = True)\n'
      'time.sleep(120)\n';

  for (final hops in [0, 1, 2, 3, 4]) {
    test('BTP10 hops=$hops + recharge lente : la victime qui a déjà sa '
        'permission ne doit JAMAIS écraser ce qui est sur le disque', () async {
      const trials = 10;
      var perte = 0, doublon = 0;
      String? premier;
      for (var t = 0; t < trials; t++) {
        queueFile().writeAsStringSync(jsonEncode(<Object?>[item('g|sms')]));
        final holder = await Process.start('python3', [
          '-c',
          script,
          lockFile().path,
        ]);
        final first = await holder.stdout.transform(const Utf8Decoder()).first;
        expect(first, contains('LOCKED'));
        final q = WebhookQueue.forTest(
          postRaw: (_) async => false,
          desktopLock: true,
        );
        await q.flush(force: true);
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
          var v = Future<void>.value();
          for (var k = 0; k < hops; k++) {
            v = v.then((_) => Future<void>.microtask(() {}));
          }
          unawaited(v.then((_) => q.add('victime|sms')));
          await Future<void>.delayed(const Duration(milliseconds: 80));
          gate.complete(appDir.path);
          await Future<void>.delayed(const Duration(milliseconds: 120));
        } finally {
          if (!gate.isCompleted) gate.complete(appDir.path);
        }

        final bodies = bodiesOnDisk();
        if (!bodies.contains('g|sms')) {
          perte++;
          premier ??= 'hops=$hops t=$t PERTE g bodies=$bodies len=${q.length}';
        }
        if (bodies.toSet().length != bodies.length) {
          doublon++;
          premier ??= 'hops=$hops t=$t DOUBLON bodies=$bodies';
        }
        q.stop();
      }
      if (premier != null) stderr.writeln('REPRO: $premier');
      expect(
        perte,
        0,
        reason: '$perte/$trials pertes de la graine à hops=$hops',
      );
      expect(doublon, 0, reason: '$doublon/$trials doublons à hops=$hops');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
