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
///
/// Deux états de conservation, jamais des pertes (mandat 2026-11-05) :
/// - [suspended] : expiré (TTL) ou abandonné (plafond de tentatives). Reste
///   dans le fichier, plus jamais POSTé, hors de portée de tout sauf `clear()`
///   explicite ou [WebhookQueue.resumeSuspended] ;
/// - [invalidJson] : élément que cette version ne sait pas lire (corruption
///   externe). Conservé BRUT et réécrit tel quel — la file ne détruit ni
///   n'écrase ce qu'elle ne comprend pas.
class PendingWebhook {
  PendingWebhook({
    required this.rawBody,
    required this.createdAtMs,
    this.attempts = 0,
    this.nextAttemptAtMs = 0,
    int? byteLength,
    this.suspended = false,
  }) : invalidJson = null,
       byteLength = byteLength ?? utf8.encode(rawBody).length;

  /// Élément invalide : valeur d'origine conservée pour round-trip.
  PendingWebhook.invalid(this.invalidJson)
    : rawBody = '',
      createdAtMs = 0,
      attempts = 0,
      nextAttemptAtMs = 0,
      suspended = false,
      byteLength = utf8.encode(jsonEncode(invalidJson)).length;

  final String rawBody;

  /// Horodatage d'entrée en file : borne d'horloge du TTL. Repris à zéro par
  /// [WebhookQueue.resumeSuspended] — sinon un « Reprendre » sur un expiré
  /// serait re-suspendu à la passe suivante, ce qui vide le bouton de son
  /// sens.
  int createdAtMs;
  int attempts;
  int nextAttemptAtMs;

  /// Expiré ou abandonné : conservé, plus jamais envoyé (voir doc de classe).
  bool suspended;

  /// Valeur JSON d'un élément illisible, préservée telle quelle.
  final Object? invalidJson;

  bool get isInvalid => invalidJson != null;

  /// Vrai poids du corps sur le disque : OCTETS UTF-8, pas unités UTF-16.
  /// `String.length` comptait un SMS chargé en emoji ~2 × moins que sa taille
  /// réelle (audit 8960c5cc) — le « budget d'octets » n'en était pas un.
  final int byteLength;

  /// Élément sérialisé de la liste JSON : un invalide ressort byte-à-byte
  /// (aux re-formatages du ré-encodage près), jamais sous une forme inventée.
  Object toJsonElement() =>
      invalidJson ??
      <String, Object?>{
        'raw_body': rawBody,
        'created_at_ms': createdAtMs,
        'attempts': attempts,
        'next_attempt_at_ms': nextAttemptAtMs,
        'bytes': byteLength,
        if (suspended) 'suspended': true,
      };

  /// Décodage tolérant : JAMAIS d'exception remontrante. Un champ numérique
  /// mal typé ne doit pas rendre tout le fichier « illisible » (audit
  /// 557ca0bb, F4 : `as num?` jetait sur `'bytes': '12'`, le catch global
  /// déclarait le fichier entier `_unreadable`, la persistance se coupait et
  /// les éléments déjà envoyés repartaient en double). Ce qui n'est pas
  /// lisible devient un élément invalide PRÉSERVÉ BRUT ; ce qui est lisible
  /// avec des champs tordus est lu au plus près.
  static PendingWebhook decode(Object? value) {
    try {
      if (value is Map && value.containsKey('raw_body')) {
        final raw = value['raw_body'];
        // 'raw_body' String, même vide : un corps vide écrit par la file
        // elle-même n'est pas une corruption (audit 557ca0bb, F7 —
        // l'ancien garde isEmpty le re-classait « invalide » au rechargement
        // et il ne repartait plus jamais).
        if (raw is String) {
          return PendingWebhook(
            rawBody: raw,
            createdAtMs: _asInt(value['created_at_ms']) ?? 0,
            attempts: _asInt(value['attempts']) ?? 0,
            nextAttemptAtMs: _asInt(value['next_attempt_at_ms']) ?? 0,
            // Absent des fichiers écrits avant ces champs : faux/recalculé,
            // jamais déviné.
            byteLength: _asInt(value['bytes']),
            suspended: value['suspended'] == true,
          );
        }
      }
    } catch (_) {
      // tout ce qui résiste au parseur ci-dessus tombe en invalide préservé
    }
    return PendingWebhook.invalid(value);
  }

  static int? _asInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// File d'attente persistante des POST ratés : un fichier JSON dans le dossier
/// de l'app. Elle survit à un redémarrage et se vide dès qu'Hermes répond.
///
/// Les réessais ne tournent que tant que l'app vit (un réveil toutes les
/// [tick]) ; au lancement suivant, la file reprend où elle en était.
class WebhookQueue {
  WebhookQueue._(
    this._postRaw, {
    bool autoStart = true,
    bool desktopLock = false,
  }) : _autoStart = autoStart,
       _wantsLock = desktopLock;

  /// Verrou inter-processus (audit 557ca0bb, F13 — desktop uniquement) :
  /// deux instances qui s'ignorent s'écrasent mutuellement leur instantané,
  /// et le fichier de l'une disparaît au premier persist de l'autre. Sur
  /// Android la cible est mono-processus ; sur les builds bureau ce verrou
  /// rend la seconde instance silencieuse (refus d'ajouter, pas d'écrire)
  /// au lieu de destructive. Si la plateforme ne sait pas verrouiller, on
  /// reste sur l'hypothèse mono-instance — un échec de verrou ne bloque
  /// jamais l'envoi.
  final bool _wantsLock;
  RandomAccessFile? _lockHandle;
  bool _lockedByPeer = false;
  bool _lockUnsupported = false;
  bool _lastPersistFailed = false;

  /// Cas où le verrou lui-même tombe en panne alors qu'aucun pair ne le
  /// détient (NFS sans POSIX lock → ENOLCK, quota de verrous → EOVERFLOW,
  /// système de fichiers sans support) : rester FONCTIONNEL sans verrou,
  /// averti — un home monté en réseau ne doit pas désactiver le webhook
  /// pour toujours (audit ade1b6ba, finding 3). Seuls les codes de conflit
  /// réel (EAGAIN/EACCES/EWOULDBLOCK) mettent l'instance en retrait.
  static bool _isLockConflict(FileSystemException e) {
    final msg = e.osError?.message.toLowerCase() ?? '';
    return msg.contains('temporarily unavailable') ||
        msg.contains('resource busy') ||
        msg.contains('permission denied') ||
        msg.contains('deadlock') ||
        msg.contains('would block');
  }

