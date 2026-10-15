import 'dart:async';

import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:fluffychat/pages/call/livekit_call_controller.dart';
import 'package:fluffychat/utils/rtc/rtc_call.dart';
import 'package:fluffychat/utils/rtc/rtc_membership.dart';
import 'package:fluffychat/utils/rtc/rtc_sfu_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);

class _TestGateway implements RtcMediaGateway {
  final remote = StreamController<RtcRemoteEvent>.broadcast();
  final muteCalls = <bool>[];
  final cameraCalls = <bool>[];
  int flips = 0;

  @override
  Future<void> connect(SfuCredentials c) async {}
  @override
  Future<void> startMedia({required bool audio, required bool video}) async {}
  @override
  Future<void> publish() async {}
  @override
  Stream<RtcRemoteEvent> get remoteEvents => remote.stream;
  @override
  Future<void> dispose() async {}

  @override
  Future<void> setAudioMuted(bool muted) async => muteCalls.add(muted);
  @override
  Future<void> setCameraMuted(bool muted) async => cameraCalls.add(muted);
  @override
  Future<void> flipCamera() async => flips++;
  @override
  bool get hasRemoteMedia => false;
}

class _Publisher implements RtcMembershipPublisher {
  @override
  Future<String?> publish(Map<String, Object?> content) async => '\$E';
  @override
  Future<void> retract() async {}
  @override
  Future<void> notify(Map<String, Object?> content) async {}
}

/// Scheduler qui ignore les jobs : les tests d'UI ne testent pas le refresh
/// (timer réel = teardown propre).
class _NoopScheduler implements RtcScheduler {
  @override
  RtcTimerHandle schedule(Duration delay, Future<void> Function() task) =>
      () {};
}

RtcSfuClient _sfu() => RtcSfuClient(
  homeserver: Uri.parse('https://matrix.sk7.sh'),
  userId: '@moi:s',
  deviceId: 'D',
  plainGet: (_) async => {
    'org.matrix.msc4143.rtc_foci': [
      {'type': 'livekit', 'livekit_service_url': 'https://lk.s'},
    ],
  },
  openidToken: () async => {
    'access_token': 'oid',
    'token_type': 'Bearer',
    'matrix_server_name': 's',
    'expires_in': 3600,
    },
  plainPost: (_, __) async => {'url': 'wss://lk.s', 'jwt': 'j'},
);

class _Harness {
  final _TestGateway gateway;
  final RtcCall call;
  final LiveKitCallController controller;

  _Harness._(this.gateway, this.call, this.controller);

  static _Harness make({bool video = false}) {
    final gateway = _TestGateway();
    final call = RtcCall(
      roomId: '!dm:s',
      wantVideo: video,
      localUserId: '@moi:s',
      localDeviceId: 'D',
      sfu: _sfu(),
      gateway: gateway,
      memberships: _Publisher(),
      now: () => _t0,
      scheduler: _NoopScheduler(),
    );
    return _Harness._(
      gateway,
      call,
      LiveKitCallController(
        call: call,
        gateway: gateway,
        remoteName: 'Noémie',
        remoteMxid: '@noemie:s',
      ),
    );
  }

  /// Voie plain-`test()` (pas de WidgetTester) : pumpEventQueue suffit.
  Future<void> outgoingActivePlain() async {
    await call.start();
    await pumpEventQueue();
    call.onRemoteMembership(
      RtcSessionMembership(
        userId: '@noemie:s',
        deviceId: 'N1',
        callId: '',
        application: 'm.call',
        expiresMs: 3600000,
        membershipId: 'x',
        originServerTs: _t0,
        fociPreferred: const [],
      ),
    );
    await pumpEventQueue();
  }

  Future<void> outgoingActive(WidgetTester tester) async {
    await tester.runAsync(call.start);
    call.onRemoteMembership(
      RtcSessionMembership(
        userId: '@noemie:s',
        deviceId: 'N1',
        callId: '',
        application: 'm.call',
        expiresMs: 3600000,
        membershipId: 'x',
        originServerTs: _t0,
        fociPreferred: const [],
      ),
    );
    await settle(tester);
  }
}

Future<void> settle(WidgetTester t) =>
    t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));

Future<void> _openCallPage(WidgetTester tester, LiveKitCallController c) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ActiveCallPage(
        controller: c,
        remoteVideo: const SizedBox(key: Key('remote-slot')),
        localVideo: const SizedBox(key: Key('local-slot')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('micro coupé passe par la gateway LiveKit', (tester) async {
    final m = _Harness.make();
    await _openCallPage(tester, m.controller);
    await m.outgoingActive(tester);

    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(m.gateway.muteCalls, [true]);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic_off));
    await tester.pump();
    expect(m.gateway.muteCalls, [true, false]);
  });

  testWidgets('caméra coupée passe par la gateway (appel vidéo)',
      (tester) async {
    final m = _Harness.make(video: true);
    await _openCallPage(tester, m.controller);
    await m.outgoingActive(tester);

    await tester.tap(find.byIcon(Icons.videocam));
    await tester.pump();
    expect(m.gateway.cameraCalls, [true]);
    expect(find.byIcon(Icons.videocam_off), findsOneWidget);
  });

  testWidgets('raccrocher termine l appel et nettoie', (tester) async {
    final m = _Harness.make();
    await _openCallPage(tester, m.controller);
    await m.outgoingActive(tester);

    await tester.tap(find.byIcon(Icons.call_end));
    await settle(tester);
    expect(m.call.state, CallState.ended);
  });

  test('sortant → distant → actif : chrono et identité exposés', () async {
    final m = _Harness.make();
    expect(m.controller.connected, isFalse);
    await m.outgoingActivePlain();
    expect(m.call.state, CallState.active);
    expect(m.controller.connected, isTrue);
    expect(m.controller.connectedAt, isNotNull);
    expect(m.controller.remoteName, 'Noémie');
    expect(m.controller.remoteMxid, '@noemie:s');
    expect(m.controller.isVideo, isFalse);
    // les flux WrappedMediaStream (legacy) ne sont pas utilisés côté RTC
    expect(m.controller.localStream, isNull);
    expect(m.controller.remoteStream, isNull);
  });
}
