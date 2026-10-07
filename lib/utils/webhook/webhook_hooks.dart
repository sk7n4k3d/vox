import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/foundation.dart';
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
        media: await _matrixMedia(event, body),
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
        media: sms.hasMmsId ? await _mmsMedia(sms.mmsId) : const <WebhookMedia>[],
      ),
    );
  }

  /// SMS/MMS sortant, depuis le callback posé sur [SmsBridge.onMessageSent]
  /// (point de passage unique de tous les envois : composeur, programmé,
  /// partage).
  ///
  /// Le callback ne porte que le numéro : on **résout le fil** (threadId) via le
  /// pont natif, comme pour le filtrage. Sans ça l'événement partait avec un fil
  /// vide, donc dans un fil différent de celui des entrants : la détection
  /// « à qui je n'ai pas répondu » (qui compare entrants et sortants d'un même
  /// fil) ne voyait jamais les réponses SMS.
  static Future<void> onSmsOutgoing(
    String address,
    String? body,
    bool isMms,
    String? attachmentPath,
  ) async {
    if (!WebhookService.instance.isConfigured) return;
    final allowed = await WebhookService.instance.allowedSmsThreads();
    final all = WebhookService.instance.smsAll;
    final newDefault = WebhookService.instance.smsNewDefault;
    // Rien ne peut partir : inutile d'aller résoudre le fil.
    if (!all && !newDefault && allowed.isEmpty) return;
    final excluded = await WebhookService.instance.excludedSmsThreads();
    final threadId = await _threadIdForAddress(address);
    if (!isSmsThreadAllowed(
      allowed,
      threadId ?? '',
      all: all,
      newDefault: newDefault,
      excluded: excluded,
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
        threadId: threadId,
        media: attachmentPath == null || attachmentPath.isEmpty
            ? const <WebhookMedia>[]
            : [
                await fileMedia(
                  attachmentPath,
                  attachmentPath.split('/').last,
                  mimeType: _mimeForPath(attachmentPath),
                ),
              ],
      ),
    );
  }

  /// Médias d'un message Matrix : les octets déchiffrés partent en base64, sous
  /// le plafond. Un téléchargement raté ou un fichier trop gros devient une
  /// simple métadonnée (`reason`), jamais un échec de l'événement.
  static Future<List<WebhookMedia>> _matrixMedia(
    Event event,
    String? body,
  ) async {
    if (!_matrixMediaTypes.contains(event.messageType)) {
      return const <WebhookMedia>[];
    }
    final info = event.content.tryGetMap<String, Object?>('info');
    final mime = (info?.tryGet<String>('mimetype')) ?? '';
    final declared = (info?.tryGet<int>('size')) ?? 0;
    if (declared > maxWebhookMediaBytes) {
      return <WebhookMedia>[
        WebhookMedia(
          mimeType: mime,
          fileName: body,
          size: declared,
          reason: 'trop volumineux (> 16 Mo)',
        ),
      ];
    }
    try {
      final file = await event.downloadAndDecryptAttachment();
      final bytes = file.bytes;
      if (bytes.isEmpty) {
        return <WebhookMedia>[
          WebhookMedia(
            mimeType: mime.isEmpty ? file.mimeType : mime,
            fileName: body,
            size: declared,
            reason: 'octets vides',
          ),
        ];
      }
      if (bytes.length > maxWebhookMediaBytes) {
        return <WebhookMedia>[
          WebhookMedia(
            mimeType: mime.isEmpty ? file.mimeType : mime,
            fileName: body,
            size: bytes.length,
            reason: 'trop volumineux (> 16 Mo)',
          ),
        ];
      }
      return <WebhookMedia>[
        WebhookMedia(
          mimeType: mime.isEmpty ? file.mimeType : mime,
          fileName: body,
          size: bytes.length,
          dataB64: base64Encode(bytes),
        ),
      ];
    } catch (e) {
      debugPrint('WebhookHooks: média Matrix illisible: $e');
      return <WebhookMedia>[
        WebhookMedia(
          mimeType: mime,
          fileName: body,
          size: declared,
          reason: 'téléchargement échoué',
        ),
      ];
    }
  }

  /// Médias d'un MMS entrant : chaque part est extraite puis lue, sous le
  /// plafond. Une part illisible devient une métadonnée.
  static Future<List<WebhookMedia>> _mmsMedia(int mmsId) async {
    final out = <WebhookMedia>[];
    try {
      final parts = await SmsBridge.instance.listMmsParts(mmsId);
      for (final part in parts) {
        final path = await SmsBridge.instance.loadMmsPart(part.partId);
        if (path == null || path.isEmpty) {
          out.add(
            WebhookMedia(
              mimeType: part.mimeType,
              fileName: part.fileName,
              size: 0,
              reason: 'part illisible',
            ),
          );
          continue;
        }
        out.add(
          await fileMedia(path, part.fileName, mimeType: part.mimeType),
        );
      }
    } catch (e) {
      debugPrint('WebhookHooks: média MMS illisible: $e');
    }
    return out;
  }

  /// Lit un fichier local et l'encode. Au-delà du plafond, ou si la lecture
  /// échoue, on ne garde que la métadonnée. Public : sert aussi aux
  /// enregistrements d'appels (WebhookCalls).
  static Future<WebhookMedia> fileMedia(
    String path,
    String? fileName, {
    String mimeType = '',
  }) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return WebhookMedia(
          mimeType: mimeType,
          fileName: fileName,
          size: 0,
          reason: 'fichier introuvable',
        );
      }
      final length = await file.length();
      if (length > maxWebhookMediaBytes) {
        return WebhookMedia(
          mimeType: mimeType,
          fileName: fileName,
          size: length,
          reason: 'trop volumineux (> 16 Mo)',
        );
      }
      final bytes = await file.readAsBytes();
      return WebhookMedia(
        mimeType: mimeType,
        fileName: fileName,
        size: bytes.length,
        dataB64: base64Encode(bytes),
      );
    } catch (e) {
      debugPrint('WebhookHooks: fichier média illisible: $e');
      return WebhookMedia(
        mimeType: mimeType,
        fileName: fileName,
        size: 0,
        reason: 'lecture impossible',
      );
    }
  }

  /// Type MIME déduit de l'extension (un MMS sortant ne nous donne que le
  /// chemin du fichier).
  static String _mimeForPath(String path) {
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'mp4' => 'video/mp4',
      '3gp' => 'video/3gpp',
      _ => 'application/octet-stream',
    };
  }

  /// Fil (threadId) correspondant à un numéro, via le pont natif. Null si le
  /// numéro ne correspond à aucune conversation connue.
  static Future<String?> _threadIdForAddress(String address) async {
    try {
      final conversations = await SmsBridge.instance.listConversations();
      return smsThreadIdForAddress(
        conversations.map((c) => (threadId: c.threadId, address: c.address)),
        address,
      );
    } catch (e) {
      debugPrint('WebhookHooks: fil introuvable pour un envoi: $e');
    }
    return null;
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
