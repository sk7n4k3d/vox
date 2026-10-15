import 'dart:async';

import 'package:fluffychat/utils/rtc/rtc_call.dart';
import 'package:fluffychat/utils/rtc/rtc_membership.dart';
import 'package:fluffychat/utils/rtc/rtc_sfu_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);

DateTime _plus(Duration d) => _t0.add(d);

class FakeGateway implements RtcMediaGateway {
  final remote = StreamController<RtcRemoteEvent>.broadcast();
  int connects = 0;
  int disposals = 0;
  bool startAudio = false, startVideo = false;

  @override
  Future<void> connect(SfuCredentials c) async => connects++;

  @override
  Future<void> startMedia({required bool audio, required bool video}) async {
    startAudio = audio;
    startVideo = video;
  }

  @override
  Future<void> publish() async {}

  @override
  Stream<RtcRemoteEvent> get remoteEvents => remote.stream;

  @override
  Future<void> dispose() async => disposals++;
  @override
  Future<void> setAudioMuted(bool muted) async {}

  @override
  Future<void> setCameraMuted(bool muted) async {}

  @override
  Future<void> flipCamera() async {}
}

class FakePublisher implements RtcMembershipPublisher {
  final published = <Map<String, Object?>>[];
  int retracted = 0;

  @override
  Future<void> publish(Map<String, Object?> content) async =>
      published.add(content);

  @override
  Future<void> retract() async => retracted++;
}

/// RtcSfuClient dont on compte les tentatives ; [failuresBefore] = nombre de
/// rejets SfuAuthException avant de réussir (-1 = échoue toujours).
class _CountingSfu {
  int attempts = 0;
  final int failuresBefore;
  _CountingSfu({this.failuresBefore = 0});

  RtcSfuClient build() => RtcSfuClient(
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
    plainPost: (_, __) async {
      attempts++;
      if (failuresBefore < 0 || attempts <= failuresBefore) {
        throw const SfuAuthException('M_UNKNOWN_TOKEN', 'expired');
      }
      return {'url': 'wss://lk.s', 'jwt': 'j'};
    },
  );
}

/// File de callbacks planifiés, horloge à la main.
class FakeScheduler implements RtcScheduler {
  final _jobs = <(DateTime, Future<void> Function())>[];
  Duration _offset = Duration.zero;
  DateTime Function() get _clock => () => _t0.add(_offset);

  @override
  RtcTimerHandle schedule(Duration delay, Future<void> Function() task) {
    final due = _clock().add(delay);
    final job = (due, task);
    _jobs.add(job);
    return () => _jobs.remove(job);
  }

  Future<void> advance(Duration d) async {
    _offset += d;
    final due = _jobs.where((j) => !j.$1.isAfter(_clock())).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    for (final j in due.toList()) {
      _jobs.remove(j);
      await j.$2();
    }
  }
}

RtcSessionMembership _remote({
  String userId = '@noemie:s',
  String deviceId = 'N1',
  DateTime? ts,
  int expiresMs = 3600000,
}) => RtcSessionMembership(
  userId: userId,
  deviceId: deviceId,
  callId: '',
  application: 'm.call',
  expiresMs: expiresMs,
  membershipId: 'm',
  originServerTs: ts ?? _t0,
  fociPreferred: const [
    RtcFocus(type: 'livekit', livekitServiceUrl: 'https://lk.s'),
  ],
);

({
  RtcCall call,
  FakeGateway gateway,
  FakePublisher publisher,
  FakeScheduler scheduler,
  List<CallState> seen,
}) _makeCall({
  bool wantVideo = false,
  int sfuFailures = 0,
}) {
  final gateway = FakeGateway();
  final publisher = FakePublisher();
  final scheduler = FakeScheduler();
  final seen = <CallState>[];
  final call = RtcCall(
    roomId: '!dm:s',
    wantVideo: wantVideo,
    localUserId: '@moi:s',
    localDeviceId: 'D',
    sfu: _CountingSfu(failuresBefore: sfuFailures).build(),
    gateway: gateway,
    memberships: publisher,
    now: () => _t0,
    scheduler: scheduler,
  );
  call.onStateChanged.listen(seen.add);
  return (
    call: call,
    gateway: gateway,
    publisher: publisher,
    scheduler: scheduler,
    seen: seen,
  );
}

Future<void> _pump() => pumpEventQueue();

