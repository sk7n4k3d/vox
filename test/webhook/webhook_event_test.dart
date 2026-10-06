import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ts = DateTime.utc(2026, 10, 6, 21, 37, 12, 345);

  group('WebhookEvent.toJson — SMS entrant', () {
    test('expose source, id, sens, horodatage, expediteur et corps', () {
      final json = WebhookEvent(
        source: WebhookSource.sms,
        eventId: '42',
        outgoing: false,
        timestamp: ts,
        sender: '+33650730202',
        senderName: 'Noémie',
        body: 'Tu reçois ?',
        threadId: '12',
      ).toJson();

      expect(json['source'], 'sms');
      expect(json['event_id'], '42');
      expect(json['direction'], 'in');
      expect(json['sender'], '+33650730202');
      expect(json['sender_name'], 'Noémie');
      expect(json['body'], 'Tu reçois ?');
      expect(json['body_hidden'], isFalse);
      expect(json['thread_id'], '12');
      expect(json['timestamp'], '2026-10-06T21:37:12.345Z');
      expect(json['timestamp_ms'], ts.millisecondsSinceEpoch);
      expect(json.containsKey('room_id'), isFalse);
    });

    test('un envoi est marque direction=out', () {
      final json = WebhookEvent(
        source: WebhookSource.sms,
        eventId: '43',
        outgoing: true,
        timestamp: ts,
        sender: '+33650730202',
        body: 'Coucou',
      ).toJson();
      expect(json['direction'], 'out');
    });
  });

  group('WebhookEvent.toJson — cache conversation', () {
    test('masque le corps mais garde les metadonnees', () {
      final json = WebhookEvent(
        source: WebhookSource.mms,
        eventId: '7',
        outgoing: false,
        timestamp: ts,
        sender: '+33612345678',
        body: 'texte secret',
        threadId: '3',
        media: const [
          WebhookMedia(mimeType: 'image/jpeg', fileName: 'image.jpg', size: 510093),
        ],
        hideBody: true,
      ).toJson();

      expect(json['body'], isNull);
      expect(json['body_hidden'], isTrue);
      expect(json['source'], 'mms');
      expect(json['sender'], '+33612345678');
      expect(json['thread_id'], '3');
    });
  });

  group('WebhookEvent.toJson — Matrix', () {
    test('porte room_id et room_name au lieu d un thread', () {
      final json = WebhookEvent(
        source: WebhookSource.matrix,
        eventId: r'$abc',
        outgoing: true,
        timestamp: ts,
        sender: '@sk7n4k3d:matrix.sk7.sh',
        body: 'hello',
        roomId: '!room:matrix.sk7.sh',
        roomName: 'Groupe avec hermes',
      ).toJson();

      expect(json['source'], 'matrix');
      expect(json['direction'], 'out');
      expect(json['room_id'], '!room:matrix.sk7.sh');
      expect(json['room_name'], 'Groupe avec hermes');
      expect(json.containsKey('thread_id'), isFalse);
    });
  });

  group('WebhookMedia', () {
    test('ne transporte aucune donnee binaire', () {
      final json = const WebhookMedia(
        mimeType: 'image/jpeg',
        fileName: 'image.jpg',
        size: 510093,
      ).toJson();
      expect(json.keys, unorderedEquals(['mime', 'filename', 'size']));
    });
  });

  group('isRoomAllowed', () {
    test('aucune room cochee = rien ne passe', () {
      expect(isRoomAllowed(const <String>{}, '!a:x'), isFalse);
    });

    test('seules les rooms listees passent', () {
      const allowed = {'!a:x', '!b:x'};
      expect(isRoomAllowed(allowed, '!a:x'), isTrue);
      expect(isRoomAllowed(allowed, '!c:x'), isFalse);
    });
  });
}
