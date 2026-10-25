# VOX — compression vidéo native + notification persistante (design)

Date : 2026-10-25
Statut : validé en autonomie par Bastien (« fait au max de tes capacités, ne me dérange plus »)
Priorité validée par Bastien : « envoyer vite et que ça passe partout, qualité téléphone » — pas de choix de qualité dans l'UI.

## 1. Le problème, mesuré

Symptôme terrain (Bastien, 25/10) : envoi d'une vidéo vers une conversation **Matrix** →
aperçu → envoyer → notification « Compression de la vidéo... » puis **boucle infinie**,
jamais de départ d'envoi, aucun moyen d'annuler.

Causes racines (vérifiées dans le code, pas devinées) :

1. `video_compress: ^3.1.4` (pubspec.yaml:86) — version **vieillotte** de la bibliothèque,
   chemin natif MediaCodec maison sans `timeout` ni `cancel` : si l'encodeur cale, le Future
   ne se résout jamais et l'UI attend à vie.
2. Les entrées réelles sur le Pixel (MediaStore, 25/10) : `VID_20261025_183011.mp4`
   **314 Mo** / 1080p / 80 s (débit ~31 Mbps, OpenCamera), `VID_20261025_182741.mp4`
   104 Mo, `VID_20261020_110813.mp4` **82 Mo en 4K** / 18 s. Ré-encoder ça avec la
   bibliothèque par défaut (`Quality.baseline_60_fps` ≈ 480p) = des minutes, sans
   progression, sans échappatoire.
3. `deleteOrigin: true` (lib/utils/resize_video.dart) — supprime le fichier d'origine
   après compression : dans le chemin galerie c'est une copie cache (donc pas la photo de
   la galerie), mais dans le chemin « partagé vers VOX » c'est le fichier réellement
   fourni par l'autre app. Dans tous les cas, supprimer un fichier en chemin d'envoi
   est une mauvaise idée → retiré.
4. Le bug « width/height inversés sur Android » (contourné par une inversion manuelle
   dans `resize_video.dart`, cf. commit amont `3d0a3ee22`) n'existe pas côté Media3 : la
   rotation est un metadata propre.
5. Aucun retour visuel : `showLoadingSnackBar` (send_file_dialog.dart:84-86) est un
   spinner infini ; pendant ce temps la fenêtre d'aperçu est fermée — l'utilisateur ne
   voit plus sa vidéo (« je ne vois pas la vidéo »).

## 2. Décision d'architecture

**Remplacer `video_compress` par Media3 Transformer** (`androidx.media3:media3-transformer:1.11.1`,
stable du 09/2026) : l'encodeur natif d'Android (celui de « Compresser » dans Google Photos),
API `ProgressHolder` pour la progression %, `Transformer.stop()` pour l'annulation, callbacks
`onCompleted`/`onError` fiables.

C'est un module **natif Kotlin** dans `android/app/src/main/kotlin/chat/fluffy/fluffychat/video/`,
sur le même modèle maison que `VoipBridge`/`SmsBridgePlugin` : MethodChannel
`eu.devlabz.vox/video` + EventChannel `eu.devlabz.vox/video_events`.
**Ma décision** : pas de paquet pub.dev (les paquets Media3 Flutter publis sont tiers et
non maintenus ; le pont natif est le pattern déjà établi dans VOX).

- Compression **hors-process Dart mais dans le process de l'app** (pas de service
  détaché) : l'envoi Matrix se fait de toute façon dans le même process, donc survivre
  à un kill de l'app n'apporte rien. Notification persistante pendant le job ; si l'app
  meurt, la notification meurt avec elle et l'envoi de toute façon avec. **Ma décision.**
- `video_compress` est **retiré de pubspec.yaml** et tous ses usages migrés
  (`resize_video.dart`, miniatures vidéo) — pas de code mort à deux encodeurs.

## 3. Le profil de compression (par défaut, non exposé)

Validé par Bastien : vitesse + compatibilité, qualité « téléphone », pas de menu.

- Conteneur : MP4, H.264 High profile + AAC (compatible partout, y compris MMS futurs).
- Résolution : bornée à **1920×1080** (échelle proportionnelle ; la rotation est portée
  par les metadata MP4, Media3 les reproduit à la sortie — vérification terrain §8.3).
- Bitrate vidéo : **3,5 Mbps** (≈ la sortie de Google Messages sur ce type de clip) ;
  audio AAC **128 kbps**.
- **Passe-plat** : si la vidéo est déjà ≤ 25 Mo ET ≤ 1920 px de côté max ET codec
  H.264/AAC → aucune ré-encodation, envoi direct (avec validation par `MediaExtractor`
  des codecs, `MediaMetadataRetriever` pour les dimensions).
- Le fichier Matrix event (width/height/duration) est lu sur le fichier **résultant**
  (médadatas fiables côté Media3) — supprime le contournement « inversé sur Android ».
