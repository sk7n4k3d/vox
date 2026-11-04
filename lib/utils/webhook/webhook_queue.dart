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
  WebhookQueue._(this._postRaw, {bool autoStart = true})
    : _autoStart = autoStart;

  static final WebhookQueue instance = WebhookQueue._(
    WebhookService.instance.postRaw,
  );

  /// Envoi d'un corps brut, injectable pour les tests de la file.
  final Future<bool> Function(String rawBody) _postRaw;

  /// Démarre la cadence dès un add. Désactivé par [forTest] pour que le test
  /// déclenche lui-même chaque flush.
  final bool _autoStart;

  /// File isolée pour les tests : ni disque ni timer, envoi simulé.
  @visibleForTesting
  factory WebhookQueue.forTest({
    required Future<bool> Function(String rawBody) postRaw,
  }) => WebhookQueue._(postRaw, autoStart: false);

  @visibleForTesting
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Plafond de la file : au-delà, on jette les plus anciens. Un webhook muet
  /// pendant des jours ne doit pas faire grossir le fichier sans borne.
  static const int maxItems = 500;

  /// Budget d'octets en plus du compteur : les corps portent parfois des
  /// médias base64 de plusieurs Mo — 500 entrées seules ne bornent pas la
  /// taille du fichier (audit 2026-11-04). Au-delà, éviction FIFO.
  static const int maxQueuedBytes = 20 * 1024 * 1024;

  /// Cadence du réveil.
  static const Duration tick = Duration(seconds: 60);

  final List<PendingWebhook> _items = [];

  /// Nombre d'envois en attente, pour l'afficher dans les réglages.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  bool _loaded = false;

  /// Le fichier existait mais était illisible : la file mémoire est alors
  /// potentiellement **amputée** des entrées déjà parties. Écrire par-dessus
  /// les effacerait sans retour, donc _persist refuse d'écraser un fichier
  /// qu'on n'a pas réussi à lire.
  bool _unreadable = false;
  Timer? _timer;

  /// Un flush à la fois : un POST de média peut durer plus longtemps que le
  /// tick de [tick] (timeout adapté à la taille, jusqu'à 2 min). Sans garde,
  /// le tick suivant — ou le bouton « Réessayer » — retenterait les mêmes
  /// corps pendant l'envoi en vol, en double.
  bool _flushing = false;

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
      await _purgeStaleParts(file);
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        _unreadable = true;
        debugPrint('WebhookQueue: fichier non reconnu, fichier préservé');
        return;
      }
      for (final entry in decoded) {
        final item = PendingWebhook.fromJson(entry);
        if (item != null) _items.add(item);
      }
      pending.value = _items.length;
    } catch (e) {
      _unreadable = true;
      debugPrint('WebhookQueue: file illisible, fichier préservé: $e');
    }
  }

  int _totalBytes() {
    var n = 0;
    for (final i in _items) {
      n += i.rawBody.length;
    }
    return n;
  }

  /// Les écritures atomiques passent par un fichier temporaire renommé
  /// ensuite. Un crash entre write et rename laisse des orphelins
  /// `<file>.part.<µs>` que plus personne ne vise : on les purge au
  /// chargement.
  Future<void> _purgeStaleParts(File queueFile) async {
    try {
      final dir = queueFile.parent;
      final prefix = '${queueFile.path}.part';
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.startsWith(prefix)) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {
      // repertoire illisible : rien à purger de toute façon
    }
  }

  Future<void> _persist() async {
    if (_unreadable) return;
    try {
      final file = await _queueFile();
      // suffixe unique : add() peut persister pendant qu'un flush de 2 min
      // persiste de son côté — deux écritures sur le même .part se
      // marchaient dessus (le second rename échouait, avalé).
      final tmp = File(
        '${file.path}.part.${DateTime.now().microsecondsSinceEpoch}',
      );
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
    // Un corps seul au-dessus du budget (un média 16 Mo en base64 ≈ 21 Mo) ne
    // JAMAIS tenir : l'éviction FIFO qui le suivrait viderait la file
    // entièrement, lui compris — perte sèche et silencieuse de tous les
    // événements non envoyés (audit suite, régression F3). On le refuse, les
    // autres restent intacts.
    if (rawBody.length > maxQueuedBytes) {
      debugPrint(
        'WebhookQueue: corps trop volumineux (${rawBody.length} octets > '
        '$maxQueuedBytes) écarté, file inchangée',
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final base = AppSettings.webhookRetryBackoffS.value;
    // Éviction anticipée : on ne chasse les plus anciens que dans la mesure où
    // le nouveau corps tient ensuite dans le budget — jamais le nouveau lui-
    // même (il est ajouté après la boucle).
    var bytes = _totalBytes();
    while (bytes + rawBody.length > maxQueuedBytes && _items.isNotEmpty) {
      bytes -= _items.removeAt(0).rawBody.length;
    }
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
    if (_autoStart) start();
  }

  /// Vide la file (réglages : « vider maintenant »).
  Future<void> clear() async {
    await _ensureLoaded();
    _items.clear();
    pending.value = 0;
    if (_unreadable) {
      // Demande explicite de l'utilisateur : on supprime le fichier qu'on
      // n'arrivait pas à lire, au lieu de le préserver indéfiniment.
      try {
        final file = await _queueFile();
        if (await file.exists()) await file.delete();
      } catch (_) {}
      _unreadable = false;
    }
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
  /// Retourne `false` si un envoi était déjà en vol et que ce flush a été
  /// ignoré — l'appelant peut le dire à l'utilisateur.
  Future<bool> flush({bool force = false}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      await _flushInner(force: force);
      return true;
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flushInner({required bool force}) async {
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
      if (await _postRaw(item.rawBody)) {
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
