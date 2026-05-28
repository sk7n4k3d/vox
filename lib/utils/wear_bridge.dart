import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

/// Bridge Wear OS — pousse un snapshot des rooms vers la Galaxy Watch Ultra
/// via le module Android natif `wear/` (DataClient `/wear/rooms`).
///
/// Singleton, thread-safe. Sur plateformes non-Android : no-op silencieux.
///
/// Workflow :
///   1. Au login d'un client Matrix, [attach] s'abonne à `client.onSync`.
///   2. À chaque sync delta (debounced 2 s), [_pushSnapshot] sérialise top-10
///      rooms + favoris + envoie au natif via MethodChannel `pushRooms`.
///   3. La watch peut ping back via MessageClient `/wear/rooms/request` →
///      le natif déclenche `onRefreshRequested` → on force un push.
///
/// La déclaration capability `fluffychat_phone` est faite côté natif
/// (`res/values/wear.xml`).
class WearBridge {
  WearBridge._();

  static final WearBridge instance = WearBridge._();

  static const _channel = MethodChannel('chat.fluffy.fluffychat/wear_bridge');
  static const _topRecentsCount = 10;
  static const _debounce = Duration(seconds: 2);

  final Map<String, StreamSubscription<SyncUpdate>> _syncSubs = {};
  final Map<String, Client> _clients = {};
  Timer? _debounceTimer;
  bool _wired = false;

