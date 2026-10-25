# Compression vidéo native (Media3) + notification persistante — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer `video_compress` (qui boucle à vie sur les grosses vidéos) par un module natif Media3 Transformer avec progression %, annulation et notification persistante, et l'intégrer au chemin d'envoi Matrix de VOX.

**Architecture:** Pont natif Kotlin sur le modèle VOX existant (`SmsBridgePlugin`) : MethodChannel `eu.devlabz.vox/video` + EventChannel `eu.devlabz.vox/video_events`. Dart attend la fin via les events, avec timeout de sécurité de 5 min. La notification est gérée côté Kotlin (une seule, mise à jour à chaque tick).

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4, Kotlin 2.2.20, `androidx.media3:media3-transformer:1.11.1`, tests Dart `flutter_test` + `TestDefaultBinaryMessengerBinding`.

**Spec:** `docs/superpowers/specs/2026-10-25-vox-video-compression-design.md`

**Travail sur edge-01** : repo `~/Bureau/dev/Applications/fluffychat`, branche `main`. `flutter` = `/usr/bin/flutter`.

## Global Constraints

- Ne JAMAIS `git push` (9 commits + ceux d'attente déjà non poussés, feu vert jamais donné).
- Ne pas toucher au chemin SMS/MMS existant (`sendMms` images seulement) ni au legacy VoIP.
- Chaîne FR exacte de la notif : « Compression vidéo » ; l'original de la galerie n'est JAMAIS supprimé.
- Tous les fichiers temporaires de compression vivent dans le cache de l'app (`context.cacheDir/video/`).
- `video_compress` doit disparaître de `pubspec.yaml` À LA FIN du plan (task 3), jamais avant (le code Dart en dépend jusqu'à là).
- Vérification à chaque task : `flutter analyze` sans warning NOUVEAU + `flutter test` vert (avant tâche build : `cd android && ./gradlew :app:compileReleaseKotlin`).

## Review Focus

1. **Vidéo 4K portrait avec rotation 90/270** (typique OpenCamera/Camera) → le Matrix event doit porter les dimensions AVEC rotation appliquée (écran vertical = width < height) et la sortie doit garder l'orientation ; attendu : le destinataire voit la vidéo droite.
2. **Vidéo déjà conforme** (≤ 25 Mo, ≤ 1920 px, H.264/AAC) → passe-plat sans ré-encodage, envoi du fichier original sans le supprimer ; attendu : instantané, aucun fichier temporaire.
3. **Annulation pendant la compression, app en arrière-plan** (action « Annuler » de la notif) → Dart reçoit `cancelled`, rien n'est envoyé, la notif disparaît, le fichier partiel est supprimé.
4. **Fichier illisible / sans piste vidéo / encoder qui refuse le format** → `error` propre dans les secondes qui suivent, snackbar avec Réessayer, jamais la boucle infinie actuelle.
5. **Chemin `content://` ou fichier partagé par une autre app** → copié dans le cache avant Transformer ; si copie impossible → `error` code `unreadable`, pas de crash natif.

---

### Task 1: Pont Dart `VideoBridge`

**Files:**
- Create: `lib/utils/video/video_bridge.dart`
- Create: `test/video/video_bridge_test.dart`

**Interfaces:**
- Consumes : rien (couche la plus basse).
- Produces (utilisé par les tasks 2-4) :
  - `VideoBridge.instance` (singleton, modèle `SmsBridge`)
  - `Future<VideoJob?> VideoBridge.start(String path, {required bool compress})` — `null` si le natif refuse (MissingPluginException/erreur) ; retourne immédiatement `{jobId}`.
  - `Future<VideoJobResult> VideoBridge.waitFor(String jobId)` — résolu par l'event `done` (`VideoJobResult.ok`), rejeté en `VideoCompressionException` sur `error`/`cancelled`/timeout.
  - `Stream<VideoProgress> VideoBridge.progress` — `{jobId, percent}` (0-100).
  - `Future<void> VideoBridge.cancel(String jobId)`
  - `Future<VideoMeta?> VideoBridge.meta(String path)` — `{width, height, durationMs, sizeBytes}` (dimensions déjà rotation-appliquées, voir Review Focus 1).
  - `Future<Uint8List?> VideoBridge.thumbnail(String path, {int maxSize = 720})`
  - `Future<void> VideoBridge.disposeResult(String jobId)` — supprime le fichier temporaire du job (JAMAIS si l'event `done` portait `passthrough: true`).
  - `class VideoCompressionException implements Exception { final String code; final String message; }` avec codes `encoder|unreadable|timeout|cancelled`.
  - `Future<VideoJobResult?> VideoBridge.resultFor(String jobId)` — résultat mémorisé du `done` (permet à l'appelant de récupérer `outputPath`/`passthrough`/dims après coup) ; `disposeResult` s'appuie dessus.
  - Événements natifs attendus (map) : `{kind: 'progress'|'done'|'error'|'cancelled', jobId, percent?, outputPath?, width?, height?, durationMs?, sizeBytes?, code?, message?}` — `done` porte en plus `passthrough` (bool). NOTE : `done` peut arriver AVANT la réponse de `start` (passe-plat résolu avant l'inscription du listener) → le pont doit mettre en cache les events par jobId et les avaler quand `start` revient avec ce jobId (file d'attente tampon, test dédiée en step 1).

- [ ] **Step 1: Écrire les tests échouants** `test/video/video_bridge_test.dart`. Cas à couvrir (messager mock via `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` sur `MethodChannel('eu.devlabz.vox/video')` + `setMockStreamHandler` sur l'EventChannel) :
  - `start` renvoie le jobId fourni par le mock ; `waitFor` se résout quand l'event `done` arrive (outputPath/width/height/durationMs transmis).
  - event `error` → `waitFor` rejette `VideoCompressionException(code: 'encoder')`.
  - event `cancelled` → rejette avec `code: 'cancelled'`.
  - `disposeResult` appelle la méthode native `cleanup` avec `outputPath`, et NE l'appelle PAS quand `passthrough` est vrai (tester avec un flag interne au job).
  - timeout : sans AUCUN event pendant 5 min (injecter `Duration timeout` param default 5 min pour tester à 50 ms) → rejette `code: 'timeout'` et appelle natif `cancel`.
  - le timeout est RÉARMÉ par chaque event progress (un progress à t+2×timeout/3 puis silence → timeout complet depuis le dernier event).

- [ ] **Step 2: Lancer, vérifier l'échec** — `flutter test test/video/video_bridge_test.dart` → échec « video_bridge.dart not found ».

- [ ] **Step 3: Implémenter `lib/utils/video/video_bridge.dart`** — classes `VideoJob{jobId}`, `VideoProgress{jobId, percent}`, `VideoJobResult{jobId, outputPath, width, height, durationMs, sizeBytes, passthrough}`, `VideoMeta{width, height, durationMs, sizeBytes}`. Un `Map<String, Completer<VideoJobResult>> _pending`, un `StreamController<VideoProgress>.broadcast()`, un `Timer` par job remé à chaque event du job ; `Duration timeout = const Duration(minutes: 5)` passé en champ modifiable (les tests le raccourcissent). Parsing défensif comme `SmsBridge` (try/cast, jamais throw sur event malformé — journal `debugPrint`).

- [ ] **Step 4: `flutter test test/video/video_bridge_test.dart` → tout vert** ; `flutter analyze lib/utils/video test/video` propre.

- [ ] **Step 5: Commit** — `git add lib/utils/video test/video && git commit -m "feat(video): pont Dart du compresseur video natif"`

---

### Task 2: Module natif Media3 + notification

**Files:**
- Modify: `android/app/build.gradle.kts` (dependencies)
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/video/VideoCompressorBridge.kt`
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/video/VideoCompressorPlugin.kt`
- Modify: `android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt` (`configureFlutterEngine`, ~ligne 36)

**Interfaces:**
- Consumes : contrat d'events défini task 1 (mêmes chaînes de méthodes/canaux).
- Produces : méthodes natives `start{path,compress}`, `cancel{jobId}`, `meta{path}` → `{width,height,durationMs,sizeBytes}`, `thumbnail{path,maxSize}` → `ByteArray`, `cleanup{paths:List<String>}` ; notification `video_compression` ; nettoyage des orphelins à l'enregistrement.

- [ ] **Step 1: Dépendance Gradle** — dans `android/app/build.gradle.kts`, `dependencies { implementation("androidx.media3:media3-transformer:1.11.1") }` (tire `media3-common`/`media3-container`/`media3-effect`/`media3-extractor` en transitif).

- [ ] **Step 2: `VideoCompressorBridge.kt`** — objet interne avec :
  - file d'attente FIFO sur un `HandlerThread` unique (un Transformer à la fois) ;
  - `start(path, compress)` : `compress` est TOUJOURS `true` côté Dart (le cas `compress=false` n'appelle pas `start`, il passe par `meta` + bytes bruts — cf. task 3) ; résoudre `content://` → copie cache (`openInputStream`, échec → event `error unreadable`) ; test passe-plat (taille ≤ 25 Mo ET côté max ≤ 1920 ET piste vidéo `video/avc` ET piste audio `audio/mp4a-latm` via `MediaExtractor`) → si OK, event `done` avec `passthrough=true` et le chemin d'origine (résolution SYNCHRONE possible dans `start` : l'event peut précéder la réponse, le pont Dart tamponne — cf. task 1) ; sinon job Transformer ;
  - profil : `CompressionPlan.forSource(width, height)` (objet pur, pas d'Android) → `androidx.media3.effect.Scale` ratio entier réduisant le côté max à ≤ 1920 (déjà ≤ → `Scale.ONE`) ; `VideoEncodingOptions` bitrate 3 500 000 ; `AudioEncodingOptions` bitrate 128 000 ; sortie `context.cacheDir/video/<jobId>.mp4` ;
  - progression : `ProgressHolder` pollé toutes les 500 ms pendant `transformer.start()` (bloquant sur le thread du job) → event `progress` + notif ; fin → event `done` avec `outputPath` et les dims du fichier SORTI (`MediaMetadataRetriever` `METADATA_KEY_VIDEO_WIDTH`/`HEIGHT`/`ROTATION`, échange si rotation 90/270 — Review Focus 1) ; `onError` → event `error` code `encoder` ;
  - `cancel(jobId)` : `transformer.stop()`, suppression fichier partiel, event `cancelled` ;
  - `meta(path)` / `thumbnail(path)` : `MediaMetadataRetriever`, image à l'échelle pour ≤ `maxSize` px, JPEG qualité 80 ; dimensions rotation-appliquées ;
  - `cleanup(paths)` : ne supprime QUE les fichiers sous `cacheDir/video/` (garde absolute-path, cf. guard path-traversal de `MmsPduProvider`) ;
  - à l'init : supprimer les fichiers de `cacheDir/video/` de plus de 24 h (orphelins).
- [ ] **Step 3: Notification** — canal `video_compression` IMPORTANCE_LOW, icône `R.drawable.notifications_icon` (le V blanc 24 dp, JAMAIS le monochrome vector — piège connu), `setOngoing(true)`, `setProgress(100, percent, false)`, titre « Compression vidéo », sous-titre = nom de fichier, action « Annuler » → `BroadcastReceiver` local → `cancel(jobId)`. Succès : « Prête » + `cancel()` après 4 s ; erreur : « Échec de la compression », pas ongoing, reste ; annulation : retirée immédiatement.
- [ ] **Step 4: `VideoCompressorPlugin.kt`** — `register(context, engine)` (copier la structure de `SmsBridgePlugin.register`) : MethodChannel `eu.devlabz.vox/video` dispatchant les 5 méthodes, EventChannel `eu.devlabz.vox/video_events`. Enregistrer le receiver de notification.
- [ ] **Step 5: `MainActivity.configureFlutterEngine`** — ajouter `VideoCompressorPlugin.register(applicationContext, flutterEngine)`.
- [ ] **Step 6: Compiler** — `cd android && ./gradlew :app:compileReleaseKotlin` → SUCCESS (attention : si erreur de plancher AGP/Kotlin, cf. piège toolchain 06/10 avant de chercher dans le code).
- [ ] **Step 7: Commit** — `git add android && git commit -m "feat(video): compressleur video natif Media3 + notification de progression"`

---

### Task 3: Migration de `resize_video.dart`, retrait de `video_compress`

**Files:**
- Modify: `lib/utils/resize_video.dart` (réécriture complète)
- Modify: `pubspec.yaml` (retirer la ligne 86 `video_compress: ^3.1.4`) + `pubspec.lock` via `flutter pub get`
- Create: `test/video/resize_video_test.dart`

**Interfaces:**
- Consumes : `VideoBridge` (task 1).
- Produces : mêmes signatures publiques qu'avant — `Future<MatrixVideoFile> XFile.getVideoInfo({bool compress = true})` et `Future<MatrixImageFile?> XFile.getVideoThumbnail()` — seuls leurs appels internes changent.

- [ ] **Step 1: Tests échouants** `test/video/resize_video_test.dart` (mock du channel comme task 1) : `getVideoInfo(compress:true)` → `start`+`waitFor` → renvoie `MatrixVideoFile` avec bytes du fichier compressé (écrire un faux fichier temp), width/height/duration repris du `done` SANS inversion (supprimer le contournement `PlatformInfos.isAndroid` et le commentaire de l'issue 172) ; `passthrough` → bytes = fichier d'origine ; `getVideoInfo(compress:false)` → passe par `meta` + bytes bruts, jamais `start` ; `getVideoThumbnail` → bytes de `thumbnail`.
- [ ] **Step 2: Vérifier l'échec** — `flutter test test/video/resize_video_test.dart` FAIL (imports video_compress encore là).
- [ ] **Step 3: Réécrire `resize_video.dart`** contre le pont ; `deleteOrigin` disparaît (le cleanup est à la charge de l'appelant, task 4) ; supprimer `import 'package:video_compress/video_compress.dart';`.
- [ ] **Step 4: `flutter pub get` puis retirer la dépendance ; `grep -rn video_compress lib/ pubspec.yaml` → 0 résultat (hors l10n générés qui n'ont pas le mot).**
- [ ] **Step 5: `flutter test test/video/ && flutter analyze` verts** — commit `git add -A lib pubspec.yaml pubspec.lock test/video && git commit -m "refactor(video): resize_video sur le pont natif, video_compress retire"`

---

### Task 4: send_file_dialog — progression, retry, cleanup + l10n

**Files:**
- Modify: `lib/l10n/intl_en.arb` et `lib/l10n/intl_fr.arb` (nouvelles clés)
- Modify: `lib/pages/chat/send_file_dialog.dart:60-160` (`_sendFile`)
- Create: `test/pages/send_file_dialog_progress_test.dart` si une extraction testable est nécessaire ; sinon test bridge existants suffisants (décision à l'exécution, préférer ne pas sur-tester l'UI).

**Interfaces:**
- Consumes : `VideoBridge` (task 1), `getVideoInfo` migré (task 3).
- Produces : clés l10n `compressingVideoPercent(percent)` (en : "Compressing video… $percent%", fr : « Compression vidéo… $percent% »), `videoCompressionFailed` (fr : « Échec de la compression vidéo »), `retry` existe déjà ? vérifier, sinon `retrySend` (fr : « Réessayer »).

- [ ] **Step 1: ARB** — ajouter les clés dans `intl_en.arb` (à côté de `compressVideo` ligne 2540) et `intl_fr.arb` ; `flutter gen-l10n` (ou `flutter pub get`) pour régénérer.
- [ ] **Step 2: `_sendFile`** — pour les vidéos : au lieu de `showLoadingSnackBar(compressVideo)` fixe, écouter `VideoBridge.instance.progress` et rappeler `showLoadingSnackBar(l10n.compressingVideoPercent(percent))` à chaque tick ; wrap `getVideoInfo` dans un try/catch `VideoCompressionException` → `showSnackBar` avec `videoCompressionFailed` + action Réessayer qui relance `_sendFile()` ; `code: 'cancelled'` → snackbar neutre discrète, pas de Réessayer. Après `sendFileEvent` réussi : `await VideoBridge.instance.disposeResult(jobId)` (jobId stocké par `getVideoInfo` dans `VideoBridge.lastCompressJobId`, simple champ — pas de hack dans les classes du SDK).
- [ ] **Step 3: `flutter analyze && flutter test` verts ; build debug compile** : `flutter build apk --debug` (le release est pour task 5, plus lent).
- [ ] **Step 4: Commit** — `git add lib test && git commit -m "feat(video): progression de compression dans la boite d envoi + retry"`

---

### Task 5: Build release + terrain sur les vraies vidéos

**Files:** aucune (vérification).

- [ ] **Step 1: `flutter build apk --release`** (~3 min) ; noter le sha256.
- [ ] **Step 2: Transférer et installer** : `scp` edge-01 → `/tmp/opencode/vox/` (~35 s), contrôler le sha256 des deux côtés, `adb connect 10.8.0.30:<port>` (revérifier via `adb mdns services` — 41441 ce jour) puis `adb install -r -d`.
- [ ] **Step 3: État permissions post-install** : `adb shell am get-standby-bucket eu.devlabz.vox` (=5) et `dumpsys deviceidle whitelist` (comme à l'accoutumée après `-r`).
- [ ] **Step 4: Capture logcat** `adb logcat -G 16M && adb logcat -v time > /tmp/opencode/vox/cap-video.log` en arrière-plan.
- [ ] **Step 5: Terrain guidé (Bastien ou nous via UI)** sur les 3 fichiers du MediaStore : `VID_20261025_183011.mp4` (314 Mo), `VID_20261025_182741.mp4` (104 Mo), `VID_20261020_110813.mp4` (4K 82 Mo). Attendu : notif qui avance, compression < 60 s chacune, message reçu dans la conversation Matrix, plus de boucle infinie. Test annulation : relancer sur la 314 Mo, « Annuler » à ~30 % → rien n'est envoyé, plus de notif. Test passe-plat : envoyer `video_90707202.mp4` (11 Mo déjà conforme) → instantané.
- [ ] **Step 6: Lire le log** (`grep -E "VideoBridge|Media3|Transformer"`), vérifier zéro crash ; demander le verdict visuel à Bastien (l'appareil photo de la galerie n'a pas à avoir bougé, la vidéo reçue doit être droite).
- [ ] **Step 7: Fiche mémoire** — mettre à jour `project_vox.md` (suppression de la mention video_compress si présente, section compression vidéo + point de reprise) ; NE PAS pousser sur gitea sans feu vert.
