import 'dart:convert';

import 'package:fluffychat/utils/biometric_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-conversation lock for VOX.
///
/// A "conversation" here is identified by an opaque string id:
///  - Matrix rooms: the room id (`!abc:server`)
///  - SMS threads:  `sms:<threadId>`
///
/// The set of locked ids is persisted **encrypted** on-device via
/// [FlutterSecureStorage] only — it never touches the Matrix account, so the
/// homeserver never learns which conversations the user considers sensitive,
/// and SMS threads (which have no server side) are handled the same way.
///
/// Unlocking is **session-scoped**: a successful biometric/PIN auth marks the
/// conversation as unlocked in memory until the app is locked or killed. The
/// persisted set only records *which* conversations are locked, never their
/// unlocked state.
class ConversationLock extends ChangeNotifier {
  ConversationLock._();
  static final ConversationLock instance = ConversationLock._();

  static const _storageKey = 'chat.fluffy.locked_conversations';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Persisted: ids that are locked. Loaded once at [load].
  final Set<String> _locked = {};

  /// Session-only: ids the user has successfully unlocked since the last app
  /// lock. Cleared by [relock] (called when the app lock engages).
  final Set<String> _unlockedThisSession = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Stable id helpers so callers don't have to remember the scheme.
  static String smsId(String threadId) => 'sms:$threadId';

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<String>();
        _locked
          ..clear()
          ..addAll(list);
      }
    } catch (e) {
      // Corrupt/inaccessible store: fail closed to "nothing locked" rather than
      // throwing — a missing lock is recoverable, a crash at startup is not.
      debugPrint('ConversationLock load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _storage.write(
        key: _storageKey,
        value: jsonEncode(_locked.toList()),
      );
    } catch (e) {
      debugPrint('ConversationLock persist failed: $e');
    }
  }

  /// True when [id] is configured as locked (independent of session unlock).
  bool isLocked(String id) => _locked.contains(id);

  /// True when [id] is locked AND not yet unlocked this session — i.e. its
  /// content must stay hidden / gated right now.
  bool isHidden(String id) =>
      _locked.contains(id) && !_unlockedThisSession.contains(id);

  bool get hasAnyLock => _locked.isNotEmpty;

  Future<void> lock(String id) async {
    if (_locked.add(id)) {
      _unlockedThisSession.remove(id);
      await _persist();
      notifyListeners();
    }
  }

  /// Removes the lock entirely. Requires the conversation to already be
  /// unlocked this session (callers must gate this behind [authenticate]).
  Future<void> unlockPermanently(String id) async {
    if (_locked.remove(id)) {
      _unlockedThisSession.remove(id);
      await _persist();
      notifyListeners();
    }
  }

  /// Marks [id] as unlocked for the current session without removing its lock.
  void markUnlockedThisSession(String id) {
    if (_unlockedThisSession.add(id)) notifyListeners();
  }

  /// Re-engages all per-conversation locks (call when the app lock engages or
  /// the app is backgrounded). Persisted locks are untouched.
  void relock() {
    if (_unlockedThisSession.isEmpty) return;
    _unlockedThisSession.clear();
    notifyListeners();
  }

  /// Prompts biometric/PIN for [id]. On success, marks it unlocked for the
  /// session and returns true. If [id] isn't locked or is already unlocked,
  /// returns true immediately without prompting.
  Future<bool> authenticate(String id, String reason) async {
    if (!isHidden(id)) return true;
    final ok = await BiometricAuth.instance.authenticate(reason);
    if (ok) markUnlockedThisSession(id);
    return ok;
  }
}
