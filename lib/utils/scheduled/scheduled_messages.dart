import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A message queued to be sent at a future time. Works for both Matrix rooms
/// and native SMS threads (a [ScheduledMessage] is one or the other).
class ScheduledMessage {
  final String id;

  /// Matrix room id, or null for SMS.
  final String? roomId;

  /// SMS recipient address, or null for Matrix.
  final String? smsAddress;

  final String body;

  /// Epoch millis at which to send.
  final int sendAt;

  const ScheduledMessage({
    required this.id,
    required this.body,
    required this.sendAt,
    this.roomId,
    this.smsAddress,
  });

  bool get isSms => smsAddress != null;
  DateTime get sendAtTime => DateTime.fromMillisecondsSinceEpoch(sendAt);

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'smsAddress': smsAddress,
        'body': body,
        'sendAt': sendAt,
      };

  factory ScheduledMessage.fromJson(Map<String, dynamic> j) => ScheduledMessage(
        id: '${j['id']}',
        roomId: j['roomId'] as String?,
        smsAddress: j['smsAddress'] as String?,
        body: '${j['body'] ?? ''}',
        sendAt: (j['sendAt'] as num?)?.toInt() ?? 0,
      );
}

/// Persists scheduled messages and fires them at their due time. Local-only
/// (no server delayed-event dependency) so it works identically for Matrix and
/// SMS. Due-while-offline messages are flushed on the next [start].
///
/// Limitation (documented): if the device is fully powered off at the exact due
/// time, the message is sent when the app next runs [start] — same behaviour as
/// most "schedule send" implementations without a server-side queue.
class ScheduledMessages {
  ScheduledMessages._();
  static final ScheduledMessages instance = ScheduledMessages._();

  static const String _prefsKey = 'chat.fluffy.scheduled_messages';

  final List<ScheduledMessage> _queue = [];
  final Map<String, Timer> _timers = {};
  Client? _client;
  bool _started = false;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever the queue changes (add / cancel / fire).
  Stream<void> get changes => _changes.stream;

  List<ScheduledMessage> get all =>
      List.unmodifiable(_queue..sort((a, b) => a.sendAt.compareTo(b.sendAt)));

  List<ScheduledMessage> forRoom(String roomId) =>
      _queue.where((m) => m.roomId == roomId).toList();

  List<ScheduledMessage> forSms(String address) =>
      _queue.where((m) => m.smsAddress == address).toList();

  /// Loads the persisted queue and arms timers. Idempotent; call once the
  /// Matrix client is available (needed to send Matrix messages).
  Future<void> start(Client client) async {
    _client = client;
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    _queue
      ..clear()
      ..addAll(
        raw.map(
          (s) => ScheduledMessage.fromJson(
            jsonDecode(s) as Map<String, dynamic>,
          ),
        ),
      );
    for (final m in List<ScheduledMessage>.from(_queue)) {
      _arm(m);
    }
    _changes.add(null);
  }

  Future<void> schedule(ScheduledMessage message) async {
    _queue.add(message);
    await _persist();
    _arm(message);
    _changes.add(null);
  }

  Future<void> cancel(String id) async {
    _timers.remove(id)?.cancel();
    _queue.removeWhere((m) => m.id == id);
    await _persist();
    _changes.add(null);
  }

  /// Edits a pending scheduled message in place: changes its [body] and/or
  /// [sendAt] while keeping the same id (so the row never disappears from the
  /// manage sheet, unlike a cancel+recreate). Re-arms the timer and persists.
  /// No-op if the id is unknown or the message has already fired.
  Future<void> reschedule(String id, {String? body, int? sendAt}) async {
    final i = _queue.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final old = _queue[i];
    final updated = ScheduledMessage(
      id: old.id,
      roomId: old.roomId,
      smsAddress: old.smsAddress,
      body: body ?? old.body,
      sendAt: sendAt ?? old.sendAt,
    );
    _queue[i] = updated;
    await _persist();
    _arm(updated);
    _changes.add(null);
  }

  void _arm(ScheduledMessage m) {
    _timers.remove(m.id)?.cancel();
    final delay = m.sendAtTime.difference(DateTime.now());
    if (delay.isNegative) {
      // Overdue (queued while offline) — fire as soon as possible.
      _timers[m.id] = Timer(const Duration(seconds: 1), () => _fire(m));
    } else {
      _timers[m.id] = Timer(delay, () => _fire(m));
    }
  }

  Future<void> _fire(ScheduledMessage m) async {
    _timers.remove(m.id);
    var sent = false;
    try {
      if (m.isSms) {
        // sendSms returns the inserted rowId, or null on failure (not default
        // SMS app, no SIM, invalid number). Only treat a non-null id as sent —
        // otherwise the message would be silently dropped from the queue.
        final rowId = await SmsBridge.instance.sendSms(m.smsAddress!, m.body);
        sent = rowId != null;
      } else if (m.roomId != null) {
        final room = _client?.getRoomById(m.roomId!);
        if (room != null) {
          await room.sendTextEvent(m.body);
          sent = true;
        }
        // room == null: client not synced yet (cold start). Leave queued and
        // re-arm shortly rather than dropping the message.
      }
    } catch (e) {
      // Network/SDK failure: keep the message and retry later.
      sent = false;
    }
    if (sent) {
      _queue.removeWhere((e) => e.id == m.id);
      await _persist();
    } else {
      // Re-arm a short retry so a transient failure doesn't lose the message.
      _timers[m.id] = Timer(const Duration(minutes: 1), () => _fire(m));
    }
    _changes.add(null);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      _queue.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }
}
