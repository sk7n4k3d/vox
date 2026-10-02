# Audit bugs — couche native Kotlin (SMS/MMS/Wear)

- **Date** : 2026-10-02
- **Périmètre** : `android/app/src/main/kotlin/chat/fluffy/fluffychat/{sms,wear}/**`,
  `MainActivity.kt`, `FcmPushService.kt`, `android/app/src/main/AndroidManifest.xml`,
  `res/xml/{file_paths,network_security_config}.xml`
- **Branche** : `feature/ux-refonte` (lecture seule — aucun fichier de code modifié)
- **Méthode** : lecture intégrale fichier par fichier, reconstitution des flux, vérification
  des signatures Android sur `android.jar` API 34 (SmsManager, SubscriptionManager, Process,
  ConnectivityManager, CarrierConfigManager), grep des usages croisés Kotlin/Dart.

> Ce document ne modifie rien. Chaque finding indique fichier:ligne, gravité, cause, correctif.

---

## Synthèse

| # | Gravité | Sujet | Fichier |
|---|---------|-------|---------|
| 1 | 💥 ANR | `SmsDeliverReceiver` fait toute l'I/O provider + contacts + notif sur le main thread | `SmsDeliverReceiver.kt:24-93` |
| 2 | 🗑️ data-loss | `HeadlessSmsSendService` `stopSelf()` puis `onDestroy` annule le scope → quick-reply perdu | `HeadlessSmsSendService.kt:44-60` |
| 3 | 🗑️ data-loss | SMS/MMS sortant laissé en OUTBOX à vie si l'envoi échoue | `SmsBridge.kt:757-777`, `1100-1130` |
| 4 | ⚠️ UX | Pagination `date < beforeMs` stricte : messages à timestamp égal jamais rechargés | `SmsBridge.kt:341-344,416-419` |
| 5 | 🗑️ data-loss | Date d'un MMS entrant = date d'ingestion, pas la date PDU | `SmsBridge.kt:1988`, `MmsRetrieveParser.kt:69` |
| 6 | ⚠️ UX | `isAccepted()` heuristique sur scan brut du PDU → faux « échec » MMS | `MmsHttpClient.kt:42-68` |
| 7 | 💥 race | `SmsNotifier.history` (HashMap) muté depuis main ET IO sans verrou | `SmsNotifier.kt:60,122-124` |
| 8 | ⚠️ bug | `onDone()` appelé 2× dans `downloadIncomingMms` (chemins d'erreur) | `SmsBridge.kt:1785-1851` |
| 9 | 💥 race | `MmsNetworkManager.acquire` : double `requestNetwork` + callback écrasé/fui | `MmsNetworkManager.kt:53-114` |
| 10 | 🔒/⚠️ | `uuid` watch non validé → traversée de chemin dans le nom de fichier | `WearBridge.kt:238`, `WearBridgeService.kt:70` |

---

## 1. 💥 ANR potentiel — `SmsDeliverReceiver` fait tout sur le main thread

**Fichier** : `sms/SmsDeliverReceiver.kt:24-93`

`onReceive()` s'exécute sur le thread principal par défaut (aucun `goAsync()`), et enchaîne :
`Telephony.Sms.Intents.getMessagesFromIntent()` (l.28), `SmsBridge.insertInbox()` (l.44,
IPC ContentResolver vers le provider téléphonie), `threadIdForSms()` (l.45, 2e requête),
`SmsBridge.lookupContact()` (l.81, requête `PhoneLookup` dans la base Contacts) et
`SmsNotifier.notifyIncoming()` (l.82, décodage bitmap + publication notif).

Sur un appareil chargé / base Contacts lente, ces appels synchrones peuvent dépasser le
budget du receiver et déclencher un ANR (« Broadcast of Intent … SMS_DELIVER has timed out »).
Le receiver MMS voisin utilise pourtant `goAsync()` (`MmsDeliverReceiver.kt:47`).

**Correctif** : envelopper le traitement dans `goAsync()` + coroutine `Dispatchers.IO`
(comme `MmsDownloadedReceiver`), en séparant l'insertion provider (rapide) du lookup contact +
notification (lent, best-effort).

---

## 2. 🗑️ data-loss — `HeadlessSmsSendService` tue son scope avant l'envoi

**Fichier** : `sms/HeadlessSmsSendService.kt:44-60`

```kotlin
scope.launch { for (recipient in recipients) { SmsBridge.sendSms(...) } }  // l.44-52
stopSelf(startId)                                                          // l.55
return START_NOT_STICKY                                                    // l.56
...
override fun onDestroy() { scope.cancel(); ... }                           // l.60
```

`stopSelf()` est appelé immédiatement après le `launch` : Android appelle `onDestroy()`
peu après, qui **annule le scope** → la coroutine `sendSms` peut être interrompue avant même
d'avoir inséré la ligne outbox ou appelé `sendMultipartTextMessage`. Résultat : la réponse
rapide depuis l'écran d'appel est silencieusement perdue.

**Correctif** : ne pas `stopSelf()` avant la fin du travail — enchaîner
`stopSelf(startId)` dans un `finally` du `launch`, ou convertir en `JobService`, ou lancer
l'envoi via `goAsync`-équivalent (ex. `CoroutineScope` non annulé + `stopSelf` dans le
callback).

