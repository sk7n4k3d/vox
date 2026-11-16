import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/video/video_bridge.dart';

/// Diagnostic NON destructif (2026-11-08) : deux ponts VideoBridge (un par
/// engine Flutter) partagent le compteur global de jobIds du natif (v1, v2…).
/// Le second bridge instancié ne reçoit JAMAIS l'event du premier job, dont
/// l'attente ne peut donc aboutir — la compression reste bloquée.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deux ponts = deux moteurs : le job v1 du pont UI ne remonte jamais',
      () async {
    final evUI = StreamController<dynamic>.broadcast();
    final evBG = StreamController<dynamic>.broadcast();
    final bridgeUI = VideoBridge(
        timeout: const Duration(minutes: 5), eventSource: evUI.stream);
    // moteur background (UnifiedPush headless) qui s'instancie en parallèle
    final bridgeBG = VideoBridge(
        timeout: const Duration(minutes: 5), eventSource: evBG.stream);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('eu.devlabz.vox/video'),
      (call) async => {'jobId': 'v1'},
    );

    await bridgeUI.start('/tmp/ui.mp4', compress: true);

    var settledUI = false;
    unawaited(bridgeUI.waitFor('v1').then((_) => settledUI = true));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(settledUI, isFalse); // attente réelle sur l'UI

    // L'autre moteur (background) s'abonne au même canal — le job UI vit
    // dans son EventChannel, pas dans celui de l'UI.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(
      settledUI,
      isFalse,
      reason: 'le pont UI ne voit jamais la fin du job : il tourne sur un '
          'autre moteur (détachage/recréation d’engine en cours de job)',
    );
    bridgeUI.dispose();
    bridgeBG.dispose();
  });

  test('engine UI tué en cours de job : le moteur de backup encaisse la fin, '
      'l\'UI attend à vie', () async {
    final evUI = StreamController<dynamic>.broadcast();
    final evBG = StreamController<dynamic>.broadcast();
    final bridgeUI = VideoBridge(
        timeout: const Duration(days: 1), // pas de timeout → reproduction pure
        eventSource: evUI.stream);
    final bridgeBG = VideoBridge(
        timeout: const Duration(days: 1), eventSource: evBG.stream);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('eu.devlabz.vox/video'),
      (call) async => {'jobId': 'v3'},
    );

    await bridgeUI.start('/tmp/video.mp4', compress: true);

    var done = false;
    unawaited(bridgeUI.waitFor('v3').then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(done, isFalse);

    // L'engine UI est tué : son EventChannel ne reçoit plus rien (on ne
    // diffuse AUCUN event sur evUI). Le job se termine sur le moteur de
    // backup, qui lui reçoit l'event.
    evBG.add({'kind': 'done', 'jobId': 'v3', 'outputPath': '/tmp/out.mp4',
        'width': 1920, 'height': 1080, 'durationMs': 1000,
        'sizeBytes': 123, 'passthrough': false});
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // Le moteur de backup a vu la fin du job…
    expect(await bridgeBG.resultFor('v3'), isNotNull);
    // …l'UI est toujours bloquée (attend l'event sur SON canal).
    expect(done, isFalse,
        reason: 'le pont UI ne reçoit jamais le done du job : engine tué en '
            'cours de compression → attente sans fin côté interface');

    evUI.close();
    evBG.close();
    bridgeUI.dispose();
    bridgeBG.dispose();
  });
}
