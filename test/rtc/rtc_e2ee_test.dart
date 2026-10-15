import 'dart:convert';

import 'package:fluffychat/utils/rtc/rtc_e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RtcE2ee (schéma matrix-rust-rtc)', () {
    test('message de clé : room_id, member_id user:device, format 0', () {
      final e = RtcE2ee(
        roomId: '!dm:s',
        userId: '@moi:s',
        deviceId: 'DEV',
      );
      final m = e.buildKeyMessage();
      expect(m['room_id'], '!dm:s');
      expect(m['member_id'], '@moi:s:DEV');
      expect(m['format'], 0);
      final mk = (m['media_key']! as Map).cast<String, Object?>();
      expect(mk['index'], 0);
      expect(base64Decode(mk['key']! as String), hasLength(32));
    });

    test('parse : clé valide acceptée, encodée latin1 pour LiveKit', () {
      final key = base64Encode(List<int>.filled(32, 7));
      final parsed = RtcE2ee.parse(
        {
          'room_id': '!dm:s',
          'member_id': '@n:o:D1',
          'media_key': {'index': 3, 'key': key},
          'format': 0,
        },
        roomId: '!dm:s',
        senderUserId: '@n:o',
        senderDeviceId: 'D1',
      );
      expect(parsed, isNotNull);
      expect(parsed!.memberId, '@n:o:D1');
      expect(parsed.index, 3);
      expect(latin1.encode(parsed.keyLatin1), List<int>.filled(32, 7));
    });

    test('parse : tout contenu douteux est jeté', () {
      const valid = {
        'room_id': '!dm:s',
        'member_id': '@n:o:D1',
        'media_key': {'index': 0, 'key': 'Rwc='},
        'format': 0,
      };
      Map<String, Object?> mutate(void Function(Map<String, Object?>) f) {
        final m = Map<String, Object?>.from(valid);
        m['media_key'] = Map<String, Object?>.from(m['media_key']! as Map);
        f(m);
        return m;
      }
      // device non authentifié (pas de session Olm) -> MSC4143 jette
      expect(
        RtcE2ee.parse(
          valid,
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: null,
        ),
        isNull,
      );
      // autre room, format inconnu, mauvaise longueur, base64 invalide
      expect(
        RtcE2ee.parse(
          mutate((m) => m['room_id'] = '!other:s'),
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
      expect(
        RtcE2ee.parse(
          mutate((m) => m['format'] = 1),
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
      expect(
        RtcE2ee.parse(
          mutate((m) {
            (m['media_key']! as Map)['key'] = base64Encode(List.filled(16, 1));
          }),
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
      expect(
        RtcE2ee.parse(
          mutate((m) {
            (m['media_key']! as Map)['key'] = 'pas-du-base64!!!';
          }),
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
    });

    test('shareWith : un envoi par device, idempotent', () async {
      final sent = <List<String>>[];
      final e = RtcE2ee(
        roomId: '!dm:s',
        userId: '@moi:s',
        deviceId: 'DEV',
        sendKey: (u, d, c) async => sent.add([u, d]),
      );
      await e.shareWith('@n:o', 'D1');
      await e.shareWith('@n:o', 'D1');
      await e.shareWith('@n:o', '');
      expect(sent, [
        ['@n:o', 'D1'],
      ]);
    });
  });
}
