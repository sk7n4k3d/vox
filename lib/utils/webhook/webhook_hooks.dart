import 'dart:async';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:matrix/matrix.dart';

/// Adaptateurs : transforment un message Matrix ou SMS/MMS en [WebhookEvent]
/// puis le poussent. Tous best-effort, appelés en `unawaited` — jamais dans le
/// chemin critique de l'affichage ou de l'envoi.
class WebhookHooks {
  WebhookHooks._();

  static const Set<String> _matrixMediaTypes = {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.File,
    MessageTypes.Sticker,
  };

  /// Événement de timeline Matrix. Ne pousse que les messages
  /// (`m.room.message`), entrants **et** sortants, et seulement pour les rooms
  /// explicitement cochées dans les réglages.
  static Future<void> onMatrixEvent(Event event) async {
    if (!WebhookService.instance.isConfigured) return;
    if (event.redacted) return;
    if (event.type != EventTypes.Message) return;

    final room = event.room;
    final allowed = await WebhookService.instance.allowedRooms();
    if (!isRoomAllowed(
      allowed,
      room.id,
      all: WebhookService.instance.matrixAll,
      newDefault: WebhookService.instance.matrixNewDefault,
      excluded: await WebhookService.instance.excludedRooms(),
    )) {
      return;
    }

    final body = event.content.tryGet<String>('body');
    final member = room.getState(EventTypes.RoomMember, event.senderId);
    await WebhookService.instance.dispatch(
      WebhookEvent(
        source: WebhookSource.matrix,
        eventId: event.eventId,
        outgoing: event.senderId == room.client.userID,
        timestamp: event.originServerTs,
        sender: event.senderId,
        senderName: member?.content.tryGet<String>('displayname'),
        body: body,
        roomId: room.id,
        roomName: room.getLocalizedDisplayname(),
        media: _matrixMedia(event, body),
      ),
    );
  }

  /// SMS/MMS entrant, depuis le flux natif `SmsBridge.instance.incoming`.
  /// Filtré sur les fils cochés dans les réglages.
  static Future<void> onSmsIncoming(SmsIncoming sms) async {
    if (!WebhookService.instance.isConfigured) return;
    final allowed = await WebhookService.instance.allowedSmsThreads();
    if (!isSmsThreadAllowed(
      allowed,
      sms.threadId,
      all: WebhookService.instance.smsAll,
      newDefault: WebhookService.instance.smsNewDefault,
      excluded: await WebhookService.instance.excludedSmsThreads(),
    )) {
      return;
    }
    await WebhookService.instance.dispatch(
      WebhookEvent(
        source: sms.kind == 'mms' ? WebhookSource.mms : WebhookSource.sms,
        eventId: sms.messageId > 0
            ? '${sms.messageId}'
            : '${sms.threadId}-${sms.date}',
        outgoing: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(sms.date),
        sender: sms.address,
        senderName: await _contactName(sms.address),
        body: sms.body,
        threadId: sms.threadId,
      ),
    );
  }

  /// SMS/MMS sortant, depuis le callback posé sur [SmsBridge.onMessageSent]
  /// (point de passage unique de tous les envois : composeur, programmé,
  /// partage). Filtré sur les fils cochés — on retrouve le fil par le numéro.
  static Future<void> onSmsOutgoing(
    String address,
    String? body,
    bool isMms,
  ) async {
    if (!WebhookService.instance.isConfigured) return;
    final allowed = await WebhookService.instance.allowedSmsThreads();
    final excluded = await WebhookService.instance.excludedSmsThreads();
    final all = WebhookService.instance.smsAll;
    final newDefault = WebhookService.instance.smsNewDefault;
    if (!all && !newDefault && allowed.isEmpty) return;
    if (!await _outgoingTargetAllowed(
      allowed,
      excluded,
      address,
      all: all,
      newDefault: newDefault,
    )) {
      return;
    }
    await WebhookService.instance.dispatch(
      WebhookEvent(
        source: isMms ? WebhookSource.mms : WebhookSource.sms,
        eventId: 'sent-${DateTime.now().millisecondsSinceEpoch}',
        outgoing: true,
        timestamp: DateTime.now(),
        sender: address,
        senderName: await _contactName(address),
        body: body,
      ),
    );
  }

  /// Métadonnées d'une pièce jointe Matrix (jamais les octets en v1).
  static List<WebhookMedia> _matrixMedia(Event event, String? body) {
    if (!_matrixMediaTypes.contains(event.messageType)) {
      return const <WebhookMedia>[];
    }
    final info = event.content.tryGetMap<String, Object?>('info');
    return <WebhookMedia>[
      WebhookMedia(
        mimeType: (info?.tryGet<String>('mimetype')) ?? '',
        fileName: body,
        size: (info?.tryGet<int>('size')) ?? 0,
      ),
    ];
  }

  /// L'envoi vise-t-il une conversation qui part ? On retrouve le fil par le
  /// numéro : la conversation native porte le couple (threadId, adresse).
  static Future<bool> _outgoingTargetAllowed(
    Set<String> allowed,
    Set<String> excluded,
    String address, {
    required bool all,
    required bool newDefault,
  }) async {
    if (all) return true;
    try {
      final conversations = await SmsBridge.instance.listConversations();
      return isSmsAddressAllowed(
        conversations.map((c) => (threadId: c.threadId, address: c.address)),
        allowed,
        address,
        newDefault: newDefault,
        excluded: excluded,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _contactName(String address) async {
    if (address.isEmpty) return null;
    try {
      final name = await SmsBridge.instance.resolveContactName(address);
      return (name != null && name.trim().isNotEmpty) ? name.trim() : null;
    } catch (_) {
      return null;
    }
  }
}
