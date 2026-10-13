import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/foundation.dart';
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

  /// Failed send attempts so far.
  final int attempts;

  /// Retries exhausted: kept in the queue (not silently dropped) until the user
  /// edits (retries) or cancels it.
  final bool failed;

  const ScheduledMessage({
    required this.id,
    required this.body,
    required this.sendAt,
    this.roomId,
    this.smsAddress,
    this.attempts = 0,
    this.failed = false,
  });

  bool get isSms => smsAddress != null;
  DateTime get sendAtTime => DateTime.fromMillisecondsSinceEpoch(sendAt);

  ScheduledMessage copyWith({
    String? body,
    int? sendAt,
    int? attempts,
    bool? failed,
  }) => ScheduledMessage(
    id: id,
    roomId: roomId,
    smsAddress: smsAddress,
    body: body ?? this.body,
    sendAt: sendAt ?? this.sendAt,
    attempts: attempts ?? this.attempts,
    failed: failed ?? this.failed,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'roomId': roomId,
    'smsAddress': smsAddress,
    'body': body,
    'sendAt': sendAt,
    'attempts': attempts,
    'failed': failed,
  };

  factory ScheduledMessage.fromJson(Map<String, dynamic> j) => ScheduledMessage(
    id: '${j['id']}',
    roomId: j['roomId'] as String?,
    smsAddress: j['smsAddress'] as String?,
    body: '${j['body'] ?? ''}',
    sendAt: (j['sendAt'] as num?)?.toInt() ?? 0,
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    failed: j['failed'] == true,
  );
}

/// Transport used by [ScheduledMessages] for SMS (injectable for tests).
class ScheduledSmsBackend {
  const ScheduledSmsBackend();

  /// Native AlarmManager scheduling (Android only).
  bool get supportsNative => defaultTargetPlatform == TargetPlatform.android;

  /// true once the SMS has been handed to the modem (even if the provider
  /// insert failed — it must then never be resent).
  Future<bool> submit(String address, String body) async =>
      await SmsBridge.instance.sendSms(address, body) != null;

  Future<bool> scheduleNative(ScheduledMessage m) =>
      SmsBridge.instance.scheduleNativeSms(
        id: m.id,
        address: m.smsAddress!,
        body: m.body,
        sendAt: m.sendAt,
      );

  Future<bool> cancelNative(String id) =>
      SmsBridge.instance.cancelNativeSms(id);

  Future<Map<String, String>> takeNativeResults() =>
      SmsBridge.instance.takeNativeSmsResults();
}

/// Persists scheduled messages and fires them at their due time.
///
/// SMS are handed to the native AlarmManager on Android (sent even if the app
/// is killed or the phone dozes); results are pulled back with
/// [syncNativeResults]. Matrix messages need a live client, so they fire from
/// Dart timers while the app runs, and overdue ones are flushed on [start].
class ScheduledMessages {
  ScheduledMessages._(this._backend);
  static final ScheduledMessages instance = ScheduledMessages._(
    const ScheduledSmsBackend(),
  );

  @visibleForTesting
  factory ScheduledMessages.forTesting(ScheduledSmsBackend backend) =>
      ScheduledMessages._(backend);

  static const String _prefsKey = 'chat.fluffy.scheduled_messages';

  /// Dart-side attempts before a message is marked [ScheduledMessage.failed].
  static const int maxAttempts = 5;

  final ScheduledSmsBackend _backend;
  final List<ScheduledMessage> _queue = [];
  final Map<String, Timer> _timers = {};

  /// Bumped on every (re)arm / cancel: a timer only fires if its generation
  /// is still current, so a cancelled or edited message can't go out.
  final Map<String, int> _generation = {};
  final Set<String> _inFlight = {};

  /// SMS ids currently owned by the native AlarmManager.
  final Set<String> _native = {};
  Timer? _nativePoll;

  Client? _client;
  bool _started = false;

  @visibleForTesting
  Duration overdueDelay = const Duration(seconds: 1);

  @visibleForTesting
  Duration Function(int attempts) retryDelay = (attempts) =>
      Duration(minutes: 1 << (attempts - 1).clamp(0, 6));

  @visibleForTesting
  Duration nativePollInterval = const Duration(seconds: 30);

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever the queue changes (add / cancel / fire).
  Stream<void> get changes => _changes.stream;

  List<ScheduledMessage> get all => List.unmodifiable(
    List.of(_queue)..sort((a, b) => a.sendAt.compareTo(b.sendAt)),
  );

  List<ScheduledMessage> forRoom(String roomId) =>
      _queue.where((m) => m.roomId == roomId).toList();

  List<ScheduledMessage> forSms(String address) =>
      _queue.where((m) => m.smsAddress == address).toList();