---

## 3. 🗑️ data-loss / UX — messages sortants bloqués en OUTBOX

**Fichiers** : `sms/SmsBridge.kt:749-796` (SMS), `sms/SmsBridge.kt:997-1130` (MMS)

- `sendSms` insère la ligne outbox (`insertOutbox`, l.757/780) puis appelle
  `sendMultipartTextMessage` (l.768). Si cet appel lève (SecurityException, service SMS
  indisponible, `divideMessage`), le `catch` (l.771-777) log et renvoie `null` **sans jamais
  repasser la ligne en `MESSAGE_TYPE_FAILED`**. La bulle reste « en cours d'envoi » à vie.
- `sendPduOnMmsNetwork` (l.1100-1130) : si `readMmsApn` ne trouve pas de MMSC (l.1109-1112)
  ou si le POST échoue (`ok == false`), `markMmsSent` n'est pas appelé et rien ne passe la
  ligne MMS en `MESSAGE_BOX_FAILED` (l.1248-1259 ne gère que le succès). Outbox MMS à vie.

**Correctif** : dans les `catch` et sur `ok == false`, faire un `update` de la ligne
(`TYPE=FAILED` + `ERROR_CODE` pour SMS ; `MESSAGE_BOX_FAILED` pour MMS).

---

## 4. ⚠️ UX — pagination par date stricte perd des messages

**Fichier** : `sms/SmsBridge.kt:339-344` (SMS) et `414-419` (MMS)

Le curseur de pagination est la date du message le plus ancien chargé, et la page suivante
filtre `DATE < beforeMs` (strict). Deux messages partageant exactement le même timestamp
(très courant côté MMS, dont `DATE` est en **secondes** — cf. l.209, `listMms` l.478)
au niveau de la frontière de page : celui qui n'était pas dans la page courante ne sera
**jamais** retourné, car `date == beforeMs` est exclu. Le message disparaît de la conv.

**Correctif** : paginer sur un curseur composite `(date, id)` avec
`DATE < ? OR (DATE = ? AND _ID < ?)`, ou dédupliquer par `id` au fil des pages.

---

## 5. 🗑️ data-loss/correctness — la date d'un MMS entrant est écrasée

**Fichiers** : `sms/SmsBridge.kt:1988`, `sms/MmsRetrieveParser.kt:69`

