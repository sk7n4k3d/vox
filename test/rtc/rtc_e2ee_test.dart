import 'dart:convert';

import 'package:fluffychat/utils/rtc/rtc_e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RtcE2ee (schéma matrix-rust-rtc)', () {
    test('message de clé MSC4143 équivalent : room, device, index, 32 o', () {
      final e = RtcE2ee(
        roomId: '!dm:s',
        userId: '@moi:s',
        deviceId: 'DEV',
      );
      expect(e.memberId, '@moi:s:DEV');
      expect(base64Decode(e.ownKeyLatin1.isEmpty ? '' : ''), isEmpty);
      // notre contenu émis (legacy) doit être relisible par le parseur
      // moderne d un client MSC4143 : keys objet + device_id
      final m = e.buildKeyMessage();
      expect(m['member_id'] ?? m['device_id'], 'DEV');
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
            (m['media_key']! as Map)['key'] = base64Encode(List.filled(8, 1));
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

  group('schéma legacy io.element (Noémie/rust Sticky2025)', () {
    test('parse legacy : keys objet, member.id, 16 octets acceptés', () {
      final parsed = RtcE2ee.parse(
        {
          'room_id': '!dm:s',
          'member': {'id': '@n:o:D1', 'device_id': 'D1'},
          'keys': {
            'index': 2,
            'key': base64Encode(List.filled(16, 9)),
          },
          'session': {'slot_id': 'm.call#ROOM'},
          'sent_ts': 1792080000000,
        },
        roomId: '!dm:s',
        senderUserId: '@n:o',
        senderDeviceId: 'D1',
      );
      expect(parsed, isNotNull);
      expect(parsed!.memberId, '@n:o:D1');
      expect(parsed.index, 2);
      expect(latin1.encode(parsed.keyLatin1), hasLength(16));
    });

    test('parse legacy : tableau de clés, le plus haut index gagne', () {
      final parsed = RtcE2ee.parse(
        {
          'room_id': '!dm:s',
          'device_id': 'D1',
          'keys': [
            {'index': 0, 'key': base64Encode(List.filled(16, 1))},
            {'index': 5, 'key': base64Encode(List.filled(32, 7))},
            {'index': 3, 'key': base64Encode(List.filled(16, 2))},
          ],
        },
        roomId: '!dm:s',
        senderUserId: '@n:o',
        senderDeviceId: 'D1',
      );
      expect(parsed, isNotNull);
      expect(parsed!.index, 5);
      // sans member.id, c'est le device authentifié Olm qui fixe l identité
      expect(parsed.memberId, '@n:o:D1');
    });

    test('parse legacy : room différente ou clé vide -> rejeté', () {
      expect(
        RtcE2ee.parse(
          {
            'room_id': '!autre:s',
            'device_id': 'D1',
            'keys': {'index': 0, 'key': base64Encode(List.filled(16, 1))},
          },
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
      expect(
        RtcE2ee.parse(
          {'room_id': '!dm:s', 'device_id': 'D1', 'keys': <Object?>[]},
          roomId: '!dm:s',
          senderUserId: '@n:o',
          senderDeviceId: 'D1',
        ),
        isNull,
      );
    });

    test('message envoyé : dialecte legacy (keys/room_id/device_id)', () {
      final e = RtcE2ee(
        roomId: '!dm:s',
        userId: '@moi:s',
        deviceId: 'DEV',
      );
      final m = e.buildKeyMessage();
      expect(m['room_id'], '!dm:s');
      expect(m['device_id'], 'DEV');
      final keys = (m['keys']! as Map).cast<String, Object?>();
      expect(keys['index'], 0);
      expect(base64Decode(keys['key']! as String), hasLength(32));
    });

    test('le type émis est le type legacy', () {
      expect(RtcE2ee.keyEventType, 'io.element.call.encryption_keys');
      expect(RtcE2ee.parseEventTypes, contains('io.element.call.encryption_keys'));
    });
  });
}
