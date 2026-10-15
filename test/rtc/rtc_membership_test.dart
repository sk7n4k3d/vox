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

    test('expires relatif, membershipID = user:device, refresh par created_ts',
        () {
      final a = buildMembershipContent(member);
      final later = RtcSessionMembership(
        userId: member.userId,
        deviceId: member.deviceId,
        callId: '',
        application: 'm.call',
        expiresMs: 3600000,
        membershipId: '',
        originServerTs: member.originServerTs.add(const Duration(minutes: 30)),
        fociPreferred: member.fociPreferred,
      );
      final b = buildMembershipContent(later);
      expect(a['expires'], 3600000);
      expect(a['membershipID'], '@sk7n4k3d:matrix.sk7.sh:VOXDEV');
      expect(b['created_ts'], isNot(a['created_ts']));
    });
  });

  test('le type d event visé est bien celui du réseau', () {
    expect(rtcMembershipEventType, 'org.matrix.msc3401.call.member');
  });

  group('forme plate miroir Element X (calibrage M1)', () {
    // fixture = event RÉEL publié par Noémie/Element X le 15/10 15:43:52
    final realRemote = <String, Object?>{
      'application': 'm.call',
      'call_id': '',
      'created_ts': 1792071832886,
      'device_id': 'VAY14m8QBP',
      'expires': 14400000,
      'foci_preferred': [
        {
          'livekit_alias': '!y2jT1plx',
          'livekit_service_url': 'https://livekit-jwt.call.matrix.org',
          'type': 'livekit',
        },
      ],
      'focus_active': {'focus_selection': 'multi_sfu', 'type': 'livekit'},
      'm.call.intent': 'audio',
      'membershipID': '@nanagum:VAY14m8QBP',
    };

    test('parse : intent, alias et created_ts sont lus', () {
      final members = parseMembershipEvent(
        realRemote,
        '@nanagum:matrix.org',
        DateTime.fromMillisecondsSinceEpoch(1792071832886),
      );
      expect(members, hasLength(1));
      final m = members.single;
      expect(m.intent, 'audio');
      expect(m.fociPreferred.single.livekitAlias, '!y2jT1plx');
      expect(m.createdTs, 1792071832886);
    });

    test('build : produit la forme plate avec alias, intent et focus_active',
        () {
      final content = buildMembershipContent(
        RtcSessionMembership(
          userId: '@moi:s',
          deviceId: 'VOXDEV',
          callId: '',
          application: 'm.call',
          expiresMs: 3600000,
          membershipId: 'x',
          originServerTs: t0,
          fociPreferred: const [
            RtcFocus(
              type: 'livekit',
              livekitServiceUrl: 'https://matrix-rtc.sk7.sh',
              livekitAlias: '!dm:s',
            ),
          ],
          intent: 'video',
        ),
      );
      // plus de tableau `calls` : Element X lit la forme plate
      expect(content['calls'], isNull);
      expect(content['application'], 'm.call');
      expect(content['device_id'], 'VOXDEV');
      expect(content['m.call.intent'], 'video');
      expect(content['focus_active'], {
        'focus_selection': 'multi_sfu',
        'type': 'livekit',
      });
      final foci = (content['foci_preferred']! as List)
          .cast<Map<String, Object?>>();
      expect(foci.single['livekit_alias'], '!dm:s');
      expect(content['membershipID'], '@moi:s:VOXDEV');
      // round-trip dans notre propre parseur
      expect(
        parseMembershipEvent(content, '@moi:s', t0).single.intent,
        'video',
      );
    });
  });

  group('legacyMembershipStateKey (calibrage serveur 15/10, RocksDB Tuwunel)',
      () {
    test('suit la forme publiée par Element X : _user_device_m.call', () {
      expect(
        legacyMembershipStateKey(
          '@nanagum:matrix.org',
          'VAY14m8QBP',
        ),
        '_@nanagum:matrix.org_VAY14m8QBP_m.call',
      );
    });
  });
}
