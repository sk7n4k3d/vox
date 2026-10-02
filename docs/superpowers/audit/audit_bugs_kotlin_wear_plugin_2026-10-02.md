# Audit bugs — complément : Wear OS, OtpExtractor, pont Flutter↔natif, manifest/gradle, couche Dart

- **Date** : 2026-10-02
- **Périmètre** : uniquement ce qui **n'est PAS** dans
  `docs/superpowers/audit/audit_bugs_kotlin_2026-10-02.md` (rapport Kotlin SMS/MMS « top 10 »).
- **Fichiers lus intégralement** :
  - `android/app/src/main/kotlin/chat/fluffy/fluffychat/wear/**` (WearBridge, WearBridgeService, WearBridgePlugin)
  - `android/wear/**` (module Wear OS complet : bridge, voice, notif, ui, data, manifest, gradle, proguard)
  - `android/app/src/main/kotlin/chat/fluffy/fluffychat/sms/OtpExtractor.kt`,
    `SmsBridgePlugin.kt`, `SmsNotifier.kt`, `SmsReplyReceiver.kt`, `SmsDeliverReceiver.kt`,
    `MainActivity.kt`, extraits `SmsBridge.kt`
  - `android/app/src/main/AndroidManifest.xml`, `android/app/build.gradle.kts`,
    `android/app/proguard-rules.pro`, `android/build.gradle.kts`, `android/settings.gradle.kts`,
    `android/gradle.properties`, `res/xml/*`
  - `lib/utils/sms/sms_bridge.dart`, `lib/utils/wear_bridge.dart`
- **Branche** : `feature/ux-refonte` (lecture seule — aucun fichier de code modifié)
- **Méthode** : lecture intégrale fichier par fichier, reconstruction des flux watch↔phone,
  vérification des contraintes Android 14/15 (FGS types, background start, DataLayer) et
  de la sémantique Flutter (MethodChannel/EventChannel, encodage).

> Rappel : le rapport initial couvre déjà goAsync manquant, stopSelf prématuré, OUTBOX/FAILED,
> pagination par date, date MMS, isAccepted, HashMap SmsNotifier, double onDone, MmsNetworkManager,
> uuid watch non validé, MmsPduProvider, code mort MmsSentReceiver, channel sound figé,
> pendingSmsIntent, SUBSCRIPTION_ID, runCatching muet, regroupement SMS, bind process-wide,
> isTrustedNode bloquant, ackVoice URI incomplète, SQLite vars, PDU non supprimé, etc.
> Ces points ne sont **pas** répétés ici.

---

## Synthèse — top 10 des points NOUVEAUX