`insertRetrievedMms` écrit `Telephony.Mms.DATE = System.currentTimeMillis()/1000` (heure
d'ingestion), alors que le PDU `m-retrieve-conf` contient la date réelle d'envoi
(`FIELD_DATE = 0x85`)… que `MmsRetrieveParser` **jette** (`FIELD_DATE -> c.skipLongInteger()`,
l.69). Un MMS non téléchargé tout de suite (téléphone éteint, hors réseau, MMSC lent) se
retrouve daté à l'heure du download → mauvais ordre dans le fil et mauvaise date affichée.
À noter : `MmsRetrieveParser.Retrieved` n'expose pas de champ `date` du tout.

**Correctif** : parser `FIELD_DATE` (long-integer → epoch secondes) et le propager dans
`Retrieved`, puis l'utiliser au lieu de `now()` (fallback `now()` si absent/0).

---

## 6. ⚠️ UX — `isAccepted()` peut marquer un MMS envoyé comme échoué

**Fichier** : `sms/MmsHttpClient.kt:42-68`

`parseResponseStatus` (l.42) **scanne tout le PDU** à la recherche de l'octet `0x93` sans
respecter la structure des champs ; il peut tomber sur un `0x93` présent dans le corps/les
autres champs et lire du garbage comme « response-text ». `isAccepted` (l.63) exige ensuite
`contains("1000") || == "ok" || endsWith(":ok")` : toute réponse valide dont le texte diffère
(autre libellé opérateur, réponse binaire sans texte) est classée **rejetée** → l'utilisateur
voit un MMS « échoué » alors que le MMSC l'a accepté. Le commentaire au-dessus de
`parseResponseStatus` (l.31-35) parle de `X-Mms-Response-Status (0x92)`, mais le code ne lit
que `0x93` : la partie binaire n'est jamais décodée.

**Correctif** : parser proprement le champ `0x92` (Response-Status, short-integer) et/ou
n'accepter `0x93` qu'en position de champ (walk WSP), et considérer « pas de signal lisible »
comme succès HTTP plutôt que comme échec.

---

## 7. 💥 race — `SmsNotifier.history` non thread-safe

**Fichier** : `sms/SmsNotifier.kt:60` (déclaration), `122-124` (mutation)

`history` est un `HashMap` mutable global. `notifyIncoming` peut être appelé :
- depuis `SmsDeliverReceiver.onReceive` → main thread (`SmsDeliverReceiver.kt:82`) ;
- depuis `ingestDownloadedMms` → `Dispatchers.IO` (`SmsBridge.kt:1934`, via
  `MmsDownloadedReceiver`).

Deux threads mutent donc le `HashMap` (`getOrPut`, `add`, `removeAt`) sans synchronisation :
risque de corruption d'entrée HashMap (perte ou boucle), en plus de `Person`/notif incohérents.
`cancel()` (l.227) et `history[threadId]` (l.265) lisent aussi sans verrou.

**Correctif** : `ConcurrentHashMap` + liste synchronisée par thread, ou
`synchronized(history)` sur toutes les accès. Rendre `notifyIncoming` explicitement
main-thread-only serait plus propre.

---

## 8. ⚠️ bug — `onDone()` invoqué deux fois dans `downloadIncomingMms`

**Fichier** : `sms/SmsBridge.kt:1780-1852`

Les chemins d'erreur appellent `onDone()` **puis** `return` (l.1788-1790 pour
content-location absente, l.1798-1800 pour schéma non http(s)), mais le `finally` (l.1849-1851)
appelle aussi `onDone()`. Le `onDone` réel est le `pending.finish()` du receiver
(`MmsDeliverReceiver.kt:52`) → `finish()` appelé deux fois. La doc du paramètre (l.1777-1779)
dit « invoqué quand la requête a été soumise », ce qui est faux sur ces chemins. Aucun
`onDone()` sur le chemin nominal avant le `finally` : le contrat est incohérent.

**Correctif** : retirer les `onDone()` explicites des `return` d'erreur (garder le seul
`finally`), ou utiliser un flag `done` idempotent.

---

## 9. 💥 race (latent) — `MmsNetworkManager.acquire` : double acquisition

**Fichier** : `sms/MmsNetworkManager.kt:53-114`

Le fast-path « réseau déjà acquis » ne teste que `network != null` (l.56), pas « acquisition
en cours ». Or le monitor `lock` est **relâché pendant `lock.wait()`** (l.101) : un 2e thread
peut entrer dans `synchronized(lock)`, incrémenter `refCount`, voir `network == null`, puis
appeler une **2e fois `cm.requestNetwork(request, cb)`** (l.88) et écraser `callback = cb`
(l.87). Le callback du 1er thread n'est alors plus jamais désenregistré → fuite de
`NetworkCallback` et réseau potentiellement maintenu.

En pratique, tous les appels passent par `mmsSendExecutor` (single-thread,
`SmsBridge.kt:1091-1092`), donc l'overlap ne se produit pas aujourd'hui : bug **latent**,
mais le comptage de références est présenté comme supportant des appels concurrents, ce qui
est faux.

**Correctif** : un état `acquiring` (ou un objet `CountDownLatch`/future par acquisition)
pour ne lancer qu'un seul `requestNetwork` et faire attendre les autres.

---

## 10. 🔒 sécurité — `uuid` watch non validé, utilisé comme nom de fichier

**Fichiers** : `wear/WearBridgeService.kt:70`, `wear/WearBridge.kt:238`

