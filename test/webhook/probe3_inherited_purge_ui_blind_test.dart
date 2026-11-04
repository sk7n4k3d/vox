// Sonde blue-team PROBE-3 (audit indépendant e98bb2a8), version dépôt.
//
// L'ORIGINAL (copié tel quel par l'audit) PRÉ-UVAIT la purge d'une file
// héritée hors budget au chargement : `heads == [h1, ne]` (h0 effacé du
// disque) et l'attente « dropped +1 » n'échouait que sur la visibilité UI.
// Corriger la perte (directive « ne supprimer aucun élément existant »)
// retourne donc ses assertions contre le code : comme P2/P4 de la sonde
// précédente, ce fichier teste désormais la GARANTIE INVERSE — rien d'hérité
// ne disparaît, les ajouts sont refusés tant que la file n'a pas drainé, et
// ce refus reste observable (compteur UI). Les faits prouvés par la sonde
// originale (purge réelle, UI muette, chemin de boot matrix.dart:314) ne
// sont pas niés : ils sont corrigés.

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appDir = await Directory.systemTemp.createTemp('vox_probe3');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  /// File héritée : 2 × 14 MiB = 28 MiB > budget 26 MiB, dates au
  /// présent (on teste le budget, pas l'expiration TTL).
  Future<void> seedInherited() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = List.generate(2, (i) {
      return <String, Object?>{
        'raw_body': 'h$i|'.padRight(14 * 1024 * 1024, 'z'),
        'created_at_ms': now,
        'attempts': 0,
        'next_attempt_at_ms': 0,
      };
    });
    File(
      '${appDir.path}/webhook_queue.json',
    ).writeAsStringSync(jsonEncode(raw));
  }

  List<Object?> diskHeads() =>
      (jsonDecode(File('${appDir.path}/webhook_queue.json').readAsStringSync())
              as List)
          .cast<Map>()
          .map((m) => (m['raw_body'] as String).substring(0, 2))
          .toList();

  test('PROBE-3 (nouveau contrat) — file héritée : rien ne disparaît, pas '
      'même au premier persist', () async {
    await seedInherited();
    final statsBefore = WebhookService.instance.stats.value.dropped;

    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    // premier add = chargement + refus motivé (le budget est déjà dépassé
    // par les seuls héritiers)
    expect(await queue.add('ne|petit'), isFalse);
    expect(
      queue.length,
      2,
      reason:
          'les deux héritiers sont chargés en '
          'totalité : la purge au chargement est abolie',
    );
    expect(queue.overBudget, isTrue);
    expect(queue.droppedCount, 1);
    expect(
      WebhookService.instance.stats.value.dropped,
      statsBefore + 1,
      reason:
          'contrairement à la purge (UI muette, finding PROBE-3), le '
          'rejet arrive bien dans WebhookStats.dropped',
    );

    // Et le persist de ce refus n'a RIEN écrasé : le fichier porte toujours
    // h0 ET h1. C'était la perte définitive démontrée par l'audit.
    expect(
      diskHeads(),
      ['h0', 'h1'],
      reason:
          'PROBE-3 originale : heads [h1, ne] — h0 (événement jamais '
          'envoyé) effacé du disque. Interdit désormais.',
    );
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('PROBE-3b — la sursaturation se résout par envoi réussi, pas par '
      'destruction', () async {
    await seedInherited();
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);
    await queue.flush(force: true); // échec : tout reste, rien n'est purgé
    expect(queue.length, 2);
    expect(
      queue.overBudget,
      isTrue,
      reason: 'un échec ne vide pas la sursaturation : c\'est voulu',
    );
    expect(await queue.add('ne|petit'), isFalse);

    // Deuxième instance, serveur en face : les ENVOIS existants partent,
    // et le drain sous le seuil rouvre les ajouts — sans qu'aucune entrée
    // n'ait été supprimée « pour faire de la place ».
    final online = WebhookQueue.forTest(postRaw: (_) async => true);
    addTearDown(online.stop);
    await online.flush(force: true);
    expect(online.length, 0);
    expect(online.overBudget, isFalse);
    expect(await online.add('ne|petit'), isTrue);
    expect(diskHeads(), ['ne']);
  }, timeout: const Timeout(Duration(seconds: 240)));
}