| # | Gravité | Sujet | Fichier |
|---|---------|-------|---------|
| N1 | 🔒 sécurité | OTP affiché en clair dans l'action de notif même quand l'aperçu est désactivé | `sms/SmsNotifier.kt:174,210-212` |
| N2 | 🔒/🗑️ | Bridge watch sans vérif d'émetteur : n'importe quel node peut forger un ack → audio supprimé | `wear/.../bridge/WearListenerService.kt:92-116` |
| N3 | 🗑️ data-loss | Enregistrement arrivé à 120 s supprimé (double `stop()` MediaRecorder) | `wear/.../voice/VoiceRecorder.kt:73-88`, `VoiceRecordingService.kt:171-186` |
| N4 | 🗑️ data-loss | Callback Flutter périmé → vocal **jamais** persisté sur disque quand l'engine est détaché | `wear/WearBridgePlugin.kt:31-44`, `WearBridge.kt:177-183` |
| N5 | 💥 crash | FGS `dataSync` démarré depuis `BOOT_COMPLETED` interdit sous Android 15 / targetSdk 36 | `wear/.../bridge/BootReceiver.kt:15-21`, `wear/build.gradle.kts:19` |
| N6 | 💥 crash (risque) | FGS `microphone` démarré depuis une action de notification (arrière-plan) sous Android 14+ | `wear/.../notif/NotificationActionReceiver.kt:26-34`, `VoiceRecordingService.kt:223-227` |
| N7 | ⚠️ UX/fuite | DataItem d'ack vocal jamais lu par la watch (fallback mort) et jamais purgé | `wear/WearBridge.kt:303-314`, `wear/.../WearListenerService.kt:92-116`, manifest watch |
| N8 | 🔒 vie privée | Payload rooms/messages poussé **en clair** sur le DataLayer partagé (noms, previews, thumbs) | `wear/WearBridge.kt:63-78,124-138` ; watch `data/RoomsRepository.kt:62-71` |
| N9 | ⚠️ crash/UX | Désérialisation Dart non défensive + `MissingPluginException` non attrapée + erreurs avalées | `lib/utils/sms/sms_bridge.dart:94-96,155-166,358,362,393-399` |
| N10 | ⚠️ ressource | `DataItemBuffer` jamais `release()` dans les `readCurrent` de la watch (et chemin d'erreur) | `wear/.../data/RoomsRepository.kt:62-71`, `RoomMessagesRepository.kt:55-65` |

**Findings secondaires** (hors top 10, section « Secondaires ») : OTP = premier nombre trouvé (pas
forcément le code) ; dialogue d'échec vocal global périmé ; drain concurrent des vocaux ;
re-enqueue d'orphelins dupliqué ; `setMaxDuration`/OPUS sur API < 29 ; `shrinkResources` sans keep
des ressources dynamiques ; `voiceReplyAction`/`WearBridge` divers.

---

## N1 — 🔒 L'OTP est affiché en clair malgré les aperçus désactivés

**Fichiers** : `android/app/src/main/kotlin/chat/fluffy/fluffychat/sms/SmsNotifier.kt:174` (extraction),
`:210-212` (action ajoutée), `:118` (calcul de `showPreview`), `:339` (libellé « Copier $code »).

```kotlin
val showPreview = prefBool(context, KEY_PREVIEW, true) && !locked
val shownBody = if (showPreview) body else "Nouveau message"
...
val otpCode = if (locked) null else OtpExtractor.extract(body)   // l.174
...
if (otpCode != null) addAction(buildCopyOtpAction(context, threadId, otpCode)) // l.210-212
...
NotificationCompat.Action.Builder(..., "Copier $code", pi)        // l.339
```

**Cause** : `otpCode` ne consulte que `locked`, pas `showPreview`. Si l'utilisateur a coupé les
aperçus (`chat.fluffy.sms_notifications_preview=false`) sans verrouiller la conversation, le corps
est masqué mais le code OTP est **quand même extrait et rendu dans le libellé du bouton**
(« Copier 123456 »), visible sur l'écran verrouillé et par tout NotificationListener.

**Correctif** : lier l'OTP à l'autorisation d'aperçu :
`val otpCode = if (locked || !showPreview) null else OtpExtractor.extract(body)`.
Ne jamais sérialiser le code dans un libellé/extra de PendingIntent immutable visible.

---

## N2 — 🔒/🗑️ Bridge watch : aucune vérification de l'émetteur

**Fichier** : `android/wear/src/main/kotlin/chat/fluffy/fluffychat/bastien_fork/wear/bridge/WearListenerService.kt:92-116`
(et `:71-90` pour `onDataChanged`).

```kotlin
override fun onMessageReceived(messageEvent: MessageEvent) {
    val path = messageEvent.path
    when {
        path == PATH_ROOMS_PING -> { RoomsRepository.pingFlow.tryEmit(Unit); notifyFromCurrentRooms() }
        path.startsWith(PATH_VOICE_ACK_PREFIX) -> {
            val uuid = path.removePrefix("$PATH_VOICE_ACK_PREFIX/")
            if (uuid.isNotEmpty()) VoiceUploader.notifyAck(uuid, success = true)   // l.106
        }
        path.startsWith(PATH_VOICE_NACK_PREFIX) -> VoiceUploader.notifyAck(uuid, false)
    }
}
```

**Cause** : contrairement au service côté **phone** (`WearBridgeService.isTrustedNode`,
déjà audité), le service côté **watch** ne vérifie ni `messageEvent.sourceNodeId` ni le host du
DataItem. Le service est `exported="true"` (requis GMS) : n'importe quelle app/node connecté peut
envoyer un message `/wear/voice/ack/<uuid>` valide, ce qui complète le `CompletableDeferred` avec
`success=true`. `VoiceUploader.upload` conclut alors `UploadState.Success` et **supprime le fichier
audio** (`VoiceUploader.kt:127-132`) pour un vocal qui n'a jamais été posté sur Matrix.
Un message `/wear/rooms/ping` forgé force en plus un readCurrent/dispatch arbitraire.

**Correctif** : implémenter un `isTrustedNode(sourceNodeId)` côté watch (même fail-closed que le
phone) sur **les deux** entrées (`onMessageReceived`, `onDataChanged`), ou signer les acks
(HMAC avec un secret partagé établi à l'appairage). A minima, n'accepter un ack que si un upload
est réellement en attente **et** si l'émetteur est le phone connu.

---

## N3 — 🗑️ L'enregistrement à durée maximale est supprimé

**Fichiers** : `android/wear/.../voice/VoiceRecorder.kt:50` (`setMaxDuration`), `:53-58` (OnInfo),
`:73-88` (`stop()`), et `VoiceRecordingService.kt:171-186` (boucle timer).

```kotlin
// VoiceRecorder
rec.setMaxDuration(MAX_DURATION_MS)            // l.50 -> auto-stop système à 120 s
...
fun stop(): RecordingResult? {
    ...
    return try { rec.stop(); rec.release(); ... }   // l.79-82
    catch (t: Throwable) { rec.runCatching { release() }; file.delete(); null } // l.83-87
}
```

```kotlin
// VoiceRecordingService.startTimerLoop
if (ms >= VoiceRecorder.MAX_DURATION_MS) { handleStop(); break }   // l.180-182
```

**Cause** : à 120 s, `MediaRecorder` s'arrête **tout seul** (info `MAX_DURATION_REACHED`) ; il passe
en état `Stopped`. La boucle timer déclenche ensuite `handleStop()` → `rec.stop()`, qui sur un
recorder déjà arrêté lève `IllegalStateException` → le `catch` **supprime le fichier** et renvoie
`null` → `RecordingState.Error("stop returned null")`. Un vocal de 2 minutes (le maximum) est perdu
environ une fois sur deux selon que le tick 500 ms tombe avant ou après l'auto-stop. Le
`setOnInfoListener` se contente de logger et ne marque pas l'état.

**Correctif** : mémoriser un flag `stopped` posé par `MEDIA_RECORDER_INFO_MAX_DURATION_REACHED`
(et par `stop()`), et dans `stop()` retourner directement le fichier sans rappeler `rec.stop()`
si déjà arrêté. Idem pour l'`OnErrorListener` : sur erreur, finaliser le fichier au lieu de le
détruire silencieusement au prochain tick.

---

## N4 — 🗑️ Un callback Flutter périmé empêche la persistance des vocaux

**Fichiers** : `android/app/src/main/kotlin/chat/fluffy/fluffychat/wear/WearBridgePlugin.kt:31-44`,
`wear/WearBridge.kt:177-183`.

```kotlin
// WearBridgePlugin.init
WearBridge.voiceReceivedCallback = { msg -> Handler(main).post { channel.invokeMethod(...) } }
```

```kotlin
// WearBridge.handleIncomingVoice
val cb = voiceReceivedCallback
if (cb != null) cb(msg)
else { persistPendingVoice(context, msg) }   // fallback disque
```

**Cause** : `voiceReceivedCallback` (comme `refreshRequestedCallback`/`messagesRequestedCallback`)
n'est **jamais remis à `null`**. Quand l'Activity est détruite (app en arrière-plan tuée côté UI,
pli/dépli Pixel Fold, engine recréé), le callback pointe encore vers un `MethodChannel` mort.
Entre cette destruction et le prochain `register()`, un vocal DataItem réveille `WearBridgeService` :
`cb != null` → on appelle le callback sur un messenger mort (le vocal est perdu) et **le fallback
`persistPendingVoice` n'est jamais pris**. C'est exactement le scénario que la persistance devait
couvrir.

**Correctif** : exposer `WearBridge.clearCallbacks()` et l'appeler dans un
`onDetachedFromEngine`/`onCancel` du plugin (ou vérifier la liveness du messenger avant d'invoquer,
et persister si l'invocation échoue).

---

## N5 — 💥 FGS `dataSync` démarré depuis `BOOT_COMPLETED` (Android 15+ / targetSdk 36)

**Fichiers** : `android/wear/.../bridge/BootReceiver.kt:15-21`,
`android/wear/src/main/AndroidManifest.xml:106-114`, `WearForegroundService.kt:35-49`,
`android/wear/build.gradle.kts:19` (`targetSdk = 36`).

```kotlin
// BootReceiver.onReceive
WearForegroundService.start(context)   // l.19
```

**Cause** : Android 15 interdit le lancement d'un foreground service de type `dataSync` depuis un
receiver `BOOT_COMPLETED` (idem `camera`, `mediaPlayback`, `phoneCall`, `mediaProjection`,
`microphone`). Le module cible `targetSdk 36`, donc la restriction s'applique :
`ForegroundServiceStartNotAllowedException` au démarrage de la montre → crash du receiver.
La reprise est déjà assurée par GMS via `WearableListenerService` (qui démarre le FGS depuis
`onCreate`, contexte autorisé).

**Correctif** : ne pas démarrer `WearForegroundService` depuis `BootReceiver` ; conserver
uniquement la relance des uploads orphelins (`VoiceUploader.reEnqueueOrphans`), ou déplacer le
démarrage dans une `Worker`/un `JobScheduler` expédiant ensuite une action autorisée.

---

## N6 — 💥 (risque) FGS `microphone` démarré depuis une action de notification

**Fichiers** : `android/wear/.../notif/NotificationActionReceiver.kt:26-34`,
`voice/VoiceRecordingService.kt:223-227`, `android/wear/src/main/AndroidManifest.xml:95-98`.

```kotlin
// NotificationActionReceiver
ACTION_VOICE_REPLY -> VoiceRecordingService.start(ctx, roomId, autoUpload = true)  // l.31
```

```kotlin
// VoiceRecordingService.startForegroundWithNotif
startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)   // l.224
```

**Cause** : Android 14+ restreint le démarrage d'un FGS de type `microphone` depuis l'arrière-plan.
Le broadcast de `NotificationActionReceiver` (déclenché par un tap sur la notif) part d'un contexte
arrière-plan ; si l'app n'est pas dans un état « while-in-use » exempt (activité visible, FGS
autorisé, interaction utilisateur reconnue), `startForeground` lève
`SecurityException`/`ForegroundServiceStartNotAllowedException` → crash du service et vocal perdu.
La présence du FGS `dataSync` permanent ne suffit pas à elle seule à accorder le micro.

**Correctif** : à valider sur device (Wear OS 5/6). Si bloqué : ouvrir l'UI avant d'enregistrer
(au lieu de l'enregistrement 100 % headless), ou déclarer/obtenir une exemption, ou utiliser le
FGS déjà en cours en y ajoutant le type micro une fois l'activité visible.

---

## N7 — ⚠️ L'ack vocal par DataItem est un fallback mort (et s'accumule)

**Fichiers** : `android/app/.../wear/WearBridge.kt:303-314` (écriture DataItem ack),
`android/wear/.../bridge/WearListenerService.kt:92-116` (watch, ne gère que MessageClient),
`android/wear/src/main/AndroidManifest.xml:74-87` (filtres watch).

```kotlin
// WearBridge.ackVoice (phone) — 2) filet de sécurité via DataItem
PutDataMapRequest.create("/wear/voice/ack/$uuid").apply { ... }   // l.305
Wearable.getDataClient(context).putDataItem(req).await()          // l.310
// 3) cleanup : deleteDataItems("wear:/wear/voice/$uuid")          // l.318-319
```

**Cause** : la watch ne s'abonne, dans son manifest, qu'à des `MESSAGE_RECEIVED` pour
`/wear/voice/ack` et `/wear/voice/nack`, et aucun `DATA_CHANGED` sur ce chemin (seul
`/wear/rooms` en a un). `WearListenerService` n'a **pas** de branche `onDataChanged` pour les acks.
Le DataItem `/wear/voice/ack/{uuid}` écrit par le phone n'est donc **jamais lu** : si l'ack
MessageClient se perd (watch hors-ligne/cloud), la watch attend 20 s puis affiche définitivement
« Audio envoyé, confirmation différée » (`VoiceUploader.kt:130`) alors que la confirmation existe
sur le DataLayer. De plus, aucun des deux côtés ne supprime ces DataItems d'ack : ils
s'accumulent indéfiniment dans le Data Layer.

**Correctif** : ajouter un `DATA_CHANGED` `/wear/voice/ack` côté watch + branche
`onDataChanged` appelant `VoiceUploader.notifyAck`, et purger le DataItem d'ack après lecture.
Sinon, retirer le fallback et son commentaire trompeur.

---

## N8 — 🔒 Vie privée : payload DataLayer en clair, lisible par toute app

**Fichiers** : `android/app/.../wear/WearBridge.kt:63-78` (`/wear/rooms`) et `:124-138`
(`/wear/rooms/{roomId}/messages`) ; lecture watch `data/RoomsRepository.kt:62-71`.

```kotlin
val req = PutDataMapRequest.create("/wear/rooms/$roomId/messages").apply {
    dataMap.putByteArray(DATA_KEY, bytes)   // JSON en clair : previews, senderName, thumbs base64
}
```

**Cause** : le Data Layer Wear n'isole pas les DataItems par package ; une app tierce présente sur
la montre (ou le téléphone) et disposant de l'API Wearable peut lire les chemins
`/wear/rooms` et `/wear/rooms/{roomId}/messages`, qui contiennent **le texte des aperçus de
messages, les noms de rooms, les compteurs non lus et des vignettes base64**. Le contenu Matrix
est E2EE, mais ce cache l'est en clair. Le `isTrustedNode` ne protège que l'entrée, pas la sortie.

**Correctif** : chiffrer le payload (AES-GCM avec une clé dérivée échangée à l'appairage / stockée
dans Keystore), ou réduire drastiquement le contenu (pas de preview, pas de base64) si le risque
est accepté. À noter aussi que le build debug (`applicationIdSuffix .debug`) partage le même
DataLayer que le release — éviter de faire cohabiter.

---

## N9 — ⚠️ Couche Dart non défensive : casts, `MissingPluginException`, erreurs avalées

**Fichier** : `lib/utils/sms/sms_bridge.dart`.

1. **Casts durs sur des valeurs natives** — un type inattendu du natif lève `TypeError` (non
   `PlatformException`), qui n'est donc pas attrapé :
   - `:358` `displayName: m['displayName'] as String?`
   - `:362` `photoPath: m['photoPath'] as String?`
   - `:396` `(m['numbers'] as List<dynamic>?)`
   - `:440` `(m['attachments'] as List<dynamic>?)` puis `Map<String, dynamic>.from(e)`
   - `:63` `Map<String, dynamic>.from(e as Map)`
2. **Seul `PlatformException` est attrapé** (`:94, :102, :123, :137, :150, :163, :176, :197, :209,
   :220, :232, :244, :257, :273, :284, :298`). Or `MissingPluginException` **n'hérite pas** de
   `PlatformException` : si le plugin natif n'est pas enregistré (engine non configuré, desktop,
   hot-restart partiel), chaque appel jette une exception asynchrone non gérée.
   Seul `nativeLog` (`:110-114`) utilise un `catch (_)` large.
3. **Erreurs avalées** : `listConversations` (`:155-166`) et `listMessages` (`:184-200`)
   renvoient une liste vide sur toute `PlatformException` → l'UI affiche « aucune conversation »
   sans distinction entre « vide » et « erreur sécurité/provider ».

**Correctif** : parsing tolérant (`m['x']?.toString()`, `m['x'] is List ? ... : const []`),
`catch (e)` large au lieu de `on PlatformException`, et remonter un état d'erreur explicite
(ou au minimum `debugPrint`) plutôt que de retourner silencieusement un défaut.

---

## N10 — ⚠️ `DataItemBuffer` jamais libéré dans les `readCurrent`

**Fichiers** : `android/wear/.../data/RoomsRepository.kt:62-71`,
`data/RoomMessagesRepository.kt:55-65`, `bridge/WearListenerService.kt:52-68`.

```kotlin
val items = dataClient.dataItems.await()
val match = items.firstOrNull { it.uri.path == targetPath } ?: return null
...
decode(bytes)   // pas de items.release()
```

**Cause** : `DataItemBuffer` détient des ressources natives et doit être `release()`. Les
`callbackFlow` le font via `events.use {}`, mais les `readCurrent()` (appelés à chaque `onStart`
de flow et à chaque ping) **ne le libèrent jamais**. Fuite jusqu'au finalizer. Dans
`WearListenerService.notifyFromCurrentRooms` (`:52-68`), `items.release()` est appelé **après**
`DataMapItem.fromDataItem` : si cette conversion ou le décodage lève, le buffer n'est pas libéré.

**Correctif** : `items.use { buf -> ... }` ou `try { ... } finally { items.release() }` partout.

---

## Findings secondaires (sévérité basse à moyenne)

### S1. ⚠️ OTP : `extract` renvoie le **premier** nombre, pas le code
`sms/OtpExtractor.kt:32` (`CODE_REGEX.find(body)`). Ex. « Commande du 12/09/2026 : code de retrait
458963 » → la regex matche « 2026 » (année) avant le vrai code et renvoie `2026`. Autre cas :
« code 123 4567 » → `\d{4,8}` matche « 4567 » et non « 1234567 ». Aucun scoring de proximité avec
le mot-clé. **Correctif** : chercher un motif `(code|otp|pin)[^0-9]{0,40}(\d[...])`, écarter les
années (1900-2099) et les dates, ou prendre le match le plus proche d'un mot-clé. À noter aussi :
« PIN:1234 » n'est pas détecté (`"pin "` exige un espace) et `lowercase()` est sensible à la locale.

### S2. ⚠️ Dialogue d'échec vocal global et périmé
`wear/.../voice/VoiceUploader.kt:74-75,127-131` (état `StateFlow` global) et
`RoomDetailScreen.kt:204-219`. Un upload headless qui échoue laisse `UploadState.Error` en
mémoire ; à l'ouverture **de n'importe quelle room** ensuite, `FailureConfirmationDialog`
s'affiche avec ce message périmé, sans lien avec l'action courante. **Correctif** : scoper l'état
par uuid/room, ou `VoiceUploader.reset()` à l'entrée de l'écran.

### S3. ⚠️ Drain concurrent des vocaux au re-register
`wear/WearBridgePlugin.kt:48` appelle `WearBridge.drainPendingVoices(context)` à **chaque**
construction de plugin. Deux engines/plugins successifs (pli/dépli, recréation d'Activity) lancent
deux `scope.launch` qui listent le même dossier et peuvent livrer/uploader **le même fichier deux
fois** (lecture avant suppression). **Correctif** : mutex global dans `WearBridge` autour du drain.

### S4. ⚠️ Re-enqueue d'orphelins : l'ancien uuid n'est pas purgé
`wear/.../voice/VoiceUploader.kt:141-173`. `reEnqueueOrphans` lit `uuid`, puis appelle `upload()`
qui génère un **nouvel** uuid ; l'ancien reste dans `pending_uuids` et `$uuid.file` jusqu'au
prochain boot (où le fichier aura été supprimé → nettoyage). Une ré-évaluation supplémentaire,
voire un double upload si le boot tombe pendant la fenêtre. **Correctif** : appeler
`clearPending(context, uuid)` avant de relancer.

### S5. ⚠️ `WearListenerService` démarre le FGS en cascade
`android/wear/.../bridge/WearListenerService.kt:36-41` : chaque réveil GMS (message ou data)
appelle `WearForegroundService.start()` — OK, mais cumulé au `MainActivity` et au `BootReceiver`,
il y a trois points de démarrage du même FGS. Voir N5.

### S6. 🗑️ Codec vocal borné à API 29+ alors que `minSdk = 26`
`wear/build.gradle.kts:18` (`minSdk = 26`) et `VoiceRecorder.kt:45-46`
(`OutputFormat.OGG` + `AudioEncoder.OPUS`). Sur Wear OS < 5 (API 26-28), MediaRecorder ne supporte
pas OPUS/OGG → `prepare()`/`start()` lèvent → `RecordingState.Error`. Pas de fallback AAC/AMR.

### S7. 🔧 `shrinkResources` sans keep des ressources dynamiques
`android/app/build.gradle.kts:97-99` (`isMinifyEnabled = true`, `isShrinkResources = true`) avec
`proguard-rules.pro` réduit à `-keep class net.sqlcipher.**`. Les composants déclarés au manifest
(receivers/services/provider) sont conservés par AGP, mais les ressources référencées **par nom**
depuis Dart ou Kotlin (`SmsNotifier.kt:199` : `getIdentifier("notifications_icon", "drawable", ...)`,
icônes de notif passées en chaîne) peuvent être supprimées en release. **Correctif** : `tools:keep`
ou règles `-keep`/`shrinkResources` dédiées si ces ressources existent.

### S8. ⚠️ `WearBridgeService` (phone) : `isTrustedNode` ne distingue pas l'app watch
`android/app/.../wear/WearBridgeService.kt:106-117` vérifie seulement que le node est appairé,
pas que c'est **notre** app watch. Toute app Wear appairée peut donc envoyer
`/wear/rooms/*/request` et `/wear/voice/*`. Moindre que N2 (le phone valide le roomId et ne
supprime pas d'audio), mais le principe « node appairé ⇒ confiance » est trop large.

### S9. 🔧 `key.properties` en clair + keystore release
`android/key.properties` contient les mots de passe du keystore en clair (gitignoré, non suivi —
vérifié). Le build wear référence par défaut `file("dummy.keystore")` (`wear/build.gradle.kts:56`),
**fichier inexistant** : si `key.properties` disparaît (CI, clone frais), le build release échoue
sur « Keystore file not found ». Pas un bug runtime, mais piège de build.

### S10. 🔧 `MmsPduProvider`/`MmsSentReceiver` déjà signalés
Rappel initial (points A/B) : ne pas re-compter. Mentionnés uniquement pour dire que la lecture
complète du manifest confirme qu'ils restent présents.

---

## Ce qui a été vérifié et ne pose pas de problème

- Décodage borné des payloads DataItem watch (512 Ko) et phone (90 Ko) : cohérent.
- Validation `ROOM_ID_RE` côté phone pour `/wear/rooms/{id}/request` : correcte.
- Whitelist MIME + clamp de durée vocale (`WearBridgeService.kt:85-86`) : corrects.
- Garde OOM du vocal (`MAX_VOICE_BYTES` 8 Mo) et release du `ParcelFileDescriptor`
  (`WearBridge.kt:159-164`) : corrects.
- `VoiceUploader` : `ParcelFileDescriptor.use {}` sur l'Asset, `persistPending/clearPending`
  sous lock et `commit()` synchrone, garde path-traversal du `filePath` canonicalisé
  (`:159-165`) : corrects.
- `SmsReplyReceiver` : utilise `goAsync()` + `finally { pending.finish() }` : correct.
- Manifest watch : `WearListenerService`/`WearForegroundService`/`VoiceRecordingService`
  types et permissions cohérents (hors N5/N6).
- Proguard wear : keeps explicites (app, GMS wearable, kotlinx.serialization, Log) OK.
- `sms_bridge.dart` : `takePendingOpenRequest`, `_archiveChanges`, flux broadcast : corrects
  hors N9.

## Incertitudes / non couvert

- **Aucun device dans cette session** : N6 (FGS micro en arrière-plan) et N5 (boot) doivent être
  confirmés sur Wear OS 5/6 réel ; les restrictions Android 14/15 sont documentées mais
  l'exemption exacte pour une action de notification doit être testée.
- Le point N8 (DataLayer lisible par toute app) repose sur le comportement connu de partage du
  Data Layer Wear ; à confirmer selon la version GMS.
- Aucun test Kotlin/Dart dans le repo : pas de reproduction automatique possible.
- Les chemins `MmsRetrieveParser`/`SmsBridge` (hors Wear/Otp/plugin/Dart) n'ont pas été réanalysés
  en profondeur : couverts par le rapport initial.
