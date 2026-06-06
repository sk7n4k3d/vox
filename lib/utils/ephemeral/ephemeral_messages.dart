import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A disappearing-message duration preset, shared by Matrix rooms and SMS
/// threads. [afterRead] is special: the countdown starts when the message is
/// read (handled by the caller passing the read time), not when it's sent.
enum EphemeralDuration {
  off(null),
  afterRead(Duration.zero), // sentinel: armed on read, default 30s window
  seconds30(Duration(seconds: 30)),
  minutes5(Duration(minutes: 5)),
  hour1(Duration(hours: 1)),
  day1(Duration(days: 1)),
  week1(Duration(days: 7));

  const EphemeralDuration(this.value);

  /// The expiry delay, or null for [off]. For [afterRead] this is zero — the
  /// effective window is [afterReadWindow].
  final Duration? value;

  static const afterReadWindow = Duration(seconds: 30);

  bool get isActive => this != EphemeralDuration.off;

  static EphemeralDuration fromName(String? name) =>
      EphemeralDuration.values.firstWhere(
        (d) => d.name == name,
        orElse: () => EphemeralDuration.off,
      );
}

/// One pending expiry: redact (Matrix) or delete (SMS) the message at [expiresAt].
class _PendingExpiry {
  final String id; // unique key
  final String? roomId; // Matrix room, or null for SMS
  final String? smsThreadId; // SMS thread, or null for Matrix
  final String messageRef; // Matrix eventId, or SMS message id
  final bool smsIsMms;
  final int expiresAt; // epoch millis

  const _PendingExpiry({
    required this.id,
    required this.messageRef,
    required this.expiresAt,
    this.roomId,
    this.smsThreadId,
    this.smsIsMms = false,
  });

  bool get isSms => smsThreadId != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'smsThreadId': smsThreadId,
        'messageRef': messageRef,
        'smsIsMms': smsIsMms,
        'expiresAt': expiresAt,
      };

  factory _PendingExpiry.fromJson(Map<String, dynamic> j) => _PendingExpiry(
        id: '${j['id']}',
        roomId: j['roomId'] as String?,
        smsThreadId: j['smsThreadId'] as String?,
        messageRef: '${j['messageRef']}',
        smsIsMms: j['smsIsMms'] == true,
        expiresAt: (j['expiresAt'] as num?)?.toInt() ?? 0,
      );
}

/// Disappearing messages for VOX.
///
/// Two layers:
///  1. **Policy** — a per-conversation [EphemeralDuration] (persisted), used by
///     the UI and applied to every outgoing message in that conversation.
///  2. **Expiry queue** — concrete `(message, expiresAt)` entries persisted and
///     fired by local timers. On Matrix the message is redacted; on SMS it is
///     deleted from the native store. Only the *local user's own* messages are
///     enqueued — we can't redact others' Matrix events, and this keeps the
///     guarantee honest (best-effort for the peer, like any client-side
///     disappearing-message feature without server enforcement).
class EphemeralMessages extends ChangeNotifier {
  EphemeralMessages._();
  static final EphemeralMessages instance = EphemeralMessages._();

  static const _policyKey = 'chat.fluffy.ephemeral_policies';
  static const _queueKey = 'chat.fluffy.ephemeral_queue';

  /// convId -> duration name. convId is a Matrix roomId or `sms:<threadId>`.
  final Map<String, EphemeralDuration> _policies = {};
  final List<_PendingExpiry> _queue = [];
  final Map<String, Timer> _timers = {};

  Client? _client;
  bool _started = false;
  StreamSubscription<SmsIncoming>? _incomingSub;

  /// Stable convId helpers.
  static String smsConvId(String threadId) => 'sms:$threadId';

  EphemeralDuration policyFor(String convId) =>
      _policies[convId] ?? EphemeralDuration.off;

  bool isActiveFor(String convId) => policyFor(convId).isActive;

  Future<void> start(Client client) async {
    _client = client;
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    // Policies
    final rawPolicies = prefs.getString(_policyKey);
    if (rawPolicies != null && rawPolicies.isNotEmpty) {
      final map = (jsonDecode(rawPolicies) as Map).cast<String, dynamic>();
      _policies
        ..clear()
        ..addEntries(
          map.entries.map(
            (e) => MapEntry(e.key, EphemeralDuration.fromName('${e.value}')),
          ),
        );
    }
    // Queue
    final rawQueue = prefs.getStringList(_queueKey) ?? const [];
    _queue
      ..clear()
      ..addAll(
        rawQueue.map(
          (s) => _PendingExpiry.fromJson(jsonDecode(s) as Map<String, dynamic>),
        ),
      );
    for (final e in List<_PendingExpiry>.from(_queue)) {
      _arm(e);
    }
    // Apply the conversation policy to *received* SMS too: the chat page only
    // listens while open, so we subscribe here (app-lifetime) to catch incoming
    // SMS regardless of which screen is showing. MMS are skipped — their body is
    // downloaded asynchronously by the system and no rowId is available at
    // push time, so there is nothing reliable to target yet.
    _incomingSub ??= SmsBridge.instance.incoming.listen((sms) {
      if (sms.isMms || !sms.hasMessageId) return;
      final convId = smsConvId(sms.threadId);
      if (!isActiveFor(convId)) return;
      trackSmsMessage(sms.threadId, '${sms.messageId}');
    });
    notifyListeners();
  }

