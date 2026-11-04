// Sonde blue-team PROBE-4 (audit indépendant e98bb2a8), version dépôt.
//
// L'ORIGINAL (copié tel quel par l'audit) balayait des délais pour PRIVER
// la course : disque = snapshot périmé du flush, mémoire = 2 entrées — le
// marker ajouté par l'add concurrent écrasé du fichier (HIT à 15 ms sur
// cette machine, btrfs). La correction chaîne les écritures : un seul file
// d'attente de persist, contenu ré-encodé À L'EXÉCUTION (jamais capturé
// avant l'attente), séquence monotonne en garde. Le contrat devient « le
// dernier état gagne, toujours » — ce fichier l'vérifie sur le même
// balayage, en incluant le point de 15 ms qui déclenchait le HIT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // systemTemp de la machine. La fenêtre write+fsync de ~20 Mo qui produisait
    // le HIT est plus large sur disque physique (l'audit l'a mesurée à 15 ms
    // sur btrfs) ; sur tmpfs elle se resserre sans se fermer par le code —
    // c'est précisément pourquoi la correction est structurelle (file
    // d'écritures) et pas chronométrée.
    root = await Directory.systemTemp.createTemp('vox_probe4_fixed');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<({bool lost, int diskLen, int memLen, bool accepted})> trial(
    int id,
    Duration insertDelay,
  ) async {
    final dir = Directory('${root.path}/t$id')..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => dir.path);
    final big = 'bg|${'B' * (20 * 1024 * 1024)}';
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    try {
      expect(await queue.add(big), isTrue);
      final flushing = queue.flush(force: true);
      await Future<void>.delayed(insertDelay);
      final marker = '{"m":$id}';
      final accepted = await queue.add(marker);
      await flushing;
      final onDisk =
          jsonDecode(
                await File('${dir.path}/webhook_queue.json').readAsString(),
              )
              as List;
      final has = onDisk.cast<Map>().any(
        (m) => (m['raw_body'] as String).contains('"m":$id'),
      );
      return (
        lost: accepted && !has,
        diskLen: onDisk.length,
        memLen: queue.length,
        accepted: accepted,
      );
    } finally {
      queue.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  test('PROBE-4 (nouveau contrat) — persist sérialisé : aucun ajout récent '
      'jamais écrasé par un snapshot périmé', () async {
    var id = 0;
    var hits = 0;
    var refus = 0;
    final lines = <String>[];
    // Balayage autour du point mesuré par l'audit (HIT à 15 ms, ×2 reps) :
    // la chaîne doit faire gagner le dernier état sur TOUT le balayage.
    for (var offMs = 5; offMs <= 30; offMs += 5) {
      for (var rep = 0; rep < 2; rep++) {
        final r = await trial(id++, Duration(milliseconds: offMs));
        if (!r.accepted) {
          refus++;
          continue;
        }
        if (r.lost) {
          hits++;
          lines.add(
            'HIT delay=${offMs}ms rep=$rep : disque=${r.diskLen}, '
            'mémoire=${r.memLen}',
          );
        }
      }
    }
    // ignore: avoid_print
    print(
      'PROBE-4 (fix): trials=${id - refus} refusés=$refus HIT=$hits '
      '${lines.join('\n')}',
    );
    expect(
      hits,
      0,
      reason:
          'finding PROBE-4 : le rename périmé écrasait '
          'l ajout le plus récent (HIT à 15 ms). La file de persist doit le '
          'faire disparaître sur tout le balayage.',
    );
    // et quand l'ajout est accepté, disque et mémoire concordent toujours
    expect(
      refus,
      0,
      reason:
          '20 Mo + ~10 o tiennent sous le budget : tous '
          'les adds doivent être acceptés',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('PROBE-4b — flush et add réellement concourants : le fichier porte '
      'bien les deux', () async {
    final dir = Directory('${root.path}/seq')..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => dir.path);
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.add('{"event_id":"premier"}');
    final flushing = queue.flush(force: true);
    final adding = queue.add('{"event_id":"second"}');
    await adding;
    await flushing;
    expect(queue.length, 2);
    final onDisk =
        jsonDecode(File('${dir.path}/webhook_queue.json').readAsStringSync())
            as List;
    final bodies = onDisk
        .cast<Map>()
        .map((m) => m['raw_body'] as String)
        .toList();
    expect(
      bodies,
      containsAll(['{"event_id":"premier"}', '{"event_id":"second"}']),
      reason:
          'le dernier instantané sérialisé contient les deux corps : '
          'jamais le snapshot d avant l ajout',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
