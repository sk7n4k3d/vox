import 'dart:convert';

import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
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

  group('isSmsThreadAllowed', () {
    test('aucun fil coche = rien ne passe', () {
      expect(isSmsThreadAllowed(const <String>{}, '12'), isFalse);
    });

    test('seuls les fils coches passent', () {
      const allowed = {'12', '4'};
      expect(isSmsThreadAllowed(allowed, '12'), isTrue);
      expect(isSmsThreadAllowed(allowed, '7'), isFalse);
    });
  });

  group('normalizeSmsAddress / smsThreadIdForAddress', () {
    test('espaces, tirets et points ne changent pas le numero', () {
      expect(normalizeSmsAddress('+33 6 50 73 02 02'), '+33650730202');
      expect(normalizeSmsAddress('06.50.73.02.02'), '0650730202');
      expect(normalizeSmsAddress('+33-(6)-50-73-02-02'), '+33650730202');
    });

    test('un envoi retrouve son fil malgre la mise en forme du numero', () {
      const threads = [
        (threadId: '12', address: '+33650730202'),
        (threadId: '4', address: '+33612345678'),
      ];
      expect(smsThreadIdForAddress(threads, '+33650730202'), '12');
      expect(smsThreadIdForAddress(threads, '+33 6 50 73 02 02'), '12');
      expect(smsThreadIdForAddress(threads, '+33612345678'), '4');
      expect(smsThreadIdForAddress(threads, '+33699999999'), isNull);
    });

    test('all=true envoie meme les conversations jamais vues', () {
      expect(isRoomAllowed(const <String>{}, '!nouvelle:x', all: true), isTrue);
      expect(isSmsThreadAllowed(const <String>{}, '99', all: true), isTrue);
      // Sans le drapeau, une conversation hors liste reste exclue.
      expect(isRoomAllowed(const {'!a:x'}, '!nouvelle:x'), isFalse);
      expect(isSmsThreadAllowed(const {'12'}, '99'), isFalse);
    });
  });

  group('nouveaux par defaut et exclus', () {
    test('le defaut envoie une conversation jamais decidee', () {
      expect(isRoomAllowed(const <String>{}, '!n:x'), isFalse);
      expect(isRoomAllowed(const <String>{}, '!n:x', newDefault: true), isTrue);
      expect(isSmsThreadAllowed(const <String>{}, '77'), isFalse);
      expect(
        isSmsThreadAllowed(const <String>{}, '77', newDefault: true),
        isTrue,
      );
    });

    test('une conversation decochee est exclue, meme avec le defaut', () {
      expect(
        isRoomAllowed(
          const <String>{},
          '!n:x',
          newDefault: true,
          excluded: const {'!n:x'},
        ),
        isFalse,
      );
      expect(
        isSmsThreadAllowed(
          const <String>{},
          '77',
          newDefault: true,
          excluded: const {'77'},
        ),
        isFalse,
      );
    });

    test('cocher reprend la main sur une exclusion', () {
      expect(
        isRoomAllowed(const {'!n:x'}, '!n:x', excluded: const {'!n:x'}),
        isTrue,
      );
    });

    test('tout envoyer court-circuite meme une exclusion', () {
      expect(
        isRoomAllowed(
          const <String>{},
          '!n:x',
          all: true,
          excluded: const {'!n:x'},
        ),
        isTrue,
      );
    });

    test('sortant : le fil retrouve par le numero suit la meme regle', () {
      const threads = [(threadId: '12', address: '+33650730202')];
      expect(smsThreadIdForAddress(threads, '+33650730202'), '12');
      expect(smsThreadIdForAddress(threads, '+33 6 50 73 02 02'), '12');
      expect(smsThreadIdForAddress(threads, '+33699999999'), isNull);
      expect(smsThreadIdForAddress(const [], '+33650730202'), isNull);
    });
  });

  group('WebhookMedia — contrat média', () {
    test('les octets partent en base64 avec le type et le nom', () {
      final json = WebhookMedia(
        mimeType: 'image/jpeg',
        fileName: 'photo.jpg',
        size: 3,
        dataB64: 'AQID',
      ).toJson();

      expect(json['mime'], 'image/jpeg');
      expect(json['filename'], 'photo.jpg');
      expect(json['size'], 3);
      expect(json['data_b64'], 'AQID');
      expect(json.containsKey('reason'), isFalse);
    });

    test('un média non joint porte une raison, pas d octets', () {
      const media = WebhookMedia(
        mimeType: 'video/mp4',
        fileName: 'gros.mp4',
        size: maxWebhookMediaBytes + 1,
        reason: 'trop volumineux (> 16 Mo)',
      );
      final json = media.toJson();

      expect(media.skipped, isTrue);
      expect(json.containsKey('data_b64'), isFalse);
      expect(json['reason'], 'trop volumineux (> 16 Mo)');
    });

    test('le plafond est bien de 16 Mo', () {
      expect(maxWebhookMediaBytes, 16 * 1024 * 1024);
    });
  });

  group('retryDelayMs — backoff de la file', () {
    test('double a chaque tentative, en partant du delai de base', () {
      expect(retryDelayMs(60, 1), 60 * 1000);
      expect(retryDelayMs(60, 2), 120 * 1000);
      expect(retryDelayMs(60, 3), 240 * 1000);
      expect(retryDelayMs(60, 4), 480 * 1000);
    });

    test('plafonne a une heure', () {
      expect(retryDelayMs(60, 20), 3600 * 1000);
      expect(retryDelayMs(3600, 5), 3600 * 1000);
    });

    test('un delai de base nul ou une tentative 0 ne part pas en negatif', () {
      expect(retryDelayMs(0, 1), 0);
      expect(retryDelayMs(60, 0), 60 * 1000);
    });
  });

  group('PendingWebhook — persistance', () {
    test('un aller-retour JSON conserve le corps brut et les compteurs', () {
      final item = PendingWebhook(
        rawBody: '{"event_id":"42"}',
        createdAtMs: 1700000000000,
        attempts: 2,
        nextAttemptAtMs: 1700000120000,
      );
      final back = PendingWebhook.fromJson(
        jsonDecode(jsonEncode(item.toJson())),
      );

      expect(back, isNotNull);
      expect(back!.rawBody, '{"event_id":"42"}');
      expect(back.createdAtMs, 1700000000000);
      expect(back.attempts, 2);
      expect(back.nextAttemptAtMs, 1700000120000);
    });

    test('une entree sans corps est ignoree', () {
      expect(PendingWebhook.fromJson(const {'attempts': 1}), isNull);
      expect(PendingWebhook.fromJson('pas un objet'), isNull);
    });
  });
}
