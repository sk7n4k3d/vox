import 'package:fluffychat/utils/rtc/rtc_membership.dart';
import 'package:fluffychat/utils/rtc/rtc_sfu_client.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime.utc(2026, 10, 15, 12);

Map<String, Object?> _session({
  String callId = '',
  String deviceId = 'NOEMIE1',
  Object? expires = 3600000,
  String membershipID = 'mem-1',
  List<Object?>? foci,
}) => {
  'application': 'm.call',
  'call_id': callId,
  'device_id': deviceId,
  'scope': 'm.room',
  if (expires != null) 'expires': expires,
  'membershipID': membershipID,
  'foci_preferred':
      foci ??
      [
        {
          'type': 'livekit',
          'livekit_service_url': 'https://matrix-rtc.sk7.sh',
        },
      ],
};

void main() {
  group('parseMembershipEvent', () {
    test('forme tableau calls[] (publiée par Element)', () {
      final members = parseMembershipEvent(
        {
          'calls': [_session()],
        },
        '@noemie:matrix.sk7.sh',
        t0,
      );
      expect(members, hasLength(1));
      final m = members.single;
      expect(m.userId, '@noemie:matrix.sk7.sh');
      expect(m.deviceId, 'NOEMIE1');
      expect(m.callId, '');
      expect(m.application, 'm.call');
      expect(m.expiresMs, 3600000);
      expect(m.membershipId, 'mem-1');
      expect(m.originServerTs, t0);
      expect(m.fociPreferred.single.type, 'livekit');
      expect(m.isImplicitRoomCall, isTrue);
      expect(m.isExpiredAt(t0.add(const Duration(minutes: 59))), isFalse);
      expect(m.isExpiredAt(t0.add(const Duration(hours: 2))), isTrue);
    });

    test('forme plate SessionMembershipData', () {
      final members = parseMembershipEvent(
        _session(deviceId: 'ALICE2'),
        '@alice:matrix.sk7.sh',
        t0,
      );
      expect(members.single.deviceId, 'ALICE2');
    });

    test('contenus invalides → liste vide, jamais de crash', () {
      for (final bad in [
        <String, Object?>{},
        {
          'calls': 'pasuneListe',
        },
        {
          'calls': [<Object?>{}],
        },
        {
          'calls': [
            {'call_id': ''}, // ni device_id ni application
          ],
        },
        {'device_id': 'X'}, // plate sans application
      ]) {
        expect(
          parseMembershipEvent(bad, '@x:y', t0),
          isEmpty,
          reason: 'sur $bad',
        );
      }
    });

    test('event sticky msc4143 ignoré proprement', () {
      expect(
        parseMembershipEvent(
          {
            'slot_id': 'm.call#ROOM',
            'member': {'id': 'abc'},
          },
          '@noemie:matrix.sk7.sh',
          t0,
        ),
        isEmpty,
      );
    });

    test('expires absent → durée par défaut 4 h, pas de crash', () {
      final members = parseMembershipEvent(
        _session(expires: null),
        '@a:b',
        t0,
      );
      expect(members.single.isExpiredAt(t0.add(const Duration(hours: 3))), isFalse);
      expect(members.single.isExpiredAt(t0.add(const Duration(hours: 5))), isTrue);
    });

    test('deux devices du même user dans un event → deux entrées', () {
      final members = parseMembershipEvent(
        {
          'calls': [_session(deviceId: 'D1'), _session(deviceId: 'D2')],
        },
        '@noemie:matrix.sk7.sh',
        t0,
      );
      expect(members.map((m) => m.deviceId), ['D1', 'D2']);
    });

    test('foci sans type livekit filtrée', () {
      final members = parseMembershipEvent(
        _session(
          foci: [
            {'type': 'sfu'},
            {
              'type': 'livekit',
              'livekit_service_url': 'https://matrix-rtc.sk7.sh',
            },
          ],
        ),
        '@a:b',
        t0,
      );
      expect(members.single.fociPreferred, hasLength(1));
      expect(members.single.fociPreferred.single.type, 'livekit');
    });
  });

  group('buildMembershipContent', () {
    final member = RtcSessionMembership(
      userId: '@sk7n4k3d:matrix.sk7.sh',
      deviceId: 'VOXDEV',
      callId: '',
      application: 'm.call',
      expiresMs: 3600000,
      membershipId: 'construit-1',
      originServerTs: t0,
      fociPreferred: const [
        RtcFocus(
          type: 'livekit',
          livekitServiceUrl: 'https://matrix-rtc.sk7.sh',
        ),
      ],
    );

    test('round-trip : ce quon construit se re-parse', () {
      final content = buildMembershipContent(member);
      final parsed = parseMembershipEvent(
        content,
        member.userId,
        member.originServerTs,
      );
      expect(parsed, hasLength(1));
      final back = parsed.single;
      expect(back.deviceId, 'VOXDEV');
      expect(back.callId, '');
      expect(back.expiresMs, 3600000);
      expect(back.fociPreferred.single.livekitServiceUrl,
          'https://matrix-rtc.sk7.sh');
    });

    test('expires est relatif en ms et membershipID régénéré à chaque build',
        () {
      final a = buildMembershipContent(member);
      final b = buildMembershipContent(member);
      final entryA =
          ((a['calls']! as List).single as Map).cast<String, Object?>();
      final entryB =
          ((b['calls']! as List).single as Map).cast<String, Object?>();
      expect(entryA['expires'], 3600000);
      expect(entryA['membershipID'], isA<String>());
      expect(entryB['membershipID'], isNot(entryA['membershipID']));
    });
  });

  test('le type d event visé est bien celui du réseau', () {
    expect(rtcMembershipEventType, 'org.matrix.msc3401.call.member');
  });
}
