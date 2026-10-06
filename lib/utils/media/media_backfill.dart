import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/media/media_exporter.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Message types the backfill treats as exportable media. Mirrors the live
/// hook in [MediaExporter] so both paths stay in sync.
const Set<String> kBackfillMediaMessageTypes = {
  MessageTypes.Image,
  MessageTypes.Video,
  MessageTypes.Sticker,
};

/// A timeline event reduced to what the walk needs. Deliberately free of
/// matrix-dart-sdk types so the walk can be unit-tested with fakes.
class MediaEventInfo {
  const MediaEventInfo({
    required this.eventId,
    required this.messageType,
    required this.senderId,
    this.redacted = false,
  });

  final String eventId;
  final String messageType;
  final String senderId;
  final bool redacted;
}

/// One room's history, paginated backwards.
abstract class MediaHistory {
  List<MediaEventInfo> get events;
  bool get canRequestHistory;
  Future<void> requestHistory();
}

/// Where the walk gets its work from.
abstract class MediaBackfillSource {
  /// Logged-in user id; their own messages are never exported.
  String get ownUserId;

  Future<List<String>> joinedRoomIds();
  Future<MediaHistory> history(String roomId);
}

/// Remembers rooms whose history was fully walked, so later runs skip them.
abstract class MediaBackfillStore {
  Future<Set<String>> loadDoneRooms();
  Future<void> markRoomDone(String roomId);
}

@immutable
class MediaBackfillProgress {
  const MediaBackfillProgress({
    this.running = false,
    this.finished = false,
    this.cancelled = false,
    this.roomsDone = 0,
    this.roomsTotal = 0,
    this.currentRoom = '',
    this.exported = 0,
    this.failed = 0,
    this.mmsExported = 0,
    this.error,
  });

  final bool running;
  final bool finished;
  final bool cancelled;
  final int roomsDone;
  final int roomsTotal;
  final String currentRoom;
  final int exported;
  final int failed;
  final int mmsExported;
  final String? error;

  MediaBackfillProgress copyWith({
    bool? running,
    bool? finished,
    bool? cancelled,
    int? roomsDone,
    int? roomsTotal,
    String? currentRoom,
    int? exported,
    int? failed,
    int? mmsExported,
    String? error,
  }) =>
      MediaBackfillProgress(
        running: running ?? this.running,
        finished: finished ?? this.finished,
        cancelled: cancelled ?? this.cancelled,
        roomsDone: roomsDone ?? this.roomsDone,
        roomsTotal: roomsTotal ?? this.roomsTotal,
        currentRoom: currentRoom ?? this.currentRoom,
        exported: exported ?? this.exported,
        failed: failed ?? this.failed,
        mmsExported: mmsExported ?? this.mmsExported,
        error: error ?? this.error,
      );
}

/// One-line human summary of a finished run, for snackbars.
String mediaBackfillSummary(MediaBackfillProgress progress) {
  if (progress.error != null) return 'Échec : ${progress.error}';
  final tail = progress.failed > 0 ? ' (${progress.failed} en échec)' : '';
  if (progress.cancelled) {
    return 'Interrompu — ${progress.exported + progress.mmsExported} médias '
        'exportés$tail.';
  }
  final parts = <String>[];
  if (progress.exported > 0) parts.add('${progress.exported} Matrix');
  if (progress.mmsExported > 0) parts.add('${progress.mmsExported} MMS');
  if (parts.isEmpty) {
    return progress.failed == 0
        ? 'Aucun nouveau média à exporter.'
        : 'Aucun média exporté$tail.';
  }
  return '${parts.join(' + ')} exportés vers la galerie$tail.';
}

/// Walks every room's history backwards, exporting each incoming image /
/// video the gallery does not have yet. Pure orchestration: the source, the
/// exporter and the done-room store are injected, so the walk is testable.
class MediaBackfillEngine {
  MediaBackfillEngine({
    required this.source,
    required this.store,
    required this.isExported,
    required this.exportEvent,
    this.onProgress,
  });

  final MediaBackfillSource source;
  final MediaBackfillStore store;

  /// Whether the gallery already holds this event's bytes.
  final Future<bool> Function(String eventId) isExported;

  /// Downloads and exports one event. Returns true when bytes were added.
  final Future<bool> Function(MediaEventInfo event) exportEvent;

  final void Function(MediaBackfillProgress progress)? onProgress;

  bool _cancelled = false;
  int _exported = 0;
  int _failed = 0;
  int _roomsDone = 0;
  int _roomsTotal = 0;
  int _roomFailures = 0;
  final Set<String> _seen = {};

  void cancel() => _cancelled = true;