  Future<void> _acquireLock(File queueFile) async {
    if (!_wantsLock || _lockHandle != null || _lockUnsupported) return;
    try {
      final raf = File('${queueFile.path}.lock').openSync(mode: FileMode.write);
      try {
        raf.lockSync(FileLock.exclusive);
        _lockHandle = raf;
        _lockedByPeer = false;
      } on FileSystemException catch (e) {
        await raf.close();
        if (_isLockConflict(e)) {
          _lockedByPeer = true;
          _tick();
          debugPrint(
            'WebhookQueue: une autre instance détient le fichier de file — '
            'cette instance est en retrait (réessai à chaque passe, elle '
            'reprendra la main quand le pair partira)',
          );
        } else {
          // verrou impossible mais pas de pair connu : continuer sans
          // verrou, hypothèse mono-processus + avertir l'UI — la garantie
          // « pas d écrasement croisé » ne tient plus, l utilisateur doit le
          // savoir (audit 3ca417b0, F5 : la branche était entièrement
          // silencieuse)
          _lockUnsupported = true;
          _lockedByPeer = false;
          _tick();
          final reason = e.osError?.message ?? e.message;
          debugPrint(
            'WebhookQueue: verrou inter-processus indisponible ($reason) — '
            'poursuite sans verrou (mono-processus supposé)',
          );
        }
      } catch (_) {
        _lockUnsupported = true;
        _lockedByPeer = false;
        _tick();
      }
    } catch (_) {
      // ouverture du fichier de verrou impossible (répertoire plein ou en
      // lecture seule) : ce n'est PAS un pair — poursuite, l écriture
      // échouera de toute façon et sera comptée par _lastPersistFailed
      _lockUnsupported = true;
      _lockedByPeer = false;
      _tick();
    }
  }

  /// Réévaluation du verrou : appelée à chaque passe de flush et avant
  /// chaque ajout. Sans elle, une instance mise en retrait par un pair le
  /// restait jusqu au redémarrage de l app, perdant chaque message pendant
  /// ce temps (finding 3, sonde H4b : pair tué, add toujours false).
  Future<void> _refreshLock() async {
    if (!_wantsLock || _lockUnsupported || _lockHandle != null) return;
    if (!_lockedByPeer) return;
    try {
      final file = await _queueFile();
      await _acquireLock(file);
      if (!_lockedByPeer) {
        // le pair est parti : cette instance devient détentrice et doit
        // charger l état (le retrait précédent n a rien lu)
        _loaded = false;
        await _ensureLoaded();
        _tick();
      }
    } catch (_) {}
  }

  void _releaseLock() {
    try {
      _lockHandle?.closeSync();
    } catch (_) {}
    _lockHandle = null;
  }

  static final WebhookQueue instance = WebhookQueue._(
    WebhookService.instance.postRaw,
    // builds bureau : deux instances peuvent coexister, le verrou les rend
    // coopératives. Mobile : mono-processus, rien à verrouiller.
    desktopLock: Platform.isLinux || Platform.isMacOS || Platform.isWindows,
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
    bool desktopLock = false,
  }) => WebhookQueue._(postRaw, autoStart: false, desktopLock: desktopLock);