void main() {
  test('sortant : credentials → media → membership → ringingOut', () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    expect(c.call.state, CallState.ringingOut);
    expect(c.gateway.connects, 1);
    expect(c.gateway.startAudio, isTrue);
    expect(c.publisher.published, hasLength(1));
    // la membership publiée porte les champs réseau attendus (forme plate)
    final entry = c.publisher.published.single;
    expect(entry['device_id'], 'D');
    expect(entry['application'], 'm.call');
    expect(entry['m.call.intent'], 'audio');
  });

  test('sortant : membership distante → active', () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    c.call.onRemoteMembership(_remote());
    await _pump();
    expect(c.call.state, CallState.active);
  });

  test('entrant : onRemoteMembership → ringingIn, accept → active sur mediaReady',
      () async {
    final c = _makeCall();
    c.call.onRemoteMembership(_remote());
    await _pump();
    expect(c.call.state, CallState.ringingIn);
    await c.call.accept();
    await _pump();
    c.gateway.remote.add(RtcRemoteEvent.mediaReady);
    await _pump();
    expect(c.call.state, CallState.active);
    expect(c.publisher.published, hasLength(1));
  });

  test('hangup : retract + gateway disposed + ended', () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    await c.call.hangup();
    expect(c.call.state, CallState.ended);
    expect(c.publisher.retracted, 1);
    expect(c.gateway.disposals, 1);
  });

  test('pair qui part → ended propre', () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    c.call.onRemoteMembership(_remote());
    await _pump();
    c.gateway.remote.add(RtcRemoteEvent.peerLeft);
    await _pump();
    expect(c.call.state, CallState.ended);
    expect(c.publisher.retracted, 1);
  });

  test('refresh : republie à la moitié de expires et reprogramme', () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    expect(c.publisher.published, hasLength(1));
    await c.scheduler.advance(const Duration(minutes: 31));
    expect(c.publisher.published, hasLength(2));
    await c.scheduler.advance(const Duration(minutes: 31));
    expect(c.publisher.published, hasLength(3));
  });

  test('SFU 401 une fois → retry unique, appel sauvé', () async {
    final c = _makeCall(sfuFailures: 1);
    await c.call.start();
    await _pump();
    expect(c.call.state, CallState.ringingOut);
  });

  test('SFU 401 persistant → failed après 2 tentatives, pas de boucle',
      () async {
    final counting = _CountingSfu(failuresBefore: -1);
    final gateway = FakeGateway();
    final call = RtcCall(
      roomId: '!dm:s',
      wantVideo: false,
      localUserId: '@moi:s',
      localDeviceId: 'D',
      sfu: counting.build(),
      gateway: gateway,
      memberships: FakePublisher(),
      now: () => _t0,
      scheduler: FakeScheduler(),
    );
    await call.start();
    await _pump();
    expect(call.state, CallState.failed);
    expect(counting.attempts, 2);
    expect(gateway.connects, 0);
  });

  test('glare (a) : distant pendant ringingOut → on garde le sortant, active',
      () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    c.call.onRemoteMembership(_remote());
    await _pump();
    expect(c.call.state, CallState.active);
    expect(c.publisher.retracted, 0);
  });

  test('glare (b) : distant avant notre publication → on cède, ended',
      () async {
    final c = _makeCall();
    final started = c.call.start();
    c.call.onRemoteMembership(_remote());
    await started;
    await _pump();
    expect(c.seen, contains(CallState.ended));
  });

  test('membership de notre propre userId → ignorée', () async {
    final c = _makeCall();
    c.call.onRemoteMembership(_remote(userId: '@moi:s', deviceId: 'AUTRE'));
    await _pump();
    expect(c.call.state, CallState.idle);
  });

  test('membership déjà expirée → ignorée', () async {
    final c = _makeCall();
    c.call.onRemoteMembership(
      _remote(ts: _plus(const Duration(hours: -2)), expiresMs: 60000),
    );
    await _pump();
    expect(c.call.state, CallState.idle);
  });

  test('vidéo : startMedia video=true', () async {
    final c = _makeCall(wantVideo: true);
    await c.call.start();
    await _pump();
    expect(c.gateway.startVideo, isTrue);
  });

  test('accept sans ringingIn → no-op', () async {
    final c = _makeCall();
    await c.call.accept();
    expect(c.call.state, CallState.idle);
    expect(c.gateway.connects, 0);
  });

  test('accept : rejoint le focus publie par le pair, pas le notre', () async {
    // bien-known local -> https://lk.s ; la membership, elle, pointe ailleurs
    var posts = <String>[];
    final sfu = RtcSfuClient(
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
      plainPost: (uri, body) async {
        posts.add(uri.toString());
        return {'url': 'wss://their-lk.s', 'jwt': 'j2'};
      },
    );
    final gateway = FakeGateway();
    final call = RtcCall(
      roomId: '!dm:s',
      wantVideo: false,
      localUserId: '@moi:s',
      localDeviceId: 'D',
      sfu: sfu,
      gateway: gateway,
      memberships: FakePublisher(),
      now: () => _t0,
      scheduler: FakeScheduler(),
    );
    call.provideFoci([
      const RtcFocus(type: 'livekit', livekitServiceUrl: 'https://their-lk.s'),
    ]);
    call.onRemoteMembership(_remote());
    await pumpEventQueue();
    expect(call.state, CallState.ringingIn);
    await call.accept();
    await pumpEventQueue();
    expect(posts, ['https://their-lk.s/sfu/get']);
  });

  test('sortant : sans pair connu, utilise le focus du bien-known local',
      () async {
    final c = _makeCall();
    await c.call.start();
    await _pump();
    expect(c.call.state, CallState.ringingOut);
  });
}
