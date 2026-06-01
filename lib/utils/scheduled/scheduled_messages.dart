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
    try {
      if (m.isSms) {
        await SmsBridge.instance.sendSms(m.smsAddress!, m.body);
      } else if (m.roomId != null) {
        final room = _client?.getRoomById(m.roomId!);
        if (room != null) {
          await room.sendTextEvent(m.body);
        }
      }
    } finally {
      _queue.removeWhere((e) => e.id == m.id);
      await _persist();
      _changes.add(null);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      _queue.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }
}