  Future<MediaBackfillProgress> run() async {
    _cancelled = false;
    _exported = 0;
    _failed = 0;
    _roomsDone = 0;
    _seen.clear();

    Set<String> done;
    List<String> rooms;
    try {
      done = await store.loadDoneRooms();
      rooms = await source.joinedRoomIds();
    } catch (e) {
      return _finish(error: '$e');
    }
    final pending = rooms.where((id) => !done.contains(id)).toList();
    _roomsTotal = pending.length;
    _publish(running: true);

    for (final roomId in pending) {
      if (_cancelled) break;
      _publish(running: true, currentRoom: roomId);
      _roomFailures = 0;
      final completed = await _walkRoom(roomId);
      if (_cancelled) break;
      // A room is only marked done when its whole history was walked AND
      // every media event in it is now in the gallery. A single failure
      // (download error, MediaStore refusal) leaves the room pending, so a
      // later run retries just the missing items.
      if (completed && _roomFailures == 0) {
        try {
          await store.markRoomDone(roomId);
        } catch (_) {}
      }
      _roomsDone++;
      _publish(running: true);
    }

    return _finish();
  }

  /// Returns true when the room's whole history was walked (so it can be
  /// marked done). Returns false when cancelled, on error, or when the
  /// history stopped yielding new events before reaching the room creation.
  Future<bool> _walkRoom(String roomId) async {
    MediaHistory history;
    try {
      history = await source.history(roomId);
    } catch (e) {
      debugPrint('MediaBackfill: cannot open $roomId: $e');
      return false;
    }

    var scanned = 0;
    while (true) {
      final events = history.events;
      if (events.length < scanned) scanned = 0;
      for (var i = scanned; i < events.length; i++) {
        if (_cancelled) return false;
        final event = events[i];
        if (!kBackfillMediaMessageTypes.contains(event.messageType)) continue;
        if (event.redacted) continue;
        if (event.senderId == source.ownUserId) continue;
        if (!_seen.add(event.eventId)) continue;
        if (await isExported(event.eventId)) continue;
        bool ok;
        try {
          ok = await exportEvent(event);
        } catch (e) {
          debugPrint('MediaBackfill: export ${event.eventId} failed: $e');
          ok = false;
        }
        if (ok) {
          _exported++;
          _publish(running: true, currentRoom: roomId);
        } else {
          _roomFailures++;
          _failed++;
        }
        if (_cancelled) return false;
      }
      scanned = events.length;
      if (_cancelled) return false;
      if (!history.canRequestHistory) return true;
      final before = events.length;
      try {
        await history.requestHistory();
      } catch (e) {
        debugPrint('MediaBackfill: history request failed for $roomId: $e');
        return false;
      }
      if (history.events.length == before) return false;
    }
  }

  MediaBackfillProgress _finish({String? error}) {
    final progress = MediaBackfillProgress(
      running: false,
      finished: error == null && !_cancelled,
      cancelled: _cancelled,
      roomsDone: _roomsDone,
      roomsTotal: _roomsTotal,
      exported: _exported,
      failed: _failed,
      error: error,
    );
    onProgress?.call(progress);
    return progress;
  }

  void _publish({
    required bool running,
    String currentRoom = '',
  }) {
    onProgress?.call(
      MediaBackfillProgress(
        running: running,
        roomsDone: _roomsDone,
        roomsTotal: _roomsTotal,
        currentRoom: currentRoom,
        exported: _exported,
        failed: _failed,
      ),
    );
  }
}

/// App-wide entry point: wires the engine to the live Matrix client, the
/// gallery exporter and the persisted done-room set, then sweeps SMS/MMS.
class MediaBackfill {
  MediaBackfill._();
  static final MediaBackfill instance = MediaBackfill._();

  final ValueNotifier<MediaBackfillProgress> progress =
      ValueNotifier(const MediaBackfillProgress());

  MediaBackfillEngine? _engine;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start(Client client) async {
    if (_running) return;
    if (!AppSettings.autoExportMedia.value) {
      progress.value = const MediaBackfillProgress(
        error: 'Active « Exporter les médias vers la galerie » pour récupérer '
            'les médias.',
      );
      return;
    }
    _running = true;
    progress.value = const MediaBackfillProgress(running: true);

    try {
      final engine = MediaBackfillEngine(
        source: _MatrixMediaSource(client),
        store: _PrefsBackfillStore(),
        isExported: MediaExporter.instance.isExported,
        exportEvent: _exportMatrixEvent,
        onProgress: (p) => progress.value = p.copyWith(
          mmsExported: progress.value.mmsExported,
        ),
      );
      _engine = engine;
      final result = await engine.run();

      if (result.cancelled || result.error != null) {
        progress.value = result.copyWith(mmsExported: 0);
        return;
      }

      var mms = 0;
      try {
        mms = await SmsBridge.instance.exportAllMmsMedia() ?? 0;
      } catch (e) {
        debugPrint('MediaBackfill: MMS sweep failed: $e');
      }
      progress.value = result.copyWith(
        mmsExported: mms,
        finished: true,
        running: false,
      );
    } catch (e) {
      progress.value = MediaBackfillProgress(error: '$e');
    } finally {
      _running = false;
      _engine = null;
    }
  }