  @visibleForTesting
  void stop() {
    _timer?.cancel();
    _timer = null;
    _releaseLock();
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

  /// Capacité dure du FICHIER (part active + suspendus + corrompus) :
  /// garde-fou disque, jamais porte d'entrée nominale — la porte d'entrée
  /// d'`add` se juge sur [maxQueuedBytes] côté actif (audit 557ca0bb, F2 :
  /// sinon les poids morts bloquent la file à jamais). Atteint, le refus
  /// motive la sortie praticable : reprendre ou archiver les suspendus —
  /// deux gestes explicites, aucun ne supprime de données.
  static const int maxFileBytes = 96 * 1024 * 1024;
  static const int maxFileItems = 4000;

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
  int _recovered = 0;
  int _persistErrors = 0;
  int _corrupt = 0;
  bool _corruptOnLoad = false;
  bool _corruptBackupDone = false;
  String? _lastRejectReason;
  int? _lastRejectBytes;
  bool _overBudget = false;
  int _persistSeq = 0;
  int _persistedSeq = 0;
  Future<bool> _persistTail = Future.value(true);

  /// Nombre d'événements écartés de la file (taille, budget ou compteur),
  /// pour l'UI des réglages.
  int get droppedCount => _dropped;

  /// Motif du dernier refus — observable par l'appelant, pas un simple log.
  String? get lastRejectReason => _lastRejectReason;

  /// Taille du dernier corps rebuté. Le corps lui-même n'est PAS conservé
  /// (audit e98bb2a8, finding LOW : jusqu'à 23 MiB de SMS/MMS sensibles en
  /// clair en RAM sans borne de durée, et aucun repli ne les lisait) — la
  /// taille et le motif restent consultables.
  int? get lastRejectBytes => _lastRejectBytes;

  /// File « sursaturée » : héritée ou grossie au-delà du budget d'une
  /// manière que la politique « zéro perte » interdit de corriger par
  /// purge. Les envois existants partent normalement ; tout ajout est refusé
  /// tant que le budget n'est pas redevenu libre. Consultable par l'UI.
  bool get overBudget => _overBudget;

  /// Nombre d'envois en attente, pour l'afficher dans les réglages.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  /// Battement notifié à CHAQUE transition d état qui intéresse l'UI —
  /// verrou, persistance en échec, rejet, récupération. `pending` seul ne
  /// suffit pas : la valeur peut ne pas bouger (file déjà vide) alors que
  /// l état, lui, a changé — la page ouverte restait muette sur le blocage
  /// comme sur les rejets (audit ade1b6ba, finding LOW compteurs).
  final ValueNotifier<int> uiTick = ValueNotifier<int>(0);

  void _tick() => uiTick.value++;

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
    // chargement sur table rasée : le seul rechargement possible vient de la
    // reprise du verrou, et laisser les anciens corps dans _items les ferait
    // double en RAM puis double sur le disque puis DOUBLE LIVRAISON (audit
    // 3ca417b0, INFO-2)
    _items.clear();
    _corrupt = 0;
    _recovered = 0;
    _corruptOnLoad = false;
    var over = false;
    File? file;
    try {
      file = await _queueFile();
      await _acquireLock(file);
      if (_lockedByPeer) {
        // état laissée tel quel par l'instance détentrice : ni lecture
        // (obsolète sitôt), ni écriture (écrasement), ni envoi (double)
        _tick();
        return;
      }
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! List) {
          throw const FormatException('racine non-List');
        }
        for (final entry in decoded) {
          final item = PendingWebhook.decode(entry);
          // Un élément qu'on ne sait pas lire N'EST PAS supprimé : il reste
          // dans _items en brut et ressort du prochain réencodé (audit
          // 6c8a1439 : « ignorée » en mémoire = effacée du disque au
          // premier persist).
          _items.add(item);
          if (item.isInvalid) {
            _corruptOnLoad = true;
            _corrupt++;
            WebhookService.instance.recordQueueCorrupt(
              'élément de la file non reconnu (${item.byteLength} octets) '
              'préservé tel quel',
            );
          }
        }
      }
      // File héritée déjà hors budget (builds antérieures sans plafond) :
      // on la charge INTÉGRALEMENT. Purger ici détruirait des événements non
      // envoyés (audit e98bb2a8, PROBE-3). Elle est marquée « sursaturée » :
      // les envois existants partent, tout ajout est refusé jusqu'au retour
      // sous le seuil.
      over = _activeBytes() > maxQueuedBytes || _activeCount() > maxItems;
      // Récupération des .part survivants APRÈS lecture du fichier
      // principal : le fsync du répertoire parent étant injoignable en Dart,
      // un crash peut laisser un instantané PLUS RÉCENT que le fichier
      // principal. Le supprimer sans l'ouvrir serait une perte (audit
      // 557ca0bb, F1). Tourne aussi quand le fichier principal est absent
      // (crash pendant la première écriture). Le watermark (seq/ts du
      // dernier renommage réussi) borne le sens opposé : un instantané plus
      // ancien est déjà sur le disque et ne doit rien écraser.
      final watermark = await _readWatermark(file);
      if (watermark != null && watermark.seq > _persistSeq) {
        // le compteur ne repart jamais en arrière, même après redémarrage
        _persistSeq = watermark.seq;
      }
      await _adoptStaleParts(
        file,
        mainMissing: !await file.exists(),
        watermark: watermark,
      );
    } catch (e) {
      _unreadable = true;
      _tick();
      debugPrint('WebhookQueue: fichier de file illisible, préservé: $e');
      // Un fichier principal illisible ne condamne pas la session si un
      // .part décodable survit : la récupération en tient lieu, après
      // copie de secours de l'épave.
      if (file != null) {
        try {
          await _adoptStaleParts(file, mainUnreadable: true);
        } catch (_) {}
      }
    }
    _overBudget = over;
    pending.value = _activeCount();
    // F3 (audit 3ca417b0) : le chargement EST une transition d'état — des
    // invalides découverts, un sursaturage, une récupération : la page déjà
    // ouverte doit les voir sans qu'un autre événement ne force un tick.
    _tick();
  }

  /// Union par corps : les événements d'un `.part` décodable absents de la
  /// mémoire y sont ajoutés, l'instantané est consolidé par persist, PUIS
  /// supprimé — quel que soit le nombre de corps fusionnés (audit ade1b6ba,
  /// finding 2), MAIS seulement si le persist a confirmé son écriture
  /// (audit 3ca417b0, F1) : sinon le `.part` survit et la consolidation est
  /// retentée au démarrage suivant. Un `.part` plus ancien que le dernier
  /// fichier écrit (watermark) est déjà sur le disque : supprimé sans rien
  /// adopter (INFO-1). Un `.part` qui ne se décode pas est un instantané
  /// INCOMPLET, pas un résidu : la coupure d'alimentation au milieu de
  /// l'écriture laisse du JSON tronqué portant des messages jamais envoyés —
  /// il est donc ARCHIVÉ en copie tournante `part-illisible.N` (conservée
  /// sans plafond) et compté, jamais détruit (finding 1). Le fichier
  /// principal illisible, lui, est copié avant d'être éventuellement
  /// remplacé.
  Future<void> _adoptStaleParts(
    File queueFile, {
    bool mainUnreadable = false,
    bool mainMissing = false,
    ({int seq, int ts})? watermark,
  }) async {
    final dir = queueFile.parent;
    final prefix = '${queueFile.path}.part.';
    final parts = <({int seq, int ts, File file})>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.startsWith(prefix)) continue;
        final seg = entity.path
            .substring(prefix.length)
            .split('.')
            .take(2)
            .toList();
        final seq = int.tryParse(seg.first) ?? 0;
        final ts = seg.length > 1 ? int.tryParse(seg[1]) ?? 0 : 0;
        parts.add((seq: seq, ts: ts, file: entity));
      }
    } catch (_) {
      return;
    }
    if (parts.isEmpty) return;
    parts.sort(
      (a, b) => a.seq != b.seq ? a.seq.compareTo(b.seq) : a.ts.compareTo(b.ts),
    );
    if (mainUnreadable && !mainMissing && _items.isEmpty) {
      // l'épave principale est sauvegardée avant d'être éventuellement
      // remplacée par la récupération
      try {
        if (await queueFile.exists()) {
          await _rotateBackup(queueFile, 'corrompu');
        }
      } catch (_) {}
    }
    final known = <String, PendingWebhook>{
      for (final i in _items) _identityKey(i): i,
    };
    final absorbed = <File>[];
    var merged = 0;
    var adoptedState = 0;
    for (final p in parts) {
      // watermark : le fichier principal a été écrit à ce (seq, ts) — tout
      // instantané plus ancien a donc déjà été absorbé par une écriture
      // réussie. Son état ne peut PAS gagner sur le plus récent (audit
      // 3ca417b0, INFO-1 : après un renommage raté dont le nettoyage a été
      // tué, un .part POUVAIT être plus vieux que le fichier principal et
      // réveillait un suspendu en écrasant tentatives/suspension).
      if (watermark != null &&
          (p.seq < watermark.seq ||
              (p.seq == watermark.seq && p.ts <= watermark.ts))) {
        try {
          await p.file.delete();
          debugPrint(
            'WebhookQueue: « .part » plus ancien que le dernier fichier '
            'écrit (seq ${p.seq} <= ${watermark.seq}) : déjà consolidé, '
            'supprimé sans rien adopter',
          );
        } catch (_) {}
        continue;
      }
      List<Object?>? list;
      try {
        final decoded = jsonDecode(await p.file.readAsString());
        if (decoded is List) list = decoded.cast<Object?>();
      } catch (_) {}
      if (list == null) {
        // instantané tronqué : copie tournante AVANT toute disparition,
        // compté comme corrompu, visible à l'UI — jamais détruit en silence
        // (audit ade1b6ba, finding 1). La cible vit hors de l'espace
        // « .part. » pour ne pas être rescannée comme un .part au boot.
        try {
          final size = await p.file.length();
          await _rotateBackup(
            p.file,
            'part-illisible',
            targetBase: '${queueFile.path}.part-illisible',
          );
          await p.file.delete();
          _corrupt++;
          debugPrint(
            'WebhookQueue: instantané « .part » tronqué ($size octets) '
            'archivé en copie « part-illisible » — la purge de ces copies '
            'relève d\'une demande explicite, jamais d\'un boot',
          );
        } catch (_) {}
        continue;
      }
      // un .part survivant est issu d'un renommage raté : son seq est
      // supérieur à celui du dernier fichier principal écrit. Pour une clé
      // déjà connue, ce sont DONC ses champs d'état qui gagnent (finding 6 :
      // un suspended/attempts du snapshot le plus récent ne doit pas être
      // annulé par l'état plus ancien du fichier principal).
      for (final entry in list) {
        final item = PendingWebhook.decode(entry);
        final key = _identityKey(item);
        final existing = known[key];
        if (existing == null) {
          known[key] = item;
          _items.add(item);
          if (item.isInvalid) {
            _corruptOnLoad = true;
            _corrupt++;
          }
          merged++;
        } else if (!item.isInvalid && !existing.isInvalid) {
          if (existing.suspended != item.suspended ||
              existing.attempts != item.attempts ||
              existing.nextAttemptAtMs != item.nextAttemptAtMs) {
            existing.suspended = item.suspended;
            existing.attempts = item.attempts;
            existing.nextAttemptAtMs = item.nextAttemptAtMs;
            existing.createdAtMs = item.createdAtMs;
            adoptedState++;
          }
        }
      }
      absorbed.add(p.file);
    }
    final dirty = merged > 0 || adoptedState > 0;
    var writeOk = !dirty;
    if (dirty) {
      // l'état récupéré porte désormais la mémoire : on consolide AVANT de
      // supprimer les .part absorbés — et on ne les supprime que si
      // l'écriture a VRAIMENT réussi : le commentaire promettait « jamais
      // l'inverse », seul le succès du renommage permettait de le garantir
      // (audit 3ca417b0, F1 — persist silencieux en échec, le .portait un
      // message jamais écrit partait quand même : traces=[] sur l'audit).
      if (_unreadable) {
        // le fichier principal est une épave déjà copiée : la récupération
        // devient l'état de référence
        _unreadable = false;
      }
      writeOk = await _persist();
      if (!writeOk) {
        debugPrint(
          'WebhookQueue: consolidation non arrivée sur le disque — les '
          '« .part » absorbés sont CONSERVÉS pour une nouvelle tentative au '
          'prochain démarrage (aucune perte, retente silencieuse)',
        );
      }
    }
    // writeOk : soit la consolidation vient d'être écrite et vérifiée, soit
    // elle était déjà faite (merged == 0, chaque corps porté par le fichier
    // principal). L'instantané n'a plus de raison d'exister : sinon il est
    // relu au prochain boot et redélivre (finding 2).
    if (writeOk) {
      for (final f in absorbed) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    _recovered += merged;
    if (merged > 0) {
      debugPrint(
        'WebhookQueue: $merged événement(s) récupéré(s) depuis un instantané '
        '« .part » plus récent que le fichier principal',
      );
    }
    if (adoptedState > 0) {
      debugPrint(
        'WebhookQueue: $adoptedState entrée(s) ont adopté l état (tentatives/'
        'suspension) du snapshot le plus récent',
      );
    }
  }

  static String _identityKey(PendingWebhook item) => item.isInvalid
      ? 'j:${jsonEncode(item.invalidJson)}'
      : 'b:${item.rawBody}';

  int _totalBytes() {
    var n = 0;
    for (final i in _items) {
      n += i.byteLength;
    }
    return n;
  }

  /// Les écritures atomiques passent par un fichier temporaire renommé
  /// ensuite ; les orphelins `.part` sont RÉCUPÉRÉS (voir _adoptStaleParts),
  /// plus purgés à l'aveugle. Les copies de secours tournent sans plafond :
  /// `.tag.1` (la plus récente) → `.tag.N`, conservées jusqu'à purge
  /// explicite (audit 3ca417b0, F2 — le plafond de 3 détruisait des épaves
  /// uniques au boot). La croissance est rendue visible dans la page
  /// Réglages (nombre + poids) plutôt que bornée en silencieux.
  /// Supprimer une copie au fil de l'eau serait détruire la seule trace d'un
  /// état antérieur — ces fichiers portent des corps de messages jamais
  /// envoyés (épaves de crash, états vidés) : eux aussi tombent sous le
  /// mandat « aucune suppression sans demande explicite » (audit 3ca417b0,
  /// F2 — la rotation bornée à 3 effaçait au boot des épaves que le même
  /// fichier promettait de ne jamais purger sans geste utilisateur).
  /// La surface disque est visible dans la page Réglages (« Copies de
  /// secours ») et la purge est un geste explicite avec confirmation.
  Future<void> _rotateBackup(
    File source,
    String tag, {
    String? targetBase,
  }) async {
    // base des cibles : par défaut le chemin de la source suffixé du tag ;
    // pour les .part tronqués on passe une base hors de l'espace « .part. »
    // sinon la copie serait rescannée comme un .part au boot suivant (et
    // resauvegardée, à l'infini).
    final base = targetBase ?? '${source.path}.$tag';
    // index courant le plus haut, puis décalage en cascade .N -> .N+1
    var top = 0;
    while (await File('$base.${top + 1}').exists()) {
      top++;
    }
    for (var n = top; n >= 1; n--) {
      try {
        await File('$base.$n').rename('$base.${n + 1}');
      } catch (_) {}
    }
    // Jamais File.copy quand la source est monde-lisible : la copie hérite
    // du mode de la source À LA CRÉATION, et le chmod ultérieur laisse
    // l'intégralité du contenu en clair accessible pendant toute la durée
    // de la copie (audit 3ca417b0, F4 / sonde RB5 : ~120 Mo en 644 pendant
    // ~0,5 s). Ici la destination est créée VIDE, durcie en 600, puis
    // remplie en flux : la fenêtre ne porte que du vide, et chaque octet
    // écrit l'est dans un fichier déjà 600.
    final dst = File('$base.1');
    try {
      await dst.create();
      await _hardenPermissions(dst);
      // pipe ferme le flux à la fin (succès comme erreur), contrairement à
      // addStream qui laisse l'IOSink ouvert donc le contenu en tampon
      await source.openRead().pipe(dst.openWrite());
    } catch (e) {
      try {
        if (await dst.exists()) await dst.delete();
      } catch (_) {}
      throw e is FileSystemException
          ? e
          : FileSystemException('copie de secours impossible', base);
    }
  }

  /// Mode 600 sur un chemin donné : les fichiers de la file portent des
  /// corps de messages en clair. Best effort : l'échec (plateforme sans
  /// chmod, ACL particulières) ne bloque jamais l'écriture, mais il est
  /// journalisé. Android n'en a pas besoin (sandbox + FBE), Windows : no-op
  /// assumé, documenté dans PRIVACY.md.
  Future<void> _hardenPermissions(File f) async {
    if (!Platform.isWindows) {
      try {
        final r = await Process.run('chmod', ['600', f.path]);
        if (r.exitCode != 0) {
          debugPrint(
            'WebhookQueue: chmod 600 impossible sur ${f.path}: ${r.stderr}',
          );
        }
      } catch (_) {}
    }
  }

  /// Instantané sur disque, Sérialisé EN CHAÎNE (audit e98bb2a8, PROBE-4) :
  /// sans barrière, deux écritures concurrentes (fin de flush vs `add`)
  /// faisaient chacune son write+fsync+rename indépendant, et le rename du
  /// snapshot LE PLUS VIEUX pouvait arriver en dernier — effaçant du fichier
  /// un ajout que la mémoire contenait encore. Ici : les écritures s'enchaînent
  /// (`_persistTail`), le contenu est ré-encodé AU MOMENT de l'exécution
  /// (jamais capturé avant la file), et la séquence monotonne sert de double
  /// garde : un ordre inversé ne peut plus passer. Le dernier état gagne.
  Future<bool> _persist() {
    _persistSeq += 1;
    final seq = _persistSeq;
    _persistTail = _persistTail.then((_) => _writeSnapshot(seq));
    return _persistTail;
  }

  /// Écrit le fichier « watermark » : le (seq, ts) du dernier instantané dont
  /// le renommage a réussi. Au démarrage suivant, un `.part` survivant plus
  /// ancien que ce repère est nécessairement déjà sur le disque (le fichier
  /// principal l'a absorbé) : son état ne peut plus écraser le plus récent
  /// (audit 3ca417b0, INFO-1 : la seule façon de comparer un `.part` au
  /// fichier principal était d'enregistrer la trace de ce dernier).
  Future<void> _writeWatermark(File queueFile, int seq, int ts) async {
    try {
      final wm = File('${queueFile.path}.wm.tmp');
      await wm.create();
      await _hardenPermissions(wm);
      await wm.writeAsString('$seq $ts', flush: true);
      await wm.rename('${queueFile.path}.wm');
    } catch (_) {
      // meilleur effort : sans repère, l'adoption redevient conservatrice
      // (elle adopte tout, comme avant ce commit) — jamais l'inverse
    }
  }

  Future<({int seq, int ts})?> _readWatermark(File queueFile) async {
    try {
      final raw = await File('${queueFile.path}.wm').readAsString();
      final parts = raw.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) return null;
      final seq = int.tryParse(parts[0]);
      final ts = int.tryParse(parts[1]);
      if (seq == null || ts == null) return null;
      return (seq: seq, ts: ts);
    } catch (_) {
      return null;
    }
  }

  /// Retourne `true` seulement si l'instantané a été écrit ET renommé avec
  /// succès. Les chemins de retour anticipé renvoient `false` : ils laissent
  /// le disque dans un état qu'on n'a PAS vérifié, et un appelant sur le
  /// point de supprimer une source de données se doit de l'apprendre
  /// (audit 3ca417b0, F1).
  Future<bool> _writeSnapshot(int seq) async {
    if (_unreadable || _lockedByPeer) return false;
    if (seq < _persistedSeq) {
      // Ne peut arriver qu'avec deux file d écritures (défensif : la chaîne
      // les sérialise déjà). Un instantané plus vieux que ce qui est déjà sur
      // le disque n a rien à y écrire. `false` : ce succès éventuel n'est pas
      // vérifié ici, et seul un renommage de CET appel autorise à supprimer
      // une source.
      return false;
    }
    File? tmp;
    try {
      final file = await _queueFile();
      // Premier réencodage d un fichier contenant des éléments invalides :
      // copie de secours des octets d'origine AVANT toute réécriture
      // (audit 6c8a1439, finding LOW). Une ligne illisible = corruption
      // externe (bit rot, fs) : on ne la « répare » pas en la supprimant,
      // et on garde la trace brute de l'état reçu.
      if (_corruptOnLoad && !_corruptBackupDone) {
        _corruptBackupDone = true;
        try {
          if (await file.exists()) {
            await _rotateBackup(file, 'corrompu');
            debugPrint(
              'WebhookQueue: copie de secours du fichier corrompu créée '
              '(rotation bornée) avant réencodage',
            );
          }
        } catch (e) {
          debugPrint(
            'WebhookQueue: copie de secours impossible: $e — les '
            'éléments invalides restent néanmoins préservés bruts',
          );
        }
      }
      // snapshot encodé ICI, sous la chaîne : c'est l'état du moment qui
      // part, pas celui capturé avant l'attente
      final ts = DateTime.now().microsecondsSinceEpoch;
      tmp = File('${file.path}.part.$seq.$ts');
      // le fichier est créé et passé en 600 AVANT l'écriture : sinon le
      // contenu est écrit dans un fichier 644 (umask), ne fût-ce que le
      // temps du write — la fenêtre suffisait à exposer les corps en clair
      // via les copies (audit ade1b6ba, finding 4 / sonde H14).
      await tmp.create();
      await _hardenPermissions(tmp);
      await tmp.writeAsString(
        jsonEncode(_items.map((i) => i.toJsonElement()).toList()),
        flush: true,
      );
      await tmp.rename(file.path);
      _persistedSeq = seq;
      await _writeWatermark(file, seq, ts);
      if (_lastPersistFailed) {
        // retour à une écriture saine : l'indicateur « sauvegarde coupée »
        // doit s'effacer, sinon le bandeau reste faux après récupération
        _lastPersistFailed = false;
        _tick();
      }
      return true;
    } catch (e) {
      // Écriture ou rename raté : rien n'est perdu — le fichier précédent
      // reste tel quel (ou absent s'il n'existait pas), la mémoire garde
      // tout, le prochain persist réessaiera. Le .part en cours, lui, ne
      // traîne pas : il porte les corps en clair (audit e98bb2a8, INFO).
      try {
        await tmp?.delete();
      } catch (_) {}
      // « rien de muet » : l échec d écriture est lui aussi compté, pas
      // seulement journalisé (audit 6c8a1439, INFO), et il rend la
      // sauvegarde officiellement coupée tant qu une écriture n a pas
      // réussi (audit ade1b6ba, sonde H13 : add disait true sans que rien
      // ne soit jamais écrit, sans aucun indicateur).
      _persistErrors++;
      if (!_lastPersistFailed) {
        _lastPersistFailed = true;
        _tick();
      }
      debugPrint(
        'WebhookQueue: écriture échouée (essayée à nouveau au '
        'prochain changement): $e',
      );
      return false;
    }
  }

  /// Met un corps d'événement en attente. Le premier réessai est déjà décalé du
  /// délai de base : inutile de retaper tout de suite un serveur qui vient de
  /// refuser.
  ///
  /// Retourne `true` si le corps est en file — en FILE, donc en mémoire :
  /// la mise sur disque peut avoir échoué dans le même appel, c'est
  /// [saveDisabled] qui le dit (compromis assumé depuis l'audit ade1b6ba,
  /// ligne clarifiée pour l'audit 3ca417b0, INFO-3). Sinon **rejet explicite
  /// et observable** : motif dans [lastRejectReason], taille dans
  /// [lastRejectBytes], compteur dans [droppedCount] — jamais d'éviction d'un
  /// élément existant pour faire de la place (audit 8960c5cc : chasser des
  /// événements non envoyés est une perte de données, y compris « en vol »).
  Future<bool> add(String rawBody) async {
    await _ensureLoaded();
    if (_lockedByPeer) {
      // le pair a peut-être rendu le verrou depuis : on retente avant de
      // refuser (chaque refus ici est un message perdu côté dispatch)
      await _refreshLock();
    }
    if (_lockedByPeer) {
      return _reject(
        utf8.encode(rawBody).length,
        'autre instance détient la file : ajout refusé (pas d écrasement '
        'croisé entre processus)',
      );
    }
    if (rawBody.isEmpty) {
      // un corps vide n'est pas un événement ; il deviendrait un poids mort
      // que les versions précédentes re-qualifiaient de corrompu (F7).
      return _reject(0, 'corps vide refusé');
    }
    if (_unreadable) {
      // F3 (audit 557ca0bb) : tant que le fichier principal est une épave,
      // AUCUNE écriture n'est possible — promettre `true` enverrait
      // l'événement en RAM sans sauvegarde, perdu au prochain redémarrage
      // sans que personne ne le sache. Un `false` compté vaut mieux qu'un
      // `true` mensonger. Seule issue : « Vider » (avec copie).
      return _reject(
        utf8.encode(rawBody).length,
        'persistance impossible : fichier de file illisible — événement '
        'refusé (les sauvegardes sont préservées ; « Vider » relance la file)',
      );
    }
    final bodyBytes = utf8.encode(rawBody).length;
    if (bodyBytes > maxQueuedItemBytes) {
      return _reject(
        bodyBytes,
        'corps de $bodyBytes octets > plafond par entrée ($maxQueuedItemBytes)',
      );
    }
    // F2 (audit 557ca0bb) : la porte d'entrée se juge sur la part ACTIVE.
    // Les suspendus et les corrompus sont des poids morts que plus aucun
    // flush ne peut drainer : les compter dans le budget rendait le rejet
    // ÉTERNEL dans le cas d'usage nominal (cible injoignable 24 h → MMS
    // suspendus → tous les événements suivants refusés, seule sortie « Vider
    // » qui détruit). Ils restent comptés, mais contre un plafond de FICHIER
    // distinct, plus élevé — et « Archiver les suspendus » (bouton) les déplace sans rien supprimer.
    if (_activeCount() >= maxItems) {
      return _reject(bodyBytes, 'file active saturée (${_activeCount()})');
    }
    if (_activeBytes() + bodyBytes > maxQueuedBytes) {
      return _reject(
        bodyBytes,
        _overBudget
            ? 'part active au budget (${_activeBytes()} octets attendent '
                  'l envoi > $maxQueuedBytes) : réessai en cours, '
                  '« Archiver les suspendus » libère le fichier'
            : 'budget d\'octets atteint (${_activeBytes()} + $bodyBytes > '
                  '$maxQueuedBytes)',
      );
    }
    if (_totalBytes() + bodyBytes > maxFileBytes ||
        _items.length >= maxFileItems) {
      return _reject(
        bodyBytes,
        'capacité totale du fichier atteinte (${_totalBytes()}/'
        '$maxFileBytes octets, ${_items.length}/$maxFileItems entrées, '
        'suspendus et corrompus inclus) : reprendre ou archiver les '
        'suspendus',
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
    pending.value = _activeCount();
    await _persist();
    if (_autoStart) start();
    return true;
  }

  /// Refus motivé et tracé : compteur pour l'UI, raison et taille pour
  /// l'appelant. Le corps lui-même n'est PAS conservé : c'étaient jusqu'à
  /// 23 MiB de SMS/MMS sensibles en clair en RAM, sans borne de durée, et
  /// aucun repli ne les lisait (audit e98bb2a8, finding LOW). La file ne
  /// bouge pas.
  bool _reject(int bodyBytes, String reason) {
    _dropped++;
    _tick();
    _lastRejectReason = reason;
    _lastRejectBytes = bodyBytes;
    WebhookService.instance.recordQueueReject(reason);
    debugPrint('WebhookQueue: $reason — événement écarté, file inchangée');
    return false;
  }

  /// Sortie de la circulation d'un événement DÉJÀ en file (TTL, plafond de
  /// tentatives) : il est SUSPENDU, pas supprimé — reste dans le fichier,
  /// ne sera plus jamais POSTé, ne disparaît que par `clear()` explicite ou
  /// `resumeSuspended()` (mandat 2026-11-05 : détruire un événement non
  /// envoyé hors livraison réussie ou demande explicite est interdit).
  void _suspend(PendingWebhook item, String reason) {
    item.suspended = true;
    WebhookService.instance.recordQueueSuspend(reason);
    debugPrint(
      'WebhookQueue: $reason — événement suspendu (conservé sur le '
      'disque, plus envoyé, vidable ou reprenable explicitement)',
    );
  }

  /// Le budget est redevenu libre (envoi réussi, clear, archivage) : la file
  /// n'est plus « sursaturée », les ajouts peuvent reprendre.
  void _markDrained() => _recomputeBudget();

  /// Entrées qui attendent réellement un envoi : ni invalides (jamais
  /// postables), ni suspendues (plus postables sans reprise explicite).
  int _activeCount() =>
      _items.where((i) => !i.isInvalid && !i.suspended).length;

  /// Octets de la part active — la seule que le flush peut drainer, donc la
  /// seule que la porte d'entrée doit respecter (audit 557ca0bb, F2).
  int _activeBytes() => _items.fold<int>(
    0,
    (n, i) => i.isInvalid || i.suspended ? n : n + i.byteLength,
  );

  /// Événements récupérés depuis des `.part` orphelins depuis ce lancement
  /// (aucun pour l'instant, aucun envoyé en double : l'union est par corps).
  int get recoveredCount => _recovered;

  /// `true` quand la persistance est coupée (fichier principal une épave que
  /// seule une reprise saine ou un « Vider » peut débloquer, ou autre
  /// instance détentrice du verrou sur desktop). L'UI doit le dire : sans
  /// écriture possible, la session n'est pas sauvegardée.
  /// `true` quand la session ne sauvegarde PAS ce qu'on lui confie :
  /// épave illisible, autre instance détentrice, ou dernière écriture en
  /// échec (audit ade1b6ba, sonde H13 — un « ajouté » silencieux sans
  /// écriture possible est une sauvegarde fantôme).
  bool get saveDisabled => _unreadable || _lockedByPeer || _lastPersistFailed;

  /// `true` quand le verrou inter-processus est indisponible sur ce stockage
  /// (NFS sans POSIX lock, quota de verrous, ouverture du `.lock` refusée) :
  /// la file fonctionne, mais la garantie « pas d'écrasement croisé entre
  /// processus » ne tient plus — l'utilisateur doit l'apprendre (audit
  /// 3ca417b0, F5). Volontairement DISTINCT de `saveDisabled` : ici
  /// l'écriture marche, c'est la protection multi-instance qui manque.
  bool get lockUnavailable => _lockUnsupported;

  /// Une ligne de l'inventaire des copies de secours.
  ({String name, int bytes}) _describeCopy(File f) =>
      (name: f.path.split(RegExp(r'[/\\]')).last, bytes: _lenSync(f));

  static int _lenSync(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Les copies de secours sont conservées SANS plafond depuis l'audit
  /// 3ca417b0 (F2) : elles portent des données uniques (épaves, états
  /// vidés, passés archivés). Leur surface disque est donc mesurée et
  /// rendue visible, et leur purge est un geste explicite. Motifs : tags de
  /// rotation `.tag.N` sur le fichier vivant et l'archive, et résidus
  /// `.tmp` d'écritures interrompues. Les `.part` en attente d'adoption et
  /// le watermark ne sont PAS des copies : jamais listés ni purgés ici.
  static final RegExp _copiesPattern = RegExp(
    r'^webhook_queue\.(?:json|archive\.json)\.(?:[a-z][a-z-]*|tmp)\.\d+$'
    r'|^webhook_queue\.(?:json|archive\.json)\.tmp$',
  );

  Future<List<({String name, int bytes})>> listCopies() async {
    final out = <({String name, int bytes})>[];
    try {
      final file = await _queueFile();
      await for (final entity in file.parent.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(RegExp(r'[/\\]')).last;
        if (!_copiesPattern.hasMatch(name)) continue;
        out.add(_describeCopy(entity));
      }
    } catch (_) {}
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Purge EXPLICITE des copies de secours (geste utilisateur confirmé) :
  /// supprime les rotations et résidus, laisse intacts le fichier vivant,
  /// l'archive vivante, les `.part` en attente et le watermark. Retourne le
  /// nombre de fichiers supprimés. Refusée si un pair détient le verrou :
  /// les rotations sont un patrimoine commun entre instances.
  Future<int> purgeCopies() => _serialized(() async {
    await _ensureLoaded();
    if (_lockedByPeer) {
      WebhookService.instance.recordQueueReject(
        'autre instance détient la file : purge des copies reportée',
      );
      return 0;
    }
    var deleted = 0;
    final entries = await listCopies();
    final file = await _queueFile();
    for (final e in entries) {
      try {
        await File('${file.parent.path}/${e.name}').delete();
        deleted++;
      } catch (_) {}
    }
    _tick();
    debugPrint(
      'WebhookQueue: purge demandée — $deleted copie(s) de secours '
      'supprimée(s) sur ${entries.length} inventoriées',
    );
    return deleted;
  });

  /// Entrées suspendues (expirées ou abandonnées) : conservées sur le disque,
  /// plus jamais POSTées, comptées dans WebhookStats.suspended.
  int get suspendedCount =>
      _items.where((i) => i.suspended && !i.isInvalid).length;

  /// Nombre d'éléments invalides préservés bruts (corruption externe).
  int get invalidCount => _items.where((i) => i.isInvalid).length;

  /// Éléments invalides rencontrés (et préservés) depuis ce lancement.
  int get corruptCount => _corrupt;

  /// Échecs d écriture depuis ce lancement (les données restent en mémoire
  /// et la dernière écriture réussie porte tout — compteur de santé, pas de
  /// perte).
  int get persistErrorCount => _persistErrors;

  /// Reprendre les envois suspendus (bouton Réglages) : la seule voie, avec
  /// `clear()`, qui sorte une entrée suspendue de son état — donc la
  /// suspension ne détruit rien et ne devient jamais une poubelle silencieuse.
  Future<int> resumeSuspended() async {
    await _ensureLoaded();
    if (_items.isEmpty) return 0;
    var resumed = 0;
    final base = AppSettings.webhookRetryBackoffS.value;
    for (final item in _items) {
      if (!item.suspended || item.isInvalid) continue;
      item.suspended = false;
      // Cycle neuf : sans ce reset, un item revenu d'un abandon serait
      // re-suspendu dès son premier nouvel échec, et un expiré le serait
      // aussitôt de nouveau.
      item.attempts = 0;
      item.createdAtMs = DateTime.now().millisecondsSinceEpoch;
      item.nextAttemptAtMs =
          DateTime.now().millisecondsSinceEpoch + retryDelayMs(base, 1);
      resumed++;
    }
    if (resumed > 0) {
      pending.value = _activeCount();
      await _persist();
      if (_autoStart) start();
    }
    return resumed;
  }

  /// File des suspendus/corrompus archivés, à côté de la file active.
  Future<File> _archiveFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/webhook_queue.archive.json');
  }

  /// Déplace suspendus et éléments corrompus dans
  /// `webhook_queue.archive.json` : ils quittent la file vivante (libère le
  /// budget qui bloquait tout ajout — audit 557ca0bb, F2) sans être
  /// supprimés : conservés sur le disque, jamais renvoyés. Retourne le
  /// nombre déplacé.
  /// Chaîne de sérialisation des gestes qui manœuvrent le patrimoine de
  /// copies (archive, purge) : deux appels concurrents sans elle calculaient
  /// tous deux la même liste « moved » avant que le premier ne la retire de
  /// mémoire, et le second archivait DEUX FOIS puis faisait sauter la
  /// rotation contenant le passé (sonde RB6 en suite complète : vert isolé,
  /// rouge sous charge — la sérialisation doit être réelle, pas chronologique).
  Future<void> _assetOpGate = Future.value();

  Future<int> _serialized(Future<int> Function() body) {
    final result = _assetOpGate.then((_) => body());
    _assetOpGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<int> archiveSuspended() => _serialized(() async {
    try {
      return await _archiveSuspendedInner();
    } catch (e) {
      // L'opérateur doit voir l'échec : sans try, l'exception E/S
      // remontait hors de la file et le geste échouait dans le silence le
      // plus total en release (audit ade1b6ba, sonde H12). Rien n'a bougé,
      // rien n'est perdu — c'est un défaut de retour, corrigé ici.
      WebhookService.instance.recordQueueReject('archive inaccessible: $e');
      debugPrint('WebhookQueue: archivage impossible (rien de déplacé): $e');
      return 0;
    }
  });

  Future<int> _archiveSuspendedInner() async {
    await _ensureLoaded();
    if (_lockedByPeer) {
      // même raison que clear() : ne pas manœuvrer les archives du pair
      WebhookService.instance.recordQueueReject(
        'autre instance détient la file : archivage reporté',
      );
      return 0;
    }
    if (_unreadable) return 0; // persistance coupée : archiver créerait des
    // doubles à la reprise du fichier épave
    final moved = _items.where((i) => i.suspended || i.isInvalid).toList();
    if (moved.isEmpty) return 0;
    final file = await _archiveFile();
    // L'archive est LA seule copie des entrées archivées aux sessions
    // précédentes (elles ont quitté la file vivante) : avant toute
    // réécriture, rotation d'une copie de l'existant, puis écriture
    // atomique tmp+rename — jamais de troncature sur place d'un fichier
    // irremplaçable (audit ade1b6ba, finding 5 / sonde H11 : la deuxième
    // archive écrasait la seule copie du passé, sans copie préalable ni
    // atomicité).
    final existing = <Object?>[];
    var existingNonEmpty = false;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          existing.addAll(decoded.cast<Object?>());
          existingNonEmpty = existing.isNotEmpty;
        } else {
          existingNonEmpty = true;
        }
      } catch (_) {
        existingNonEmpty = true; // contenu illisible : à copier tel quel
      }
      if (existingNonEmpty) {
        // l'existant (relisible ou non) est d'abord copié en rotation :
        // l'archive est la seule copie du passé, elle ne se troncature
        // jamais sans trace
        await _rotateBackup(file, 'archive');
      }
    }
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.create();
      await _hardenPermissions(tmp);
      await tmp.writeAsString(
        jsonEncode(<Object?>[
          ...existing,
          ...moved.map((i) => i.toJsonElement()),
        ]),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      // destination inaccessible (ex. un répertoire du même nom) : le
      // résidu temporaire ne doit pas traîner les corps en clair, et
      // l'erreur remonte être comptée par l'appelant
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    final movedIds = moved.toSet();
    _items.removeWhere(movedIds.contains);
    pending.value = _activeCount();
    _recomputeBudget();
    _tick();
    await _persist();
    debugPrint(
      'WebhookQueue: ${moved.length} entrée(s) suspendue(s)/corrompue(s) '
      'archivée(s) dans ${file.path} — conservées, plus envoyées',
    );
    return moved.length;
  }

  /// Recalcule le drapeau « part active hors budget » (après archive, drain,
  /// ou clear).
  void _recomputeBudget() {
    final over = _activeBytes() > maxQueuedBytes || _activeCount() > maxItems;
    if (over != _overBudget) {
      _overBudget = over;
      pending.value = _activeCount();
    }
  }

  /// Vide la file (réglages : « vider maintenant ») — la SEULE voie de
  /// destruction, encadrée : l'UI demande confirmation et cette méthode
  /// copie d'abord le fichier en sauvegarde tournante `.avant-vidage.N`
  /// (audit 557ca0bb, F5 : un tap ne doit pas être irréversible sans trace).
  Future<void> clear() async {
    await _ensureLoaded();
    if (_lockedByPeer) {
      // l'instance en retrait ne doit pas pousser les rotations « avant-
      // vidage » du fichier que le pair détient ni toucher à son état
      // (audit 3ca417b0, corollaire F5)
      debugPrint(
        'WebhookQueue: vidage ignoré — une autre instance détient la file',
      );
      return;
    }
    // copie de l'état complet AVANT destruction, suspendus et invalides
    // inclus — surtout l'épave illisible, que clear() est la seule voie
    // d'effacer : sa copie tourne, jamais sa disparition sèche.
    try {
      final file = await _queueFile();
      if (await file.exists()) {
        await _rotateBackup(file, 'avant-vidage');
      }
    } catch (_) {}
    _items.clear();
    // Un envoi en vol dont l'échec tomberait APRÈS ce clear ne réinsérera
    // pas son corps : la demande explicite de l'utilisateur prime.
    _inFlight.clear();
    _clearGeneration++;
    _overBudget = false;
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
    await _refreshLock();
    if (_lockedByPeer || _items.isEmpty) return;
    if (AppSettings.webhookWifiOnly.value &&
        !await SmsBridge.instance.isOnWifi()) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttlMs = AppSettings.webhookRetryTtlH.value * 3600 * 1000;
    final maxAttempts = AppSettings.webhookRetryAttempts.value;
    final base = AppSettings.webhookRetryBackoffS.value;
    var changed = false;
    var requeuedAtHead = 0;
    final generationAtStart = _clearGeneration;

    // Le clear est une borne stricte : si l'utilisateur a vidé la file
    // pendant l'envoi, on ne poste PAS le reste de la copie (audit e98bb2a8,
    // finding LOW : la sémantique « vide » doit être réelle).
    for (final item in List<PendingWebhook>.of(_items)) {
      if (_clearGeneration != generationAtStart) {
        debugPrint('WebhookQueue: file vidée en cours d envoi, flush stoppé');
        changed = true;
        break;
      }
      if (item.isInvalid) continue; // préservé brut, jamais POSTé
      if (item.suspended) continue; // suspendu : seul resumeSuspended/clear
      // le concerne (mandat 2026-11-05).
      if (_inFlight.contains(item)) {
        // Garde réel (audit 557ca0bb, F8) : un item déjà en cours de POST
        // ne doit jamais être reposté par une passe concurrente. Le garde
        // _flushing le couvrait déjà ; celui-ci rend la protection explicite
        // au lieu d'un commentaire affirmant une invariant non vérifiée.
        continue;
      }
      if (!force && item.nextAttemptAtMs > now) continue;
      if (now - item.createdAtMs > ttlMs) {
        // TTL dépassée : SUSPENSION, plus suppression — l'entrée reste des
        // deux côtés, comptée et visible (audit 6c8a1439, finding HIGH).
        _suspend(
          item,
          'événement expiré (TTL ${AppSettings.webhookRetryTtlH.value} h)',
        );
        changed = true;
        continue;
      }
      // En vol : l'entrée RESTE dans _items (donc dans le fichier — un crash
      // pendant l'envoi ne la perd pas) et _inFlight la signale protégée :
      // son échec ne peut la faire disparaître (audit 8960c5cc, sonde P4).
      final generationAtSend = _clearGeneration;
      _inFlight.add(item);
      final bool sent;
      try {
        sent = await _postRaw(item.rawBody);
      } finally {
        _inFlight.remove(item);
      }
      if (sent) {
        _items.remove(item);
        _markDrained();
        changed = true;
        continue;
      }
      item.attempts++;
      if (item.attempts >= maxAttempts) {
        // Plafond de tentatives : suspension, plus destruction (mandat).
        _suspend(item, 'abandon après ${item.attempts} tentatives');
        changed = true;
        continue;
      }
      item.nextAttemptAtMs = now + retryDelayMs(base, item.attempts);
      // Réinsertion en tête : le prochain FIFO le retentera en premier.
      // L'index d'insertion progresse pour que plusieurs échecs d'une même
      // passe gardent leur ordre relatif (sinon la passe inverse la file).
      // Sauf si l'utilisateur a vidé la file pendant l'envoi — un clear
      // volontaire ne doit pas être contredit par un échec tardif.
      if (generationAtSend == _clearGeneration && _items.contains(item)) {
        _items.remove(item);
        _items.insert(requeuedAtHead++, item);
      }
      changed = true;
    }
    pending.value = _activeCount();
    if (changed) {
      // Un drain par TTL/abandon peut aussi faire repasser sous le seuil :
      // les ajouts reprendront, et le drapeau doit cesser en même temps.
      _markDrained();
      await _persist();
    }
  }
}
