import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_hooks.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pousse vers la boîte Hermes le **journal d'appels** puis les
/// **enregistrements d'appels** (app Téléphone de GrapheneOS).
///
/// Pourquoi : la détection « à qui je n'ai pas répondu » ne regardait que les
/// messages. Si Bastien n'a pas répondu par SMS mais a **appelé** la personne,
/// l'agent le ressortait quand même comme sans réponse. Un appel arrive donc
/// comme un événement `direction: out` **dans le même fil** que les SMS du
/// numéro, et la requête côté Hermes le compte comme réponse.
///
/// Chaque appel reçu, émis ou manqué part ; l'enregistrement (un `.m4a` par
/// appel, écrit par l'app Téléphone de GrapheneOS) est ensuite envoyé **sur le
/// même identifiant d'événement**, donc la ligne de l'appel est remplacée par la
/// version qui porte l'audio — une seule ligne par appel, indexée par le
/// numéro, l'heure, le sens et la durée.
///
/// Idempotent : identifiants stables (`call-<id>`, `rec-<nom>`) et Hermes fait
/// un `INSERT OR REPLACE` ; le renvoi du même média ne crée pas de doublon
/// (l'ingestion purge les médias de l'événement avant de réinsérer).
class WebhookCalls {
  WebhookCalls._();
  static final WebhookCalls instance = WebhookCalls._();

  /// Fenêtre du premier import : la même que la détection de non-réponse (48 h).
  static const Duration firstImport = Duration(hours: 48);

  /// Cadence du rattrapage tant que l'app vit.
  static const Duration tick = Duration(minutes: 5);

  /// Un peu de recul sur la dernière date vue, pour ne pas rater un appel qui
  /// tombe exactement à la frontière (les doublons sont écrasés).
  static const int _overlapMs = 60 * 1000;

  /// Écart toléré entre l'heure du nom d'un enregistrement et celle du journal.
  static const int _matchToleranceMs = 180 * 1000;

  static const String _lastCallKey = 'chat.fluffy.webhook_calls_last_ms_v2';
  static const String _lastRecordingKey =
      'chat.fluffy.webhook_recordings_last_ms_v3';

  Timer? _timer;
  bool _running = false;