`uuid` est lu depuis le `DataMap` (`getString(KEY_UUID)`, l.70) sans validation de forme, puis
concaténé dans un nom de fichier : `File(pendingVoicesDir, "${ts}_${msg.uuid}.bin")`
(`WearBridge.kt:238`). Un `uuid` contenant `../` (émis par une watch appairée compromise)
écrit hors de `wear_voice_pending/`, dans le stockage privé de l'app. Même remarque pour
`WearBridge.ackVoice` qui compose `/wear/voice/ack/$uuid` (l.290/305) et
`dataMap.putString("uuid", uuid)`. À l'inverse, `roomId` est bien filtré par `ROOM_ID_RE`
(`WearBridgeService.kt:44,79`).

**Correctif** : valider `uuid` (regex UUID/`[A-Za-z0-9-]{8,64}`) avant tout usage fichier/path,
et refuser sinon.

---

## Findings secondaires (sévérité basse à moyenne)

### A. 🔒 Provider `MmsPduProvider` exporté pour un chemin mort
`MmsPduProvider.kt:28-54`, manifest `<provider … exported="true">`. Depuis le passage à
l'envoi direct HTTP (`MmsHttpClient`), plus aucun `sendMultimediaMessage` n'utilise ce
provider : `MmsPduProvider.buildUri` (l.81) n'est appelé nulle part et le fichier PDU écrit
dans `SmsBridge.kt:1055-1058` n'est jamais relu. Surface d'attaque exportée gratuite.
Correctif : supprimer le provider + le fichier PDU, ou `exported="false"` si un usage revient.
(La garde UID `Binder.getCallingUid()` l.40-47 est correcte par ailleurs.)

### B. 🗑️ Code mort de l'ancien envoi MMS système
`SmsBridge.buildMmsSentIntent` (l.1468-1479), `obtainSmsManagerForMms` (l.1482-1495),
`MmsSentReceiver.kt` entier, `ACTION_MMS_SENT` (l.79), `EXTRA_MMS_ID` (l.82) et le
`<receiver .sms.MmsSentReceiver>` du manifest : plus aucun `PendingIntent` n'est créé, donc
le receiver ne se déclenche **jamais**. Sa logique (`MESSAGE_BOX_SENT/FAILED`, `READ`, `SEEN`)
fait doublon avec `markMmsSent` (l.1248). Et `MmsSentReceiver` ne gère que le succès.
Correctif : supprimer, ou réutiliser via le chemin `sendMultimediaMessage` si on y revient.

### C. ⚠️ `SmsNotifier.ensureChannel` fige le son à la création
`SmsNotifier.kt:70-85`. `ensureChannel` retourne si le channel existe (l.73). Android ne
réapplique pas le son d'un channel déjà créé : couper le réglage
`sms_notifications_sound` après coup ne change rien tant que le channel n'est pas recréé.
Correctif : recréer le channel (avec un id suffixé/version) quand le réglage son change,
ou déléguer le son au `Notification` (`setSilent`/`setSound`) plutôt qu'au channel.

### D. ⚠️ `pendingSmsIntent` statique jamais vidé sur push « live »
`SmsBridgePlugin.kt:378-413`. `setPendingSmsIntent` écrit le statique (l.410) **et** pousse
l'event (l.412). Si l'app est déjà ouverte, l'event est consommé par le stream Dart, mais le
statique reste rempli : au prochain `getPendingSmsIntent` (l.143-147), Dart ré-ouvre une
seconde fois la même conversation. Correctif : mettre `pendingSmsIntent = null` quand l'event
est poussé en live.

