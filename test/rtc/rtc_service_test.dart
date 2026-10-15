import 'dart:async';

import 'package:fluffychat/utils/rtc/rtc_call.dart';
import 'package:fluffychat/utils/rtc/rtc_membership.dart';
import 'package:fluffychat/utils/rtc/rtc_service.dart';
import 'package:fluffychat/utils/rtc/rtc_sfu_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);

class _FakePort implements RtcSessionPort {
  final incoming = <RtcIncomingEvent>[];
  final published = <String, List<Map<String, Object?>>>{};
  final retracted = <String>[];
  final joinedRooms = <String>{'!dm:s'};
  bool available = true;

  @override
  String get userId => '@moi:s';
  @override
  String get deviceId => 'VOXDEV';
  @override
  Stream<RtcIncomingEvent> get membershipEvents => _membership.stream;
  final _membership = StreamController<RtcIncomingEvent>.broadcast();

  @override
  Future<bool> isRoomJoined(String roomId) async =>
      joinedRooms.contains(roomId);

  @override
  Future<void> publishMembership(
    String roomId,
    Map<String, Object?> content,
  ) async => (published[roomId] ??= []).add(content);

  @override
  Future<void> retractMembership(String roomId) async =>
      retracted.add(roomId);

  @override
  Future<RtcSfuClient?> sfuClient() async => available
      ? RtcSfuClient(
          homeserver: Uri.parse('https://matrix.sk7.sh'),
          userId: userId,
          deviceId: deviceId,
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
        )
      : null;
}

class _Gateway implements RtcMediaGateway {
  final remote = StreamController<RtcRemoteEvent>.broadcast();
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
  Future<void> setAudioMuted(bool muted) async {}
  @override
  Future<void> setCameraMuted(bool muted) async {}
  @override
  Future<void> flipCamera() async {}
}

Map<String, Object?> _content({
  String deviceId = 'N1',
  String callId = '',
  int expires = 3600000,
}) => {
  'calls': [
    {
      'application': 'm.call',
      'scope': 'm.room',
      'call_id': callId,
      'device_id': deviceId,
      'expires': expires,
      'membershipID': 'x-$deviceId',
      'foci_preferred': [
        {'type': 'livekit', 'livekit_service_url': 'https://lk.s'},
      ],
    },
  ],
};

void main() {
  late _FakePort port;
  late RtcService service;
  final incomingShown = <RtcCall>[];
  final gateways = <_Gateway>[];

  setUp(() {
    port = _FakePort();
    incomingShown.clear();
    gateways.clear();
    service = RtcService(
      port: port,
      gatewayFactory: () => _Gateway(),
      now: () => _t0,
      scheduler: _Noop(),
      onIncoming: (call) => incomingShown.add(call),
    );
  });
  tearDown(() => service.shutdown());

  Future<void> deliver({
    String roomId = '!dm:s',
    String sender = '@noemie:s',
    Map<String, Object?>? content,
    DateTime? ts,
  }) async {
    await service.handleMembershipEvent(
      RtcIncomingEvent(
        roomId: roomId,
        senderId: sender,
        content: content ?? _content(),
        originServerTs: ts ?? _t0,
      ),
    );
    await pumpEventQueue();
  }

  test('entrant valide dans une DM rejointe → onIncoming une seule fois',
      () async {
    await deliver();
    await deliver(); // deuxième event du même pair : pas de doublon
    expect(incomingShown, hasLength(1));
    expect(service.currentCall?.state, CallState.ringingIn);
  });

  test('deux devices du même user dans un event → un seul appel', () async {
    await deliver(
      content: {
        'calls': [
          ...(_content()['calls']! as List).cast<Map<String, Object?>>(),
          ...( _content(deviceId: 'N2')['calls']! as List)
              .cast<Map<String, Object?>>(),
        ],
      },
    );
    expect(incomingShown, hasLength(1));
  });

  test('events de notre propre compte → ignorés', () async {
    await deliver(sender: '@moi:s');
    expect(incomingShown, isEmpty);
    expect(service.currentCall, isNull);
  });

  test('room non rejointe / membership expirée → ignorés', () async {
    await deliver(roomId: '!inconnu:s');
    await deliver(
      ts: _t0.subtract(const Duration(hours: 2)),
      content: _content(expires: 60000),
    );
    expect(incomingShown, isEmpty);
  });

  test('pair qui retire sa presence pendant ringingIn → appel annulé',
      () async {
    await deliver();
    final call = service.currentCall!;
    await deliver(content: {'calls': <Object?>[]});
    expect(call.state, CallState.ended);
    expect(service.currentCall, isNull);
  });

  test('sortant : published porte notre device et retract a la fin', () async {
    final call = (await service.outgoingCall(roomId: '!dm:s', video: false))!;
    await call.start();
    await pumpEventQueue();
    expect(port.published['!dm:s'], hasLength(1));
    final entry = port.published['!dm:s']!.single;
    expect(entry['device_id'], 'VOXDEV');
    await call.hangup();
    expect(port.retracted, ['!dm:s']);
  });

  test('rtcAvailable : reflète la présence dun focus annonce', () async {
    final off = RtcService(
      port: _FakePort()..available = false,
      gatewayFactory: () => _Gateway(),
    );
    expect(await off.rtcAvailable(), isFalse);
    await off.shutdown();
    final on = RtcService(
      port: _FakePort(),
      gatewayFactory: () => _Gateway(),
    );
    expect(await on.rtcAvailable(), isTrue);
    await on.shutdown();
  });

  test('les présences vivantes sont suivies par room avec leur focus',
      () async {
    await deliver();
    final peers = service.remotePeersOf('!dm:s');
    expect(peers.map((p) => p.deviceId), ['N1']);
    // M1 : Element X publie son propre SFU dans foci_preferred
    expect(
      peers.single.fociPreferred.single.livekitServiceUrl,
      'https://lk.s',
    );
  });

  test('rtcAvailable ne se fige pas sur un premier echec', () async {
    final flaky = _FakePort()..available = false;
    final svc = RtcService(port: flaky, gatewayFactory: () => _Gateway());
    expect(await svc.rtcAvailable(), isFalse);
    flaky.available = true;
    expect(await svc.rtcAvailable(), isTrue);
    await svc.shutdown();
  });

  test('deuxieme appel pendant un appel actif → ignore, rien ne se publie',
      () async {
    await deliver();
    final call = service.currentCall!;
    await call.accept();
    await pumpEventQueue();
    expect(call.state, CallState.connecting);
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
    await deliver(
      roomId: '!autre:s',
      content: _content(deviceId: 'Z9'),
    );
    expect(port.published['!autre:s'], isNull);
    expect(service.currentCall?.state, CallState.connecting);
  });
}

class _Noop implements RtcScheduler {
  @override
  RtcTimerHandle schedule(Duration delay, Future<void> Function() task) =>
      () {};
}