  /// Doit être appelé une fois au démarrage de l'app (avant tout [attach]).
  void wireIfNeeded() {
    if (_wired) return;
    if (!_isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRefreshRequested':
          Logs().d('[WearBridge] watch requested refresh — forcing push');
          _scheduleSnapshot(immediate: true);
          break;
        case 'onVoiceReceived':
          await _handleVoiceReceived(call.arguments);
          break;
        case 'onMessagesRequested':
          await _handleMessagesRequested(call.arguments);
          break;
      }
      return null;
    });
    _wired = true;
  }

  Future<void> _handleVoiceReceived(dynamic args) async {
    if (args is! Map) {
      Logs().w('[WearBridge] onVoiceReceived bad args type');
      return;
    }
    final uuid = args['uuid'] as String? ?? '';
    final roomId = args['roomId'] as String? ?? '';
    final durationMs = (args['durationMs'] as int?) ?? 0;
    final mimeType = (args['mimeType'] as String?) ?? 'audio/ogg';
    final bytesRaw = args['bytes'];
    if (uuid.isEmpty || roomId.isEmpty || bytesRaw is! List<int>) {
      Logs().w('[WearBridge] onVoiceReceived missing fields');
      return;
    }
    final client = _clients.values.firstOrNull;
    final room = client?.getRoomById(roomId);
    if (client == null || room == null) {
      Logs().w('[WearBridge] no client/room for voice uuid=$uuid roomId=$roomId');
      await _ackVoice(uuid, false);
      return;
    }
    try {
      final bytes = Uint8List.fromList(bytesRaw);
      final audioFile = MatrixAudioFile(
        bytes: bytes,
        name: 'voice_$uuid.ogg',
        mimeType: mimeType,
        duration: durationMs,
      );
      Logs().d('[WearBridge] sending voice ${bytes.length} bytes to $roomId');
      await room.sendFileEvent(
        audioFile,
        extraContent: {
          'org.matrix.msc1767.audio': {
            'duration': durationMs,
            // waveform vide — V2 minimal, on n'extrait pas la waveform de l'Opus
            'waveform': const <int>[],
          },
          'org.matrix.msc3245.voice': const <String, dynamic>{},
        },
      );
      Logs().d('[WearBridge] voice sent OK uuid=$uuid');
      await _ackVoice(uuid, true);
    } catch (e, st) {
      Logs().w('[WearBridge] voice send failed uuid=$uuid', e, st);
      await _ackVoice(uuid, false);
    }
  }

  Future<void> _ackVoice(String uuid, bool success) async {
    try {
      await _channel.invokeMethod('ackVoice', {
        'uuid': uuid,
        'success': success,
      });
    } catch (e) {
      Logs().w('[WearBridge] ackVoice channel error', e);
    }
  }

  Future<void> _handleMessagesRequested(dynamic args) async {
    if (args is! Map) return;
    final roomId = args['roomId'] as String? ?? '';
    if (roomId.isEmpty) return;
    final client = _clients.values.firstOrNull;
    if (client == null) return;
    final room = client.getRoomById(roomId);
    if (room == null) {
      Logs().w('[WearBridge] requested messages for unknown room $roomId');
      return;
    }
    try {
      final timeline = await room.getTimeline(limit: 30);
      final rawEvents = timeline.events.where(_isRenderableEvent).take(30).toList();

      // Sérialise + télécharge les thumbnails image en parallèle.
      final messages = await Future.wait(
        rawEvents.map((e) => _serializeMessageWithMedia(e, client.userID)),
      );

      // Sprint 2 audit finding-023 (CRITICAL): DataItem GMS limit = 100KB
      // strict. Sans plafond, 30 thumbs base64 ~20KB chacun = 600KB →
      // putDataItem rejette silencieusement, watch n'a rien. Ici on garde
      // un budget sûr de 90KB et on droppe les thumbBase64 dès qu'on
      // déborde, par ordre des messages les plus anciens d'abord.
      const maxPayloadBytes = 90 * 1024;
      var currentSize = jsonEncode({
        'version': 1,
        'roomId': roomId,
        'updatedAt': 0,
        'messages': messages,
      }).length;
      var droppedThumbs = 0;
      // Iterate from the oldest message (low index) — most recent thumbs
      // stay visible on the watch face.
      for (final m in messages) {
        if (currentSize <= maxPayloadBytes) break;
        final thumb = m['thumbBase64'];
        if (thumb is String && thumb.isNotEmpty) {
          currentSize -= thumb.length;
          m.remove('thumbBase64');
          droppedThumbs++;
        }
      }

      final payload = {
        'version': 1,
        'roomId': roomId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'messages': messages.reversed.toList(),
      };
      final json = jsonEncode(payload);
      await _channel.invokeMethod('pushMessages', {
        'roomId': roomId,
        'json': json,
      });
      Logs().d(
        '[WearBridge] pushed ${messages.length} msgs for $roomId '
        '(${json.length} bytes, droppedThumbs=$droppedThumbs)',
      );
    } catch (e, st) {
      Logs().w('[WearBridge] pushMessages failed for $roomId', e, st);
    }
  }

  Future<Map<String, dynamic>> _serializeMessageWithMedia(
    Event event,
    String? ownUserId,
  ) async {
    final base = _serializeMessage(event, ownUserId);
    if (base['type'] == 'image' || base['type'] == 'video') {
      try {
        final thumb = await _generateThumbnail(event);
        if (thumb != null) {
          base['thumbBase64'] = base64Encode(thumb);
        }
      } catch (e) {
        Logs().d('[WearBridge] thumbnail failed for ${event.eventId}: $e');
      }
    }
    return base;
  }

  /// Télécharge l'image/vidéo Matrix, déchiffre si E2EE, downscale à 200x200
  /// JPEG q75 (~10-20 KB). Returns null si échec.
  Future<Uint8List?> _generateThumbnail(Event event) async {
    Uint8List? raw;
    try {
      final file = await event.downloadAndDecryptAttachment(getThumbnail: true);
      raw = file.bytes;
    } catch (_) {
      try {
        final file = await event.downloadAndDecryptAttachment(getThumbnail: false);
        raw = file.bytes;
      } catch (_) {
        return null;
      }
    }
    if (raw.isEmpty) return null;

    // Décode + downscale + JPEG q75 via package:image.
    // Run hors UI thread pour ne pas bloquer le rendering.
    return await compute(_resizeAndEncodeJpeg, raw);
  }

  bool _isRenderableEvent(Event e) {
    if (e.redacted) return false;
    switch (e.type) {
      case EventTypes.Message:
      case EventTypes.Sticker:
      case EventTypes.Encrypted:
        return true;
      default:
        return false;
    }
  }

  Map<String, dynamic> _serializeMessage(Event e, String? ownUserId) {
    final isOwn = e.senderId == ownUserId;
    final senderName = e.senderFromMemoryOrFallback.calcDisplayname();
    var type = 'text';
    int? audioDurationMs;
    var body = e.body;
    if (e.type == EventTypes.Sticker) {
      type = 'sticker';
    } else if (e.type == EventTypes.Message) {
      switch (e.messageType) {
        case MessageTypes.Audio:
          type = 'audio';
          final info = e.content['info'] as Map<String, dynamic>?;
          final dur = info?['duration'];
          if (dur is int) audioDurationMs = dur;
          if (body.isEmpty) body = 'Vocal';
          break;
        case MessageTypes.Image:
          type = 'image';
          if (body.isEmpty) body = '📷 Photo';
          break;
        case MessageTypes.Video:
          type = 'video';
          if (body.isEmpty) body = '🎬 Vidéo';
          break;
        case MessageTypes.File:
          type = 'file';
          if (body.isEmpty) body = '📎 Fichier';
          break;
        case MessageTypes.Location:
          type = 'text';
          if (body.isEmpty) body = '📍 Position';
          break;
        default:
          type = 'text';
      }
    }
    // Pas de truncate body — la Watch affiche le message complet et scroll si trop long.
    // Limite hard pour ne pas exploser le DataItem 100KB : 8KB par message.
    if (body.length > 8000) {
      body = '${body.substring(0, 8000)}…';
    }

    // Si le message a un formatted_body HTML (Matrix custom HTML), on le pousse à
    // la Watch qui sait parser inline tags <b>, <i>, <code>, <a>, <s>, <blockquote>, <br>.
    String? formattedBody;
    if (e.type == EventTypes.Message) {
      final format = e.content['format'] as String?;
      final fb = e.content['formatted_body'] as String?;
      if (format == 'org.matrix.custom.html' && fb != null && fb.isNotEmpty) {
        formattedBody = fb.length > 8000 ? '${fb.substring(0, 8000)}…' : fb;
      }
    }

    return {
      'id': e.eventId,
      'senderId': e.senderId,
      'senderName': senderName,
      'ts': e.originServerTs.millisecondsSinceEpoch,
      'type': type,
      'body': body,
      'formattedBody': ?formattedBody,
      'isOwn': isOwn,
      'audioDurationMs': ?audioDurationMs,
      'isRedacted': e.redacted,
    };
  }

  /// Abonne le bridge au sync d'un Client Matrix.
  void attach(Client client) {
    if (!_isAndroid) return;
    wireIfNeeded();
    final name = client.clientName;
    if (_syncSubs.containsKey(name)) return;
    _clients[name] = client;
    _syncSubs[name] = client.onSync.stream.listen((_) {
      _scheduleSnapshot();
    });
    Logs().d('[WearBridge] attached client $name (${client.userID})');
    _scheduleSnapshot(immediate: true);
  }

  /// Détache un client (logout / cleanup).
  void detach(String clientName) {
    _syncSubs.remove(clientName)?.cancel();
    _clients.remove(clientName);
  }

  void _scheduleSnapshot({bool immediate = false}) {
    if (immediate) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _pushSnapshot();
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _pushSnapshot);
  }

  Future<void> _pushSnapshot() async {
    if (!_isAndroid) return;
    final client = _clients.values.firstOrNull;
    if (client == null) return;

    try {
      final rooms = client.rooms.where(_isEligible).toList()
        ..sort(_byActivityDesc);

      final favorites = rooms.where((r) => r.isFavourite).take(_topRecentsCount).toList();
      final favoriteIds = favorites.map((r) => r.id).toSet();
      final recents = rooms
          .where((r) => !favoriteIds.contains(r.id))
          .take(_topRecentsCount)
          .toList();

      final payload = {
        'version': 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'favorites': favorites.map(_serializeRoom).toList(),
        'recents': recents.map(_serializeRoom).toList(),
      };

      final json = jsonEncode(payload);
      await _channel.invokeMethod('pushRooms', {'json': json});
      Logs().d('[WearBridge] pushed ${favorites.length} fav + ${recents.length} recent (${json.length} bytes)');
    } on PlatformException catch (e, st) {
      Logs().w('[WearBridge] pushRooms platform error', e, st);
    } catch (e, st) {
      Logs().w('[WearBridge] pushRooms failed', e, st);
    }
  }

  bool _isEligible(Room room) {
    if (room.isSpace) return false;
    if (room.membership != Membership.join) return false;
    return true;
  }

  int _byActivityDesc(Room a, Room b) {
    final ta = a.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;
    final tb = b.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;
    return tb.compareTo(ta);
  }

  Map<String, dynamic> _serializeRoom(Room room) {
    final last = room.lastEvent;
    return {
      'id': room.id,
      'name': room.getLocalizedDisplayname(),
      'avatarMxc': room.avatar?.toString(),
      'unread': room.notificationCount,
      'highlight': room.highlightCount,
      'lastEventTs': last?.originServerTs.millisecondsSinceEpoch ?? 0,
      'preview': _buildPreview(room),
      'isDirect': room.isDirectChat,
      'isEncrypted': room.encrypted,
    };
  }

  String _buildPreview(Room room) {
    final last = room.lastEvent;
    if (last == null) return '';
    if (last.redacted) return '🗑️';
    final ownMessage = last.senderId == room.client.userID;
    final prefix = ownMessage
        ? 'Tu : '
        : (room.isDirectChat ? '' : '${last.senderFromMemoryOrFallback.calcDisplayname()} : ');
    if (last.type == EventTypes.Message) {
      switch (last.messageType) {
        case MessageTypes.Audio:
          return '$prefix🎤';
        case MessageTypes.Image:
          return '$prefix📷 Photo';
        case MessageTypes.Video:
          return '$prefix🎬 Vidéo';
        case MessageTypes.File:
          return '$prefix📎 Fichier';
        case MessageTypes.Sticker:
          return '${prefix}Sticker';
        case MessageTypes.Location:
          return '$prefix📍 Position';
        default:
          final body = last.body.replaceAll('\n', ' ').trim();
          return '$prefix${body.length > 80 ? '${body.substring(0, 80)}…' : body}';
      }
    }
    return prefix.trim();
  }

  bool get _isAndroid {
    if (kIsWeb) return false;
    try {
      return defaultTargetPlatform == TargetPlatform.android;
    } catch (_) {
      return false;
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Top-level pour `compute` isolate. Décode, downscale 200x200, encode JPEG q75.
/// Cible ~15 KB par thumbnail pour rester sous DataItem 100KB total.
Uint8List? _resizeAndEncodeJpeg(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    // Cover-fit 200x200 : downscale puis crop center
    final resized = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? null : 200,
      height: decoded.width >= decoded.height ? 200 : null,
      interpolation: img.Interpolation.average,
    );
    final cropped = img.copyCrop(
      resized,
      x: ((resized.width - 200) ~/ 2).clamp(0, resized.width),
      y: ((resized.height - 200) ~/ 2).clamp(0, resized.height),
      width: 200.clamp(0, resized.width),
      height: 200.clamp(0, resized.height),
    );
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 75));
  } catch (_) {
    return null;
  }
}