### E. ⚠️ `insertInbox` ne renseigne pas `SUBSCRIPTION_ID`
`SmsBridge.kt:1559-1578`. Sur bi-SIM, la ligne entrante est attribuée à la SIM par défaut du
provider plutôt qu'à la SIM réceptrice. Idem `insertOutbox` (l.780-796). Correctif : récupérer
la subId (l'intent SMS_DELIVER porte `SubscriptionManager`/`EXTRA_SUBSCRIPTION`) et la poser.

### F. 🗑️ `runCatching` avale les erreurs de notification
`SmsDeliverReceiver.kt:80-91`. Le `runCatching { lookupContact(...); notifyIncoming(...) }`
n'utilise pas le résultat : toute exception est **silencieuse** (ni log ni trace). Un échec
répété de notif (bitmap invalide, OOM photo) est invisible. Idem `SmsBridge.kt:1912-1946`.
Correctif : `onFailure { Log.w(TAG, ..., it) }`.

### G. ⚠️ Regroupement/agrégation SMS entrant approximatif
`SmsDeliverReceiver.kt:39-41`. `groupBy { originatingAddress }` fusionne tous les PDUs du
broadcast par expéditeur, puis concatène les corps en ignorant les `messageBody` nuls
(`?: ""`). Deux SMS distincts du même émetteur dans le même intent (rare mais possible sur
certains OEM) sont collés en un seul message ; une part sans body est silencieusement perdue.
Correctif : s'appuyer sur la référence de concaténation (`SmsMessage` n'expose pas
`getPdu`/ref sur l'API publique — regrouper au minimum par `(address, timestampMillis)` et
logger les parts vides).

