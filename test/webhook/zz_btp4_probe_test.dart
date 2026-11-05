// Sondes blue-team (audit ade1b6ba), versions dépôt — btp4 : instantané
// « .part » tronqué par une coupure d'alimentation.
//
// PROVENANCE : l'original (H15) DEMONTRAIT la destruction silencieuse — son
// assertion passait quand le fichier tronqué était supprimé sans copie. Le
// correctif la retourne : ce fichier asserte que le tronqué est ARCHIVÉ,
// compté, et jamais rescan né comme un .part (rapport §1 finding 1).

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
    appDir = await Directory.systemTemp.createTemp('vox_btp4');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appDir.path,
        );
  });

  tearDown(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  int modeOf(File f) => f.statSync().mode & 0x1ff;

  test('H15 (contrat) : .part tronqué (snapshot partiel porteur de messages '
      'jamais envoyés) est copié en « part-illisible », compté, jamais '
      'détruit ni rescan né', () async {
    final fresh = DateTime.now().millisecondsSinceEpoch;
    queueFile().writeAsStringSync(
      jsonEncode(<Object?>[
        <String, Object?>{
          'raw_body': 'vivant|sms',
          'created_at_ms': fresh,
          'attempts': 0,
          'next_attempt_at_ms': 0,
        },
      ]),
    );
    // coupure de courant en plein renommage : JSON tronqué AU MILIEU d'un
    // deuxième corps — ces octets ne se décodent pas mais portent un
    // message réel, jamais envoyé
    final truncated =
        '[{"raw_body":"perdu|sms","created_at_ms":$fresh,"attempts":0,'
        '"next_attempt_at_ms":0},{"raw_bo';
    final part = File('${appDir.path}/webhook_queue.json.part.7.$fresh')
      ..writeAsStringSync(truncated);

    final posted = <String>[];
    final q = WebhookQueue.forTest(
      postRaw: (b) async {
        posted.add(b);
        return true;
      },
    );
    addTearDown(q.stop);
    await q.flush(force: true);

    // 1. les octets bruts sont INTACTS dans la copie d'archivage
    final archived = File('${appDir.path}/webhook_queue.json.part-illisible.1');
    expect(
      archived.existsSync(),
      isTrue,
      reason:
          'la copie existe AVANT toute disparition (l originale mesurait '
          'partSupprimé=true tracesPartout=[] : perte sèche)',
    );
    expect(archived.readAsStringSync(), truncated);
    expect(archived.readAsStringSync(), contains('perdu|sms'));
    expect(modeOf(archived), 0x180, reason: 'copie en 600 : corps clair');
    // 2. l original a été déplacé (la copie en tient lieu), pas éliminé
    expect(
      part.existsSync(),
      isFalse,
      reason: 'suppression SEULEMENT après copie réussie',
    );
    // 3. c est compté, pas muet
    expect(
      q.corruptCount,
      greaterThanOrEqualTo(1),
      reason:
          'visible dans les compteurs : un boot qui avale des données doit '
          'laisser une trace chiffrée',
    );
    // 4. la file vivante tourne : seul le décodable part
    expect(posted, ['vivant|sms']);

    // 5. boot suivant : la copie « part-illisible » ne repasse PAS dans le
    // scanner des .part (sinon rotation à l'infini à chaque lancement)
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
    expect(
      File('${appDir.path}/webhook_queue.json.part-illisible.2').existsSync(),
      isFalse,
      reason: 'aucune resauvegarde : la cible vit hors de l espace « .part. »',
    );
    expect(
      archived.existsSync(),
      isTrue,
      reason:
          'la copie d un boot reste la copie du suivant — la purge de ces '
          'copies relève d une demande explicite, jamais d un boot',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('H15b (contrat) : troncature du fichier PRINCIPAL illisible + .part '
      'tronqué -> les DEUX épaves sont archivées, aucune perte même quand '
      'tout est illisible', () async {
    // racine JSON valide mais PAS une liste : le décodage « réussit » et
    // la validation de forme échoue -> chemin épave principale
    queueFile().writeAsStringSync('{"racine":"pas une liste"}');
    File(
      '${appDir.path}/webhook_queue.json.part.2.555',
    ).writeAsStringSync('[{"raw_body');
    final q = WebhookQueue.forTest(postRaw: (_) async => true);
    addTearDown(q.stop);
    await q.flush(force: true);

    // épave principale : copie « corrompu » (comportement préexistant)
    expect(
      File('${appDir.path}/webhook_queue.json.corrompu.1').existsSync(),
      isTrue,
      reason:
          'le fichier principal illisible est copié avant d être '
          'remplacé — et le .part tronqué l est aussi (l originale ne '
          'trouvait aucune trace du second)',
    );
    final partCopy = File('${appDir.path}/webhook_queue.json.part-illisible.1');
    expect(partCopy.existsSync(), isTrue);
    expect(partCopy.readAsStringSync(), '[{"raw_body');
    expect(q.corruptCount, greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