  void cancel() => _engine?.cancel();

  /// Exports every media of a single Matrix room, ignoring the done-room
  /// markers so the conversation is always fully rescanned.
  Future<MediaBackfillProgress> exportRoom(Client client, String roomId) async {
    if (_running) return progress.value;
    _running = true;
    progress.value = const MediaBackfillProgress(running: true);
    try {
      final engine = MediaBackfillEngine(
        source: _MatrixMediaSource(client, onlyRoomId: roomId),
        store: _NoopBackfillStore(),
        isExported: MediaExporter.instance.isExported,
        exportEvent: _exportMatrixEvent,
        onProgress: (p) => progress.value = p,
      );
      _engine = engine;
      final result = await engine.run();
      progress.value = result;
      return result;
    } catch (e) {
      final failure = MediaBackfillProgress(error: '$e');
      progress.value = failure;
      return failure;
    } finally {
      _running = false;
      _engine = null;
    }
  }

  /// Exports every media of a single SMS/MMS thread.
  Future<int> exportSmsThread(String threadId) async {
    try {
      return await SmsBridge.instance.exportAllMmsMedia(threadId: threadId) ?? 0;
    } catch (e) {
      debugPrint('MediaBackfill: SMS thread sweep failed: $e');
      return 0;
    }
  }

  /// Forgets which rooms were already walked so the next run rescans
  /// everything. Useful after export failures or a settings change.
  Future<void> reset() async {
    if (_running) return;
    await _PrefsBackfillStore().clearDoneRooms();
    progress.value = const MediaBackfillProgress();
  }

  Future<bool> _exportMatrixEvent(MediaEventInfo info) async {
    if (info is! _MatrixMediaEventInfo) return false;
    final event = info.event;
    final file = await event.downloadAndDecryptAttachment();
    final uri = await MediaExporter.instance.exportMatrixEvent(event, file);
    return uri != null;
  }
}

class _MatrixMediaSource implements MediaBackfillSource {
  _MatrixMediaSource(this.client, {this.onlyRoomId});

  final Client client;
  final String? onlyRoomId;

  @override
  String get ownUserId => client.userID ?? '';

  @override
  Future<List<String>> joinedRoomIds() async {
    if (client.userID == null) return const [];
    final only = onlyRoomId;
    if (only != null) {
      return client.getRoomById(only) == null ? const [] : [only];
    }
    return client.rooms.map((room) => room.id).toList(growable: false);
  }

  @override
  Future<MediaHistory> history(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('room $roomId is gone');
    return _MatrixMediaHistory(await room.getTimeline(limit: 50));
  }
}

class _MatrixMediaHistory implements MediaHistory {
  _MatrixMediaHistory(this._timeline);

  final Timeline _timeline;
  List<MediaEventInfo>? _cache;
  int _cacheLength = -1;

  @override
  List<MediaEventInfo> get events {
    final events = _timeline.events;
    if (_cache == null || _cacheLength != events.length) {
      _cache = List<MediaEventInfo>.generate(
        events.length,
        (i) => _MatrixMediaEventInfo(events[i]),
        growable: false,
      );
      _cacheLength = events.length;
    }
    return _cache!;
  }

  @override
  bool get canRequestHistory => _timeline.canRequestHistory;

  @override
  Future<void> requestHistory() => _timeline.requestHistory(historyCount: 100);
}

class _MatrixMediaEventInfo extends MediaEventInfo {
  _MatrixMediaEventInfo(this.event)
      : super(
          eventId: event.eventId,
          messageType: event.messageType,
          senderId: event.senderId,
          redacted: event.redacted,
        );

  final Event event;
}

/// Used for a single-conversation export: never reports a room as done, so
/// the walk always rescans the whole conversation.
class _NoopBackfillStore implements MediaBackfillStore {
  @override
  Future<Set<String>> loadDoneRooms() async => <String>{};

  @override
  Future<void> markRoomDone(String roomId) async {}
}

class _PrefsBackfillStore implements MediaBackfillStore {  static const String _key = 'chat.fluffy.media_backfill.rooms_done';

  @override
  Future<Set<String>> loadDoneRooms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  @override
  Future<void> markRoomDone(String roomId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = (prefs.getStringList(_key) ?? const <String>[]).toSet()
        ..add(roomId);
      await prefs.setStringList(_key, done.toList());
    } catch (_) {}
  }

  Future<void> clearDoneRooms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