- Seuil existant conservé : `compress=false` (interrupteur de la boîte d'envoi) = pas de
  ré-encodage, upload tel quel (plafond `mUploadSize` déjà géré).

## 4. UX — notification persistante + chemin dans l'app

Côté notif (natif, modèle `VoipBridge.showCallNotification`) :

- Canal `video_compression`, IMPORTANCE_LOW, silencieuse, groupe single. Icône :
  `notifications_icon` (le V blanc 24 dp — jamais le vector monochrome, cf. piège notifs
  SMS).
- Contenu : « Compression vidéo — <nom> », style `setProgress(max, p, false)`,
  texte d'état : « En file » → « Compression 0–100 % » → terminée.
- Action **« Annuler »** → `ACTION_CANCEL` → `Transformer.stop()` → événement Dart
  `cancelled`.
- À la fin : succès → la notif affiche « Prête » et disparaît ~4 s plus tard (l'envoi
  démarre dans la foulée) ; annulation → silencieuse ; erreur → « Échec », action
  « Voir » qui rouvre la conversation, reste affichée jusqu'à lecture.

Côté app (Matrix `send_file_dialog`) :

- À la place du spinner infini : la boîte se ferme (comportement actuel conservé),
  la progression est reprise dans la **conversation** sur la pastille d'envoi optimiste
  (on garde `showLoadingSnackBar` mais avec le pourcentage si l'app est au premier
  plan ; la notification couvre l'arrière-plan).
- **Garde de sécurité** : timeout global de **5 min** par job (ticker Dart, la
  progression native réarme) → échec propre plutôt que boucle infinie. message d'erreur
  dans une snackbar avec bouton Réessayer.
- La miniature d'event est générée nativement (`MediaMetadataRetriever`, 720 px, JPEG
  q80) **depuis le fichier source ou compressé** — remplace `getByteThumbnail`.
- Nettoyage : fichiers temporaires d'un job supprimés **après upload réussi** (et aux
  démarrages suivants pour les orphelins) ; plus jamais `deleteOrigin`.

## 5. Fichiers touchés

- `pubspec.yaml` / `pubspec.lock` : −`video_compress`.
- `lib/utils/resize_video.dart` : réécriture du chemin vidéo (pont natif, plus de
  contournement inversé).
- `lib/pages/chat/send_file_dialog.dart` : progression + timeout + retry.
- `lib/utils/video/video_bridge.dart` (**nouveau**) : wrapper Dart du MethodChannel,
  modèle `lib/utils/sms/sms_bridge.dart` (singletons, events, stream).
- `android/.../video/VideoCompressorBridge.kt` + `VideoCompressorPlugin.kt` (**nouveaux**) :
  Media3 Transformer, file d'attente (les envois multiples `widget.files` multiples
  existent), notification, `list` des jobs pour reprise après relance.
- `AndroidManifest.xml` : rien de neuf — `POST_NOTIFICATIONS` déjà déclaré (ligne 33),
  pas de service détaché donc pas de permission FGS supplémentaire.
- `android/app/build.gradle.kts` : + `androidx.media3:media3-transformer:1.11.1`
  (et transitifs `media3-common`).
- L10n : nouvelles chaînes FR (`compressingVideoProgress(p)`, `videoCompressionFailed`,
  `cancel` existe déjà) — générées via `flutter gen-l10n`.

## 6. Tests

- Dart : `test/video/video_bridge_test.dart` (fake MethodChannel : file, progression,
  annulation, timeout 5 min, retry).
- Dart : `resize_video` sur les cas passe-plat / compressé / échec (mock du pont).
- Kotlin : mapping profil (résolution/bitrate selon entrée) si testable sans Robolectric
  ; sinon couvert par le terrain.
- **Terrain (Bastien + moi via adb 10.8.0.30:41441)** : les 3 vraies vidéos du jour
  (314 Mo, 104 Mo, 4K 82 Mo) → mesurer le temps de compression sur le Pixel 10 Pro XL
  (< 60 s attendu), vérifier la notif vivante, l'annulation, et la réception Matrix.
  Budget : une session de démo.

## 7. Non-objectifs

- Pas de RCS, pas de MMS vidéo (le MMS natif reste photo ; le module sera réutilisable
  plus tard), pas de choix de qualité UI, pas de reprise après kill de l'app, pas de
  transcodage AV1/HEVC→H.264 pour l'entrée (le Pixel filme en H.264/HEVC — l'HEVC
  d'entrée est supporté par Media3, on le ré-encode en H.264 de sortie).

## 8. Hypothèses à vérifier au build (mes paris assumés)

1. Media3 1.11.1 compile avec AGP 8.11.1/Kotlin 2.2.20/Flutter 3.47.5 — a priori oui
   (Jetpack standard), mais les checks de plancher de version Flutter sont séquentiels
   (cf. piège des bumps AGP/Kotlin du 06/10), premier build = juge.
2. La boîte d'aperçu Matrix passe par `send_file_dialog` pour les vidéos (lu : oui,
   `getVideoInfo` n'est appelé que depuis là + `share_scaffold_dialog` ; les deux migrés).
3. Dimensions de sortie : `MediaMetadataRetriever` sur le fichier compressé
   (`METADATA_KEY_VIDEO_WIDTH`/`HEIGHT` + `METADATA_KEY_VIDEO_ROTATION`) — la règle est
   la même que l'affichage : rotation 90/270 ⇒ largeur et hauteur échangées. Auparavant
   c'était la boîte noire de `video_compress` qui les devinait (et les inversait).
