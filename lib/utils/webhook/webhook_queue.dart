import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/webhook/webhook_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Délai avant la n-ième tentative : `base × 2^(n-1)`, plafonné à une heure.
/// Pur, donc testable sans toucher au disque.
int retryDelayMs(int baseSeconds, int attempts) {
  final exp = attempts <= 1 ? 0 : attempts - 1;
  final capped = exp > 10 ? 10 : exp;
  final seconds = baseSeconds * (1 << capped);
  return (seconds > 3600 ? 3600 : seconds) * 1000;
}

/// Un envoi en attente : le corps JSON **brut**. On ne garde pas la signature :
/// elle couvre l'horodatage, donc chaque tentative est re-signée avec un
/// horodatage frais (rejouer la signature d'origine serait vu comme un rejeu).
class PendingWebhook {
  PendingWebhook({
    required this.rawBody,
    required this.createdAtMs,
    this.attempts = 0,
    this.nextAttemptAtMs = 0,
  });

  final String rawBody;
  final int createdAtMs;
  int attempts;
  int nextAttemptAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'raw_body': rawBody,
        'created_at_ms': createdAtMs,
        'attempts': attempts,
        'next_attempt_at_ms': nextAttemptAtMs,
      };

  static PendingWebhook? fromJson(Object? value) {
    if (value is! Map) return null;
    final raw = value['raw_body'];
    if (raw is! String || raw.isEmpty) return null;
    return PendingWebhook(
      rawBody: raw,
      createdAtMs: (value['created_at_ms'] as num?)?.toInt() ?? 0,
      attempts: (value['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAtMs: (value['next_attempt_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// File d'attente persistante des POST ratés : un fichier JSON dans le dossier
/// de l'app. Elle survit à un redémarrage et se vide dès qu'Hermes répond.
///
/// Les réessais ne tournent que tant que l'app vit (un réveil toutes les
/// [tick]) ; au lancement suivant, la file reprend où elle en était.
class WebhookQueue {
  WebhookQueue._();
  static final WebhookQueue instance = WebhookQueue._();

  /// Plafond de la file : au-delà, on jette les plus anciens. Un webhook muet
  /// pendant des jours ne doit pas faire grossir le fichier sans borne.
  static const int maxItems = 500;

  /// Cadence du réveil.
  static const Duration tick = Duration(seconds: 60);

  final List<PendingWebhook> _items = [];

  /// Nombre d'envois en attente, pour l'afficher dans les réglages.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  bool _loaded = false;
  Timer? _timer;

  int get length => _items.length;

  Future<File> _queueFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/webhook_queue.json');
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _queueFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      for (final entry in decoded) {
        final item = PendingWebhook.fromJson(entry);
        if (item != null) _items.add(item);
      }
      pending.value = _items.length;
    } catch (e) {
      debugPrint('WebhookQueue: file illisible: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _queueFile();
      final tmp = File('${file.path}.part');
      await tmp.writeAsString(
        jsonEncode(_items.map((i) => i.toJson()).toList()),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('WebhookQueue: écriture échouée: $e');
    }
  }

  /// Met un corps d'événement en attente. Le premier réessai est déjà décalé du
  /// délai de base : inutile de retaper tout de suite un serveur qui vient de
  /// refuser.
  Future<void> add(String rawBody) async {
    await _ensureLoaded();
    final now = DateTime.now().millisecondsSinceEpoch;
    final base = AppSettings.webhookRetryBackoffS.value;
    _items.add(
      PendingWebhook(
        rawBody: rawBody,
        createdAtMs: now,
        nextAttemptAtMs: now + retryDelayMs(base, 1),
      ),
    );
    if (_items.length > maxItems) {
      _items.removeRange(0, _items.length - maxItems);
    }
    pending.value = _items.length;
    await _persist();
    start();
  }

  /// Vide la file (réglages : « vider maintenant »).
  Future<void> clear() async {
    await _ensureLoaded();
    _items.clear();
    pending.value = 0;
    await _persist();
  }

  /// Démarre la boucle de réessai. Idempotent.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(tick, (_) => unawaited(flush()));
    unawaited(flush());
  }

  /// Tente d'envoyer ce qui est mûr. Un échec repart avec un délai doublé,
  /// jusqu'au plafond de tentatives ou au TTL.
  ///
  /// [force] ignore le délai d'attente (bouton « Réessayer » des réglages).
  Future<void> flush({bool force = false}) async {
    await _ensureLoaded();
    if (_items.isEmpty) return;
    if (AppSettings.webhookWifiOnly.value &&
        !await SmsBridge.instance.isOnWifi()) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttlMs = AppSettings.webhookRetryTtlH.value * 3600 * 1000;
    final maxAttempts = AppSettings.webhookRetryAttempts.value;
    final base = AppSettings.webhookRetryBackoffS.value;

    for (final item in List<PendingWebhook>.of(_items)) {
      if (!force && item.nextAttemptAtMs > now) continue;
      if (now - item.createdAtMs > ttlMs) {
        _items.remove(item);
        continue;
      }
      if (await WebhookService.instance.postRaw(item.rawBody)) {
        _items.remove(item);
        continue;
      }
      item.attempts++;
      if (item.attempts >= maxAttempts) {
        _items.remove(item);
        continue;
      }
      item.nextAttemptAtMs = now + retryDelayMs(base, item.attempts);
    }
    pending.value = _items.length;
    await _persist();
  }
}
