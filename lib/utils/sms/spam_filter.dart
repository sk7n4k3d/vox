import 'dart:async';

import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, on-device spam filter for incoming SMS. No network, no server: a
/// small French-language + link heuristic combined with the contact book.
///
/// A thread is flagged when the sender is NOT a known contact AND at least two
/// criteria match among: a shortener/short link, an obvious spam keyword, or a
/// long numeric sender. Flagged threads are mirrored to the native persisted set
/// (see the plugin's markThreadSpam) so the notifier stays silent even when the
/// app is closed.
class SpamFilterService {
  SpamFilterService._();
  static final SpamFilterService instance = SpamFilterService._();

  static const String enabledKey = 'chat.fluffy.sms_spam_filter';
  static const String _threadsKey = 'chat.fluffy.sms_spam_threads';

  bool _enabled = true;
  final Set<String> _spam = {};
  bool _loaded = false;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever the enabled flag or the spam set changes.
  Stream<void> get changes => _changes.stream;

  bool get isEnabled => _enabled;
  Set<String> get spamThreadIds => Set.unmodifiable(_spam);
  bool isSpam(String threadId) => _spam.contains(threadId);

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(enabledKey) ?? true;
    _spam
      ..clear()
      ..addAll(prefs.getStringList(_threadsKey) ?? const []);
    _loaded = true;
    _changes.add(null);
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
    if (!enabled) {
      // Unflag everything so previously-hidden threads come back.
      for (final id in _spam.toList()) {
        await SmsBridge.instance.markThreadSpam(id, false);
      }
      _spam.clear();
      await _persist();
    }
    _changes.add(null);
  }

  /// Mirrors the native spam set into the Dart model at startup (covers threads
  /// flagged in a previous run / by the native side).
  Future<void> syncFromNative() async {
    final native = await SmsBridge.instance.listSpamThreads();
    var changed = false;
    for (final id in native) {
      if (_spam.add(id)) changed = true;
    }
    if (changed) {
      await _persist();
      _changes.add(null);
    }
  }

  /// Flags [threadId] as spam (idempotent) and silences it natively.
  Future<void> flag(String threadId) async {
    if (threadId.isEmpty) return;
    await SmsBridge.instance.markThreadSpam(threadId, true);
    if (_spam.add(threadId)) {
      await _persist();
      _changes.add(null);
    }
  }

  /// Restores a spam thread: unhides it and re-enables its notifications.
  Future<void> restore(String threadId) async {
    await SmsBridge.instance.markThreadSpam(threadId, false);
    if (_spam.remove(threadId)) {
      await _persist();
      _changes.add(null);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_threadsKey, _spam.toList());
  }

  // ── Heuristic ───────────────────────────────────────────────────────────────

  static final RegExp _urlRe =
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

  static const Set<String> _shorteners = {
    'bit.ly', 't.co', 'tinyurl.com', 'goo.gl', 'is.gd', 'cutt.ly',
    'rebrand.ly', 'buff.ly', 'ow.ly', 'shorturl.at', 'rb.gy', 'tiny.cc',
    'adf.ly', 'lnk.to', 'urlz.fr', 'linktr.ee', 's.id', 'shorturl',
  };

  static const List<String> _keywords = [
    'stop',
    'gratuit',
    'offre',
    'cliquez',
    'gagnez',
    'promo',
    'urgent',
    'sms info',
  ];

  /// True when [body] from [address] should be treated as spam. [hasContact]
  /// must be true when the sender resolves to a saved contact (never flagged).
  static bool looksLikeSpam({
    required String address,
    required String body,
    required bool hasContact,
  }) {
    if (hasContact) return false;
    var score = 0;
    final lower = body.toLowerCase();

    if (_hasShortLink(body)) score++;
    if (_keywords.any(lower.contains)) score++;
    final digits = address.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 8) score++;

    return score >= 2;
  }

  static bool _hasShortLink(String body) {
    for (final m in _urlRe.allMatches(body)) {
      final host = Uri.tryParse(m.group(0)!)?.host.toLowerCase() ?? '';
      if (host.isEmpty) continue;
      for (final s in _shorteners) {
        if (host == s || host.endsWith('.$s')) return true;
      }
    }
    return false;
  }
}