### H. ⚠️ Bind process-wide sur le réseau MMS pendant l'envoi
`MmsNetworkManager.kt:36-51`. `bindProcessToNetwork(net)` route **tout** le trafic du process
sur le réseau cellulaire MMS pendant la durée du POST (jusqu'à 30 s de timeout,
`MmsHttpClient.kt:137-138`). Le sync Matrix / les autres requêtes HTTP de l'app passent par ce
chemin pendant ce temps. Correctif : garder le bind le plus court possible, ou utiliser
`network.openConnection()` (le commentaire `MmsHttpClient.kt:117-122` dit que ça a racé en
EPERM — à revoir avec un retry plutôt qu'un bind global).

### I. 🔒 `isTrustedNode` bloquant 5 s sur le thread du listener
`WearBridgeService.kt:106-117`. `Tasks.await(..., 5s)` sur un callback système ; si GMS ne
répond pas, chaque message/DataItem bloque 5 s. Fail-closed correct, mais un timeout plus
court (1-2 s) ou un cache des nodes appairés éviterait de geler le service.

### J. ⚠️ `ackVoice` : suppression de DataItem avec une URI incomplète
`WearBridge.kt:317-322`. `Uri.parse("wear:/wear/voice/$uuid")` ne porte pas le host (nodeId) ;
`deleteDataItems` ne matche probablement pas le DataItem réel `wear://<node>/wear/voice/<uuid>`
→ l'asset watch n'est jamais purgé (échec avalé par le `catch` l.320). Correctif : construire
l'URI avec le host du node, ou passer par le `Uri` d'origine.

### K. ⚠️ `MmsRetrieveParser` : `mmsPartsBatch` peut dépasser la limite SQLite
`SmsBridge.kt:510-524`. `MSG_ID IN (?,?,…)` avec un `limit=0` (pas de limite, cf.
`listMessages`) sur un fil à >999 MMS → `SQLiteException` (limite de variables), attrapée et
loggée (l.561) → **toutes** les parts perdues pour ce lot. Correctif : chunker par 500, ou
borner `limit` côté Kotlin.

### L. ⚠️ `MmsDownloadedReceiver` : fichier PDU non supprimé sur parse KO
`SmsBridge.kt:1890-1894` et `1921-1925`. En cas de PDU illisible, `return false` sans
`file.delete()` → accumulation dans `cacheDir/mms_in`. Idem si `insertRetrievedMms` échoue
(retourne `-1`, le fichier est déjà supprimé l.1897 — OK, mais pas les branches précédentes).
Correctif : supprimer le fichier dans un `finally`.

### M. ⚠️ `SmsSentReceiver` : reports de remise quasi toujours « complete »
`SmsSentReceiver.kt:48-63`. `Telephony.Sms.Intents.getMessagesFromIntent(intent)` ne contient
pas de PDU pour un `SMS_DELIVERED` ; on retombe systématiquement sur `STATUS_COMPLETE`, même
pour un échec opérateur. Le commentaire l'assume, mais l'utilisateur voit « remis » à tort.
Correctif : émettre le PendingIntent DELIVERED avec `SmsManager` et lire le vrai
`SmsMessage.status` quand le PDU est présent (ce que fait déjà le `when`, mais il ne reçoit
jamais de données).

### N. ⚠️ `MmsRetrieveParser` : date et ordre des parts
`MmsRetrieveParser.kt:94-106`. `name` finit comme `part_$i` par défaut, mais peut être écrasé
par Content-Location (0x8E/0xAE)… ou par Content-ID (0x85/0x97) selon l'ordre du PDU, donnant
des noms du type `<image_0>`. Impact cosmétique (nom d'attachement). Aucun correctif urgent.

### O. ⚠️ `SmsBridgePlugin` : scope jamais annulé au re-register
`SmsBridgePlugin.kt:56`, `register` l.388-395. À chaque `configureFlutterEngine` (pli/dépli
Pixel Fold), un nouveau plugin + scope est créé sans annuler l'ancien. Les jobs en vol peuvent
appeler `result.success` sur un `binaryMessenger` mort. Correctif : annuler l'ancien scope
dans `register`.

---

## Revue `AndroidManifest.xml`

- **Receivers/exports** : corrects pour le rôle ROLE_SMS. `SmsDeliverReceiver` protégé par
  `permission="android.permission.BROADCAST_SMS"`, `MmsDeliverReceiver` par
  `BROADCAST_WAP_PUSH` — bien. `SmsSentReceiver`/`MmsSentReceiver`/`SmsReplyReceiver`/
  `MmsDownloadedReceiver` `exported="false"` — bien. `HeadlessSmsSendService` protégé par
  `SEND_RESPOND_VIA_MESSAGE` — bien.
- **`WearBridgeService` `exported="true"`** : nécessaire pour GMS, garde `isTrustedNode`
  en place (finding I). OK.
- **`MmsPduProvider` `exported="true"`** : voir finding A, à supprimer ou fermer.
- **Intent-filter MainActivity `SEND` `*/*`** : cible de partage large mais volontaire (fork
  FluffyChat). Pas de `SENDTO` dangereux au-delà des schémas sms/mms attendus.
- **Permissions à vérifier** : `WRITE_EXTERNAL_STORAGE` / `READ_EXTERNAL_STORAGE` —
  inutiles sur Android 10+ en scoped storage et non référencées par la couche Kotlin SMS/MMS
  (elles servent peut-être à un plugin pub.dev : `flutter_file_dialog`, `image_picker`,
  `flutter_inappwebview`). `requestLegacyExternalStorage="true"` (l. du manifest) est ignoré
  sur API 30+ et sans effet ici. À revoir si aucun plugin ne les utilise :
  suppression = surface + revue Play réduites.
- Pas de `<queries>` : non nécessaire pour la couche SMS/MMS (aucune résolution de package).
- `network_security_config` : cleartext limité aux 4 MMSC FR — correct et bien pensé.
- `file_paths.xml` expose `mms_in/`, `mms_out/`, `mms_parts/` en cache — cohérent.

---

## Incertitudes / non couvert

- **Aucun test Kotlin** dans le repo (`find android -path *test*` : vide). Les findings
  ci-dessus ne sont donc pas couverts par une suite de tests.
- Le **chemin nominal MMS entrant/sortant n'a pas été exécuté** (pas de device dans cette
  session) : les gravités reposent sur la lecture du flux, pas sur une reproduction.
- Le décodage binaire WSP de `MmsPduComposer` (Content-ID `0x40 or 0x80`, ordre des headers)
  n'a pas pu être validé octet-à-octet sans capture MMSC réelle — non signalé comme bug.
- Les fichiers hors périmètre (`FcmPushService.kt` entièrement commenté, Dart
  `lib/utils/sms/*`) n'ont pas été audités, seulement parcourus pour vérifier les usages
  croisés (préfixe `FlutterSharedPreferences`, `kind` des events).
- La correspondance `applicationId` (`eu.devlabz.vox`) ↔ autorité `MmsPduProvider`
  (`eu.devlabz.vox.mmspdu` l.77) et ↔ préfixe `FileProvider` (`${applicationId}.fileprovider`)
  est cohérente pour le build actuel ; un `applicationIdSuffix` de debug la casserait.

---

## Ordre de correction conseillé

1. **#2** (perte SMS quick-reply) et **#1** (ANR receiver) — fiabilité quotidienne.
2. **#3** (OUTBOX à vie) et **#5** (mauvaise date MMS) — intégrité visible des fils.
3. **#7** (HashMap) et **#9** (network manager) — races, avant tout ajout de concurrence.
4. **#4/#6/#8** — UX et faux négatifs MMS.
5. **#10/A** — durcissement sécurité, puis nettoyage du code mort (B).