  /// Démarre le rattrapage (idempotent).
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(tick, (_) => unawaited(sync()));
    unawaited(sync());
  }

  /// Lit le journal, puis les enregistrements nouveaux. Best-effort.
  Future<void> sync() async {
    if (_running) return;
    if (!AppSettings.webhookCallsEnabled.value) return;
    if (!WebhookService.instance.isConfigured) return;
    if (!await SmsBridge.instance.isCallLogGranted()) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Un seul scan des conversations, réutilisé pour résoudre chaque numéro.
      final conversations = await SmsBridge.instance.listConversations();
      final threads = conversations.map(
        (c) => (threadId: c.threadId, address: c.address),
      );
      await _syncCalls(prefs, threads);
      await _syncRecordings(prefs, threads);
    } catch (e) {
      debugPrint('WebhookCalls: synchronisation échouée: $e');
    } finally {
      _running = false;
    }
  }

  Future<void> _syncCalls(
    SharedPreferences prefs,
    Iterable<({String threadId, String address})> threads,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final since =
        (prefs.getInt(_lastCallKey) ?? now - firstImport.inMilliseconds) -
        _overlapMs;
    final calls = await SmsBridge.instance.listCalls(sinceMs: since);
    if (calls.isEmpty) return;
    var newest = since;
    for (final call in calls) {
      final threadId = smsThreadIdForAddress(threads, call.number);
      // Trace de diagnostic : type d'appel et fil retrouvé (jamais le numéro).
      await SmsBridge.instance.nativeLog(
        'VOXCALL id=${call.id} type=${call.type} fil=${threadId ?? "-"}',
      );
      await WebhookService.instance.dispatch(
        WebhookEvent(
          source: WebhookSource.call,
          eventId: 'call-${call.id}',
          outgoing: callIsOutgoing(call.type),
          timestamp: DateTime.fromMillisecondsSinceEpoch(call.date),
          sender: call.number,
          senderName: call.name,
          body: callLabel(call.type, call.duration),
          threadId: threadId,
        ),
      );
      if (call.date > newest) newest = call.date;
    }
    await prefs.setInt(_lastCallKey, newest);
  }

  /// Envoie les enregistrements d'appels pas encore poussés (curseur sur la date
  /// de dernière modification du fichier, qui marque la fin de l'appel).
  Future<void> _syncRecordings(
    SharedPreferences prefs,
    Iterable<({String threadId, String address})> threads,
  ) async {
    if (!AppSettings.webhookRecordings.value) return;
    final recordings = await SmsBridge.instance.listCallRecordings();
    if (recordings.isEmpty) return;
    final cursor = prefs.getInt(_lastRecordingKey) ?? 0;
    final fresh = recordings.where((r) => r.modified > cursor).toList();
    if (fresh.isEmpty) return;

    // Le journal sur la même fenêtre, pour retrouver l'appel de chaque fichier.
    final oldest = fresh
        .map(
          (r) =>
              callRecordingStarted(r.name)?.millisecondsSinceEpoch ??
              r.modified,
        )
        .reduce((a, b) => a < b ? a : b);
    final calls = await SmsBridge.instance.listCalls(
      sinceMs: oldest - _matchToleranceMs,
      limit: 500,
    );

    var newest = cursor;
    // Un même appel peut avoir deux fichiers (rappels, boîte vocale) : on
    // n'écrase jamais un enregistrement avec un autre, sinon le premier resterait
    // sur le disque sans ligne qui le référence — et la purge des fichiers non
    // référencés le supprimerait.
    final usedTargets = <String>{};
    for (final recording in fresh) {
      final started = callRecordingStarted(recording.name);
      final number = callRecordingNumber(recording.name);
      final matched = _matchCall(calls, number, started);
      var eventId = matched != null ? 'call-${matched.id}' : '';
      if (eventId.isEmpty || !usedTargets.add(eventId)) {
        eventId = 'rec-${recording.name}';
        usedTargets.add(eventId);
      }
      final media = await WebhookHooks.fileMedia(
        recording.path,
        recording.name,
        mimeType: 'audio/mp4',
      );
      await WebhookService.instance.dispatch(
        WebhookEvent(
          source: WebhookSource.call,
          // Même identifiant que l'appel quand il est unique : la ligne porte
          // alors l'audio. Sinon identifiant propre au fichier (jamais écrasé).
          eventId: eventId,
          outgoing: matched != null && callIsOutgoing(matched.type),
          timestamp: started ?? DateTime.fromMillisecondsSinceEpoch(
            recording.modified,
          ),
          sender: number ?? matched?.number ?? '',
          senderName: matched?.name,
          body: matched != null
              ? callLabel(matched.type, matched.duration)
              : "Enregistrement d'appel",
          threadId: number == null
              ? null
              : smsThreadIdForAddress(threads, number),
          media: [media],
        ),
      );
      await SmsBridge.instance.nativeLog(
        'VOXREC ${recording.name} taille=${recording.size} '
        'appel=${matched?.id ?? "-"}',
      );
      if (recording.modified > newest) newest = recording.modified;
    }
    await prefs.setInt(_lastRecordingKey, newest);
  }

  /// L'appel correspondant à un enregistrement : même numéro (normalisé) et
  /// date la plus proche dans la tolérance.
  SmsCall? _matchCall(List<SmsCall> calls, String? number, DateTime? started) {
    if (number == null || started == null) return null;
    final target = normalizeSmsAddress(number);
    final targetMs = started.millisecondsSinceEpoch;
    SmsCall? best;
    var bestDelta = 1 << 62;
    for (final call in calls) {
      if (normalizeSmsAddress(call.number) != target) continue;
      final delta = (call.date - targetMs).abs();
      if (delta <= _matchToleranceMs && delta < bestDelta) {
        best = call;
        bestDelta = delta;
      }
    }
    return best;
  }
}
