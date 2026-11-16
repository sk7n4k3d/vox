import 'package:fluffychat/pages/sms_chat/sms_chat_page.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SmsMessage liveMms({List<SmsAttachment> attachments = const []}) => SmsMessage(
    id: '140',
    address: '+33600000000',
    body: '',
    date: 1793899553000,
    isFromMe: false,
    type: 1,
    status: -1,
    read: true,
    isMms: false,
    attachments: attachments,
  );

  group('mergeLiveMmsAttachments', () {
    test('ajoute les parts média au message live et passe isMms', () {
      final parts = [
        const SmsAttachment(
          partId: 339,
          mimeType: 'image/jpeg',
          fileName: 'image0000001.jpg',
        ),
      ];
      final merged = mergeLiveMmsAttachments(liveMms(), parts);
      expect(merged.isMms, isTrue);
      expect(merged.attachments, parts);
      expect(merged.images.single.partId, 339);
      expect(merged.visualMedia, hasLength(1));
    });

    test('préserve les champs texte/identité du message live', () {
      final original = SmsMessage(
        id: '141',
        address: '+33600000000',
        body: 'photo du chat',
        date: 1793899999000,
        isFromMe: false,
        type: 1,
        status: -1,
        read: true,
      );
      final merged = mergeLiveMmsAttachments(original, const [
        SmsAttachment(
          partId: 340,
          mimeType: 'image/jpeg',
          fileName: 'img.jpg',
        ),
      ]);
      expect(merged.id, '141');
      expect(merged.address, '+33600000000');
      expect(merged.body, 'photo du chat');
      expect(merged.date, 1793899999000);
      expect(merged.isFromMe, isFalse);
      expect(merged.type, 1);
      expect(merged.status, -1);
      expect(merged.read, isTrue);
    });

    test('audio seul : joint comme pièce non-visuelle, jamais perdu', () {
      final merged = mergeLiveMmsAttachments(liveMms(), const [
        SmsAttachment(
          partId: 341,
          mimeType: 'audio/3gpp',
          fileName: 'audio.3gp',
        ),
      ]);
      expect(merged.attachments, hasLength(1));
      expect(merged.images, isEmpty);
      expect(merged.otherFiles.single.isAudio, isTrue);
    });
  });

  group('SmsIncoming.fromMap — événement MMS live', () {
    test('expose mmsId et kind mms (parts relisables via listMmsParts)', () {
      final incoming = SmsIncoming.fromMap(const {
        'kind': 'mms',
        'address': '+33600000000',
        'body': 'salut',
        'date': 1793899555000,
        'threadId': '4',
        'mmsId': 140,
      });
      expect(incoming.isMms, isTrue);
      expect(incoming.hasMmsId, isTrue);
      expect(incoming.mmsId, 140);
      // Pas de messageId pour un MMS : c'est bien mmsId qui porte la ligne.
      expect(incoming.hasMessageId, isFalse);
    });

    test('payload sans mmsId (MMS échoué) : hasMmsId faux, pas de relance', () {
      final incoming = SmsIncoming.fromMap(const {
        'kind': 'mms',
        'address': '+33600000000',
        'body': '',
        'date': 1,
        'threadId': '4',
      });
      expect(incoming.hasMmsId, isFalse);
    });
  });
  group('SmsMessage.uid — désambiguïsation SMS/MMS', () {
    SmsMessage msg(String id, {bool isMms = false}) => SmsMessage(
      id: id,
      address: '+33600000000',
      body: 'x',
      date: 1,
      isFromMe: false,
      type: 1,
      status: -1,
      read: true,
      isMms: isMms,
    );

    test('même _ID provider sur deux tables → uid différents', () {
      // C'est la collision structurelle de mmssms.db : Sms._ID et Mms._ID sont
      // deux compteurs AUTOINCREMENT indépendants.
      expect(msg('42').uid, 'sms:42');
      expect(msg('42', isMms: true).uid, 'mms:42');
      expect(msg('42').uid, isNot(msg('42', isMms: true).uid));
    });

    test('mêmes table+id → uid stable (jointure rechargement ↔ live)', () {
      expect(
        SmsMessage.fromMap({
          'id': 42,
          'address': '+33600000000',
          'body': 'x',
          'date': 1,
          'isFromMe': false,
          'type': 1,
          'status': -1,
          'read': true,
          'isMms': true,
        }).uid,
        msg('42', isMms: true).uid,
      );
    });

    test('ids synthétiques (live sans rowId, optimiste) restent uniques', () {
      final incoming = msg('incoming-1793899553000-0');
      final mmsIncoming = msg('incoming-1793899553000-1', isMms: true);
      final optimistic = msg('optimistic-123', isMms: true);
      expect({incoming.uid, mmsIncoming.uid, optimistic.uid}.length, 3);
    });

    test("merge live conserve l'uid (la jointure trouve la même bulle)", () {
      final live = msg('140', isMms: true);
      final merged = mergeLiveMmsAttachments(live, const [
        SmsAttachment(partId: 1, mimeType: 'image/png', fileName: 'a.png'),
      ]);
      expect(merged.uid, live.uid);
    });
  });

  group('SmsMessage.copyWith — rafraîchissement restreint', () {
    test('ne change que type/status, préserve corps/date/média', () {
      final original = SmsMessage(
        id: '99',
        address: '+33600000000',
        body: 'mon texte',
        date: 1793899553000,
        isFromMe: true,
        type: 2,
        status: -1,
        read: true,
        attachments: const [
          SmsAttachment(
            partId: 77,
            mimeType: 'image/jpeg',
            fileName: 'img.jpg',
          ),
        ],
      );
      final refreshed = original.copyWith(type: 2, status: 0);
      expect(refreshed.status, 0);
      expect(refreshed.body, 'mon texte');
      expect(refreshed.date, 1793899553000);
      expect(refreshed.uid, original.uid);
      expect(refreshed.attachments, original.attachments);
    });
  });
}
