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
    int? byteLength,
  }) : byteLength = byteLength ?? utf8.encode(rawBody).length;

  final String rawBody;
  final int createdAtMs;
  int attempts;
  int nextAttemptAtMs;

  /// Vrai poids du corps sur le disque : OCTETS UTF-8, pas unités UTF-16.
  /// `String.length` comptait un SMS chargé en emoji ~2 × moins que sa taille
  /// réelle (audit 8960c5cc) — le « budget d'octets » n'en était pas un.
  final int byteLength;

  Map<String, Object?> toJson() => <String, Object?>{
    'raw_body': rawBody,
    'created_at_ms': createdAtMs,
    'attempts': attempts,
    'next_attempt_at_ms': nextAttemptAtMs,
    'bytes': byteLength,
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
      // Absent des fichiers écrits avant ce commit : recalculé, jamais déviné.
      byteLength: (value['bytes'] as num?)?.toInt(),
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

  /// Plafond de la file. Atteint, le NOUVEL entrant est refusé — jamais les
  /// anciens chassés : un événement pas encore envoyé est une donnée, pas un
  /// cache que l'on peut purger pour faire de la place (audit 8960c5cc).
  static const int maxItems = 500;

  /// Budget d'octets UTF-8 réels des corps en attente. 26 MiB : choisi pour
  /// que le média NOMINAL tienne toujours — [maxWebhookMediaBytes] (16 MiB)
  /// encodé en base64 pèse 22 369 624 octets, plus l'ossature JSON de
  /// l'événement (audit 8960c5cc : à 20 MiB, ces corps-là étaient
  /// structurellement rejetés, et leur rejet était invisible).
  static const int maxQueuedBytes = 26 * 1024 * 1024;

  /// Plafond d'un SEUL corps : le média nominal + marge. Un corps au-dessus
  /// ne peut jamais cohabiter avec quoi que ce soit d'utile ; il est refusé
  /// avec motif, la file existante reste intacte.
  static const int maxQueuedItemBytes = 23 * 1024 * 1024;

  /// Cadence du réveil.
  static const Duration tick = Duration(seconds: 60);

  final List<PendingWebhook> _items = [];

  /// Entrées en cours de POST. Elles restent dans [_items] (donc sur le
  /// fichier : un crash pendant l'envoi ne les perd pas) et cette liste les
  /// signale « en vol » : protection contre toute éviction future, et garde
  /// contre la résurrection après un `clear()` demandé pendant l'envoi.
  final List<PendingWebhook> _inFlight = [];

  /// incrémenté à chaque `clear()` : un envoi qui échoue APRÈS un clear
  /// volontaire de l'utilisateur ne doit pas réinsérer son corps.
  int _clearGeneration = 0;

  int _dropped = 0;
  String? _lastRejectReason;
  String? _lastRejectBody;

  /// Nombre d'événements écartés de la file (taille, budget ou compteur),
  /// pour l'UI des réglages.
  int get droppedCount => _dropped;

  /// Motif du dernier refus — observable par l'appelant, pas un simple log.
  String? get lastRejectReason => _lastRejectReason;

  /// Corps du dernier événement rebuté : l'appelant peut en tirer un repli
  /// (métadonnées seules) au lieu de le perdre.
  String? get lastRejectBody => _lastRejectBody;

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
      _reconcileBudgetOnLoad();
      pending.value = _items.length;
    } catch (e) {
      _unreadable = true;
      debugPrint('WebhookQueue: file illisible, fichier préservé: $e');
    }
  }

  /// Une file écrite par une build antérieure (sans budget d'octets, ou avec
  /// d'anciennes constantes) peut être héritée hors budget. La laisser telle
  /// quelle reporterait la perte sur le premier `add` — même de 13 octets —
  /// via l'éviction (audit 8960c5cc, sonde P3). La purge a lieu ICI, une
  /// seule fois, en tête (les plus anciens), et elle est comptée et journalisée
  /// : plus rien ne disparaît sans trace ni sans que l'ajout courant soit
  /// refusé à tort.
  void _reconcileBudgetOnLoad() {
    var bytes = _totalBytes();
    var purged = 0;
    while ((bytes > maxQueuedBytes || _items.length > maxItems) &&
        _items.isNotEmpty) {
      final gone = _items.removeAt(0);
      bytes -= gone.byteLength;
      purged++;
      _dropped++;
      _lastRejectReason =
          'file héritée hors budget : entrée de ${gone.byteLength} octets '
          'purgée';
    }
    if (purged > 0) {
      debugPrint(
        'WebhookQueue: $purged entrée(s) trop ancienne(s) purgée(s) au '
        'chargement ($bytes octets retenus / budget $maxQueuedBytes)',
      );
    }
  }

  int _totalBytes() {
    var n = 0;
    for (final i in _items) {
      n += i.byteLength;
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
  ///
  /// Retourne `true` si le corps est en file. Sinon **rejet explicite et
  /// observable** : motif dans [lastRejectReason], corps dans [lastRejectBody],
  /// compteur dans [droppedCount] — jamais d'éviction d'un élément existant
  /// pour faire de la place (audit 8960c5cc : chasser des événements non
  /// envoyés est une perte de données, y compris « en vol »).
  Future<bool> add(String rawBody) async {
    await _ensureLoaded();
    final bodyBytes = utf8.encode(rawBody).length;
    if (bodyBytes > maxQueuedItemBytes) {
      return _reject(
        rawBody,
        'corps de $bodyBytes octets > plafond par entrée ($maxQueuedItemBytes)',
      );
    }
    if (_items.length >= maxItems) {
      return _reject(rawBody, 'file saturée (${_items.length} entrées)');
    }
    if (_totalBytes() + bodyBytes > maxQueuedBytes) {
      return _reject(
        rawBody,
        'budget d\'octets atteint (${_totalBytes()} + $bodyBytes > '
        '$maxQueuedBytes)',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final base = AppSettings.webhookRetryBackoffS.value;
    _items.add(
      PendingWebhook(
        rawBody: rawBody,
        createdAtMs: now,
        nextAttemptAtMs: now + retryDelayMs(base, 1),
        byteLength: bodyBytes,
      ),
    );
    pending.value = _items.length;
    await _persist();
    if (_autoStart) start();
    return true;
  }

  /// Refus motivé et tracé : compteur pour l'UI, raison pour l'appelant,
  /// corps conservé pour un repli éventuel. La file, elle, ne bouge pas.
  bool _reject(String rawBody, String reason) {
    _dropped++;
    _lastRejectReason = reason;
    _lastRejectBody = rawBody;
    WebhookService.instance.recordQueueReject(reason);
    debugPrint('WebhookQueue: $reason — événement écarté, file inchangée');
    return false;
  }

  /// Vide la file (réglages : « vider maintenant »).
  Future<void> clear() async {
    await _ensureLoaded();
    _items.clear();
    // Un envoi en vol dont l'échec tomberait APRÈS ce clear ne réinsérera
    // pas son corps : la demande explicite de l'utilisateur prime.
    _inFlight.clear();
    _clearGeneration++;
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
    var changed = false;

    for (final item in List<PendingWebhook>.of(_items)) {
      if (!force && item.nextAttemptAtMs > now) continue;
      if (now - item.createdAtMs > ttlMs) {
        // TTL dépassée : politique explicite (l'événement est trop vieux pour
        // intéresser Hermes), pas une eviction « pour faire de la place ».
        _items.remove(item);
        changed = true;
        continue;
      }
      // En vol : l'entrée RESTE dans _items (donc dans le fichier — un crash
      // pendant l'envoi ne la perd pas) et _inFlight la signale protégée :
      // son échec ne peut la faire disparaître (audit 8960c5cc, sonde P4).
      final generationAtSend = _clearGeneration;
      _inFlight.add(item);
      final sent = await _postRaw(item.rawBody);
      _inFlight.remove(item);
      if (sent) {
        _items.remove(item);
        changed = true;
        continue;
      }
      item.attempts++;
      if (item.attempts >= maxAttempts) {
        _items.remove(item);
        changed = true;
        continue;
      }
      item.nextAttemptAtMs = now + retryDelayMs(base, item.attempts);
      // Réinsertion en tête : le prochain FIFO le retentera en premier.
      // Sauf si l'utilisateur a vidé la file pendant l'envoi — un clear
      // volontaire ne doit pas être contredit par un échec tardif.
      if (generationAtSend == _clearGeneration && _items.contains(item)) {
        _items.remove(item);
        _items.insert(0, item);
      }
      changed = true;
    }
    pending.value = _items.length;
    if (changed) await _persist();
  }
}