  Future<void> setPolicy(String convId, EphemeralDuration duration) async {
    if (duration == EphemeralDuration.off) {
      _policies.remove(convId);
    } else {
      _policies[convId] = duration;
    }
    await _persistPolicies();
    notifyListeners();
  }

  /// Enqueues an expiry for a just-sent Matrix message. [explicit] overrides the
  /// conversation policy (per-message duration). No-op if neither is active.
  Future<void> trackMatrixMessage(
    String roomId,
    String eventId, {
    EphemeralDuration? explicit,
  }) async {
    final duration = explicit ?? policyFor(roomId);
    final delay = _delayFor(duration);
    if (delay == null) return;
    await _enqueue(
      _PendingExpiry(
        id: '$roomId|$eventId',
        roomId: roomId,
        messageRef: eventId,
        expiresAt: DateTime.now().add(delay).millisecondsSinceEpoch,
      ),
    );
  }

  /// Enqueues an expiry for a sent or received SMS (and sent MMS) message.
  ///
  /// Received SMS are armed via the app-lifetime [_incomingSub] in [start]
  /// using the rowId the native SmsDeliverReceiver now emits. Received MMS are
  /// still not auto-expired: their body is downloaded asynchronously by the
  /// system, so no rowId exists at WAP-push time.
  Future<void> trackSmsMessage(
    String threadId,
    String messageId, {
    bool isMms = false,
    EphemeralDuration? explicit,
  }) async {
    final duration = explicit ?? policyFor(smsConvId(threadId));
    final delay = _delayFor(duration);
    if (delay == null) return;
    await _enqueue(
      _PendingExpiry(
        id: 'sms:$threadId|$messageId',
        smsThreadId: threadId,
        smsIsMms: isMms,
        messageRef: messageId,
        expiresAt: DateTime.now().add(delay).millisecondsSinceEpoch,
      ),
    );
  }

  Duration? _delayFor(EphemeralDuration duration) {
    if (!duration.isActive) return null;
    if (duration == EphemeralDuration.afterRead) {
      return EphemeralDuration.afterReadWindow;
    }
    return duration.value;
  }

  Future<void> _enqueue(_PendingExpiry e) async {
    // De-dupe: a message is only tracked once.
    if (_queue.any((q) => q.id == e.id)) return;
    _queue.add(e);
    await _persistQueue();
    _arm(e);
  }

  void _arm(_PendingExpiry e) {
    _timers.remove(e.id)?.cancel();
    final delay = DateTime.fromMillisecondsSinceEpoch(e.expiresAt)
        .difference(DateTime.now());
    _timers[e.id] = Timer(
      delay.isNegative ? const Duration(seconds: 1) : delay,
      () => _fire(e),
    );
  }

  Future<void> _fire(_PendingExpiry e) async {
    _timers.remove(e.id);
    try {
      if (e.isSms) {
        final smsId = int.tryParse(e.messageRef);
        if (smsId != null) {
          await SmsBridge.instance.deleteMessage(smsId, isMms: e.smsIsMms);
        }
      } else if (e.roomId != null) {
        final room = _client?.getRoomById(e.roomId!);
        // Redact only if the event still exists and isn't already redacted.
        if (room != null) {
          await room.redactEvent(e.messageRef);
        }
      }
    } catch (err) {
      // Network/permission failure: drop the entry rather than retrying forever.
      // (The next app run won't re-arm it because it's removed below.)
      debugPrint('EphemeralMessages expiry failed for ${e.id}: $err');
    } finally {
      _queue.removeWhere((q) => q.id == e.id);
      await _persistQueue();
      notifyListeners();
    }
  }

  Future<void> _persistPolicies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _policyKey,
      jsonEncode(_policies.map((k, v) => MapEntry(k, v.name))),
    );
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _queueKey,
      _queue.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  /// Tears down the incoming subscription and timers and re-points to a fresh
  /// client. Call on logout/login so Matrix redactions don't target a stale
  /// client and the incoming listener can be re-armed by the next [start].
  Future<void> reset() async {
    await _incomingSub?.cancel();
    _incomingSub = null;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _started = false;
    _client = null;
  }
}
