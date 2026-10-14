import 'package:fluffychat/pages/call/voip_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const MethodChannel channel = MethodChannel('eu.devlabz.vox/voip');
const String eventChannel = 'eu.devlabz.vox/voip_events';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void mockNative({Future<Object?> Function(MethodCall)? handler}) {
    messenger.setMockMethodCallHandler(
      channel,
      handler ??
          (call) async {
            calls.add(call);
            if (call.method == 'currentAudioRoute') return 'bluetooth';
            return true;
          },
    );
  }

  setUp(() {
    calls.clear();
    mockNative();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('appels Dart → natif', () {
    test('startPersistentService invoque la bonne méthode', () async {
      expect(await VoipBridge().startPersistentService(), isTrue);
      expect(calls.single.method, 'startPersistentService');
    });

    test('stopPersistentService invoque la bonne méthode', () async {
      expect(await VoipBridge().stopPersistentService(), isTrue);
      expect(calls.single.method, 'stopPersistentService');
    });

    test('chaque route audio est envoyée au natif sous son nom', () async {
      final bridge = VoipBridge();
      for (final route in AudioRoute.values) {
        calls.clear();
        await bridge.setAudioRoute(route);
        expect(calls.single.method, 'setAudioRoute');
        expect(calls.single.arguments['route'], route.wireName);
      }
      expect(AudioRoute.values.map((r) => r.wireName),
          ['speaker', 'earpiece', 'wired', 'bluetooth']);
    });

    test('currentAudioRoute relit la valeur du natif', () async {
      expect(await VoipBridge().currentAudioRoute(), 'bluetooth');
    });

    test('requestCallPermissions renvoie le booléen natif', () async {
      expect(await VoipBridge().requestCallPermissions(), isTrue);
      expect(calls.single.method, 'requestCallPermissions');
    });

    test('isCallPermissionGranted envoie le nom court', () async {
      await VoipBridge().isCallPermissionGranted('audio');
      await VoipBridge().isCallPermissionGranted('camera');
      expect(calls.map((c) => c.arguments['permission']), ['audio', 'camera']);
    });

    test('startRinging transmet le flag vidéo', () async {
      await VoipBridge().startRinging(video: true);
      expect(calls.single.method, 'startRinging');
      expect(calls.single.arguments['video'], isTrue);
    });
  });

  group('robustesse du pont', () {
    test('un PlatformException ne fait pas planter, renvoie false', () async {
      mockNative(
        handler: (call) async => throw PlatformException(code: 'VOIP_ERR'),
      );

      expect(await VoipBridge().startPersistentService(), isFalse);
      expect(await VoipBridge().setAudioRoute(AudioRoute.speaker), isFalse);
    });

    test('un MissingPluginException rend false au lieu de lever', () async {
      mockNative(
        handler: (call) async => throw MissingPluginException(),
      );

      expect(await VoipBridge().stopPersistentService(), isFalse);
    });

    test('un currentAudioRoute qui échoue retombe sur le contre-oreille', () async {
      mockNative(
        handler: (call) async => throw PlatformException(code: 'X'),
      );

      expect(await VoipBridge().currentAudioRoute(), 'earpiece');
    });
  });

  group('événements natif → Dart', () {
    Future<VoipEvent> emit(Map<String, dynamic> payload) async {
      final pending = VoipBridge().eventStream.first;
      await messenger.handlePlatformMessage(
        eventChannel,
        const StandardMethodCodec().encodeSuccessEnvelope(payload),
        (_) {},
      );
      return pending;
    }

    test('incoming_call est exposé avec tous ses champs', () async {
      final event = await emit({
        'kind': 'incoming_call',
        'callId': 'c1',
        'roomId': '!r1:sk7.sh',
        'callerName': 'Alice',
        'video': true,
      });

      expect(event.kind, VoipEventKind.incomingCall);
      expect(event.callId, 'c1');
      expect(event.roomId, '!r1:sk7.sh');
      expect(event.callerName, 'Alice');
      expect(event.video, isTrue);
    });

    test('audio_route est exposé avec sa route', () async {
      final event = await emit({'kind': 'audio_route', 'route': 'bluetooth'});

      expect(event.kind, VoipEventKind.audioRoute);
      expect(event.route, 'bluetooth');
    });

    test('service_killed est exposé', () async {
      final event = await emit({'kind': 'service_killed'});

      expect(event.kind, VoipEventKind.serviceKilled);
    });

    test('un event inconnu ne fait pas planter le flux', () async {
      final event = await emit({'kind': 'quelque_chose_dautre'});

      expect(event.kind, VoipEventKind.unknown);
    });
  });
}