  /// Loads the persisted queue and arms timers. Idempotent; call once the
  /// Matrix client is available (needed to send Matrix messages).
  Future<void> start(Client? client) async {
    _client = client;
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    _queue
      ..clear()
      ..addAll(
        raw.map(
          (s) =>
              ScheduledMessage.fromJson(jsonDecode(s) as Map<String, dynamic>),
        ),
      );
    // Apply native results first: re-scheduling an SMS the AlarmManager
    // already sent would send it twice.
    await syncNativeResults();
    for (final m in List<ScheduledMessage>.from(_queue)) {
      await _arm(m);
    }
    _changes.add(null);
  }

  Future<void> schedule(ScheduledMessage message) async {
    _queue.add(message);
    await _persist();
    await _arm(message);
    _changes.add(null);
  }

  /// Returns false (and does nothing) if the message is already being sent.
  Future<bool> cancel(String id) async {
    if (_inFlight.contains(id)) return false;
    if (_native.contains(id) && !await _backend.cancelNative(id)) {
      // The alarm already fired: let its result decide.
      await syncNativeResults();
      return false;
    }
    _disarm(id);
    _queue.removeWhere((m) => m.id == id);
    await _persist();
    _changes.add(null);
    return true;
  }

  /// Edits a pending scheduled message in place: changes its [body] and/or
  /// [sendAt] while keeping the same id. Also retries a failed message.
  /// Returns false if the id is unknown or the message is already being sent.
  Future<bool> reschedule(String id, {String? body, int? sendAt}) async {
    if (_inFlight.contains(id)) return false;
    if (!_queue.any((m) => m.id == id)) return false;
    if (_native.contains(id) && !await _backend.cancelNative(id)) {
      await syncNativeResults();
      return false;
    }
    _disarm(id);
    final i = _queue.indexWhere((m) => m.id == id);
    if (i < 0) return false;
    final updated = _queue[i].copyWith(
      body: body,
      sendAt: sendAt,
      attempts: 0,
      failed: false,
    );
    _queue[i] = updated;
    await _persist();
    await _arm(updated);
    _changes.add(null);
    return true;
  }

  /// Pulls the outcome of natively sent SMS and updates the queue.
  Future<void> syncNativeResults() async {
    if (!_backend.supportsNative) return;
    final results = await _backend.takeNativeResults();
    if (results.isEmpty) return;
    var changed = false;
    results.forEach((id, result) {
      _native.remove(id);
      final i = _queue.indexWhere((m) => m.id == id);
      if (i < 0) return;
      changed = true;
      if (result == 'sent') {
        _queue.removeAt(i);
      } else {
        _queue[i] = _queue[i].copyWith(failed: true);
      }
    });
    if (_native.isEmpty) {
      _nativePoll?.cancel();
      _nativePoll = null;
    }
    if (changed) {
      await _persist();
      _changes.add(null);
    }
  }

  void _disarm(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    _timers.remove(id)?.cancel();
    _native.remove(id);
  }

  Future<void> _arm(ScheduledMessage m) async {
    _disarm(m.id);
    if (m.failed) return;
    final gen = _generation[m.id]!;
    if (m.isSms && _backend.supportsNative) {
      final ok = await _backend.scheduleNative(m);
      if (_generation[m.id] != gen) return;
      if (ok) {
        _native.add(m.id);
        _nativePoll ??= Timer.periodic(
          nativePollInterval,
          (_) => syncNativeResults(),
        );
        return;
      }
    }
    final delay = m.sendAtTime.difference(DateTime.now());
    _timers[m.id] = Timer(
      delay < overdueDelay ? overdueDelay : delay,
      () => _fire(m.id, gen),
    );
  }

  Future<void> _fire(String id, int gen) async {
    if (_generation[id] != gen) return;
    _timers.remove(id);
    final m = _queue.where((e) => e.id == id).firstOrNull;
    if (m == null || m.failed) return;

    _inFlight.add(id);
    var sent = false;
    var countsAsAttempt = true;
    try {
      if (m.isSms) {
        sent = await _backend.submit(m.smsAddress!, m.body);
      } else if (m.roomId != null) {
        final room = _client?.getRoomById(m.roomId!);
        if (room != null) {
          await room.sendTextEvent(m.body);
          sent = true;
        } else {
          // Client not synced yet (cold start): no send happened, so no
          // duplicate risk — just wait without burning an attempt.
          countsAsAttempt = false;
        }
      }
    } catch (e) {
      sent = false;
    } finally {
      _inFlight.remove(id);
    }

    final i = _queue.indexWhere((e) => e.id == id);
    if (sent) {
      if (i >= 0) _queue.removeAt(i);
      await _persist();
    } else if (i >= 0) {
      final attempts = countsAsAttempt ? m.attempts + 1 : m.attempts;
      final updated = m.copyWith(
        attempts: attempts,
        failed: attempts >= maxAttempts,
      );
      _queue[i] = updated;
      await _persist();
      if (!updated.failed) {
        _disarm(id);
        final next = _generation[id]!;
        _timers[id] = Timer(
          retryDelay(attempts == 0 ? 1 : attempts),
          () => _fire(id, next),
        );
      }
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
