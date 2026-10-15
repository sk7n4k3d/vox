# VOX MatrixRTC 1:1 — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** appels 1:1 MatrixRTC (audio/vidéo) entre VOX et Element X/Web via le LiveKit `matrix-rtc.sk7.sh`, en coexistence avec le VoIP legacy `m.call.*`.

**Architecture :** module `lib/utils/rtc/` dans l'app (le SDK patché parle le dialecte `com.famedly.call.member`, ignoré d'Element). Signalisation = state events `org.matrix.msc3401.call.member` ; média = `livekit_client` (même WebRTC natif que flutter_webrtc, aucune lib supplémentaire) ; UI = l'interface `CallController` déjà découplée, second pilote.

**Tech Stack :** Dart/Flutter, `livekit_client 2.13.1`, `matrix-dart-sdk-patched` (aucune modif SDK prévue), tests `flutter_test`.

**Spec :** `docs/superpowers/specs/2026-10-15-voip-matrixrtc-design.md` (à lire en entier avant le task 1 ; §1 contient la séquence d'auth prouvée en spike, §3 les formats wire, §8 les jalons terrain).

**Travail sur :** edge-01, `ssh 10.8.0.2`, repo `~/Bureau/dev/Applications/fluffychat`, branche `main`. Tests : `flutter test test/rtc/` (à créer) et `flutter test test/pages/call/` (44 tests existants, jamais cassés). Build : `flutter build apk --release` (~2-3 min).

## Global Constraints

- Aucune modification de `../matrix-dart-sdk-patched` (si jugé indispensable : s'arrêter et le justifier).
- `flutter analyze` : aucun NOUVEAU diagnostic (5 infos préexistantes dans `lib/pages/call/` tolérées).
- Ne jamais logger un token, un JWT complet ni une clé e2ee (uniquement id/longueurs) — même règle `PII-safe` que le webhook.
- Commit à chaque task, messages conventionnels français comme l'historique (`feat(rtc): …`), **jamais de `git push`** (hors feu vert explicite de Bastien).
- Ne pas toucher au chemin legacy `m.call.*` ni aux 44 tests existants.
- versionCode : NE PAS incrémenter (3552 reste, `install -r`).

## Review Focus

Classes d'entrée que les specs ne testent pas encore et qui cassent des appels :

1. **Membership malformée** (event `org.matrix.msc3401.call.member` au contenu vide/casse, ou émis par un bot) → ignorer silencieusement, jamais de crash ni d'écran fantôme. → test task 2.
2. **JWT périmé ou SFU qui répond 401/M_UNKNOWN en plein appel sortant** → régénérer token+JWT une seule fois, échec = message d'erreur, pas de boucle. → test task 3 (`SfuAuthFailure`).
3. **Deux appareils du même utilisateur** (Bastien sur Element Web + Noémie qui regarde) : membership distante avec le NOUEST userId → ce n'est pas un appel entrant ; et `memberships` multiples dans le même event → ne pas créer deux sessions. → test task 6.
4. **Glare** : appel sortant RTC vers une room pendant qu'une membership RTC distante y apparaît → un seul écran d'appel, l'entrant gagne si notre invite n'a pas encore publié de membership, sinon on ignore. → test task 3.
5. **App tuée en plein appel** : notre membership n'est plus rafraîchie ; à la reprise, si notre propre membership est expirée, ne PAS ressusciter l'appel (propre `ended`) ; et ne jamais laisser sonner le `VoipBridgeService` sans appel actif. → test task 3 (timer) + vérification terrain task 8.

---

### Task 1 : `RtcSfuClient` — focus, OpenID, JWT (spec §1 spike + §3.2)

**Files:**
- Create: `lib/utils/rtc/rtc_sfu_client.dart`
- Test: `test/rtc/rtc_sfu_client_test.dart`

**Interfaces:**
- Consumes : `Client` matrix-dart (existant) — pour HTTP authentifié utiliser la couche bas niveau `client.api.request`/équivalent `get` réel (vérifier dans `lib/matrix_api_lite/` au premier appel, sinon `client.httpClient` + `client.homeserver` ; l'endpoint existe, c'est un simple GET).
- Produit :
  - `class SfuCredentials { final String livekitUrl; final String jwt; }` (url = `wss://…` rendu par le service)
  - `class RtcSfuClient { RtcSfuClient(this._client); Future<List<RtcFocus>> discoverFoci(); Future<SfuCredentials> requestCredentials(String roomId); }`
  - `class RtcFocus { final String type; final String livekitServiceUrl; }` (`type == 'livekit'`)
  - exception `SfuAuthException` (une régénération max, gérée task 3).

- [ ] **Step 1 : test vert sur fixture réelle.** Écrire `test/rtc/rtc_sfu_client_test.dart` avec `MockClient`/`http` mocké (pattern déjà utilisé dans `test/` du projet — regarder un test existant qui mocke l'API avant d'inventer) : (a) `discoverFoci()` parse la réponse `.well-known` réelle du 15/10 : `{"m.homeserver":{"base_url":"https://matrix.sk7.sh"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://matrix-rtc.sk7.sh"}]}` → un focus livekit ; (b) bien-known sans `rtc_foci` → liste vide ; (c) `requestCredentials('!y2jT…')` : GET openid → `{"access_token":"oid","token_type":"Bearer","matrix_server_name":"matrix.sk7.sh","expires_in":3600}` puis POST `{focus}/sfu/get` avec le body exact du spike (clé `openid_token` = l'objet OpenID complet, `room`, `device_id`) → réponse `{"url":"wss://matrix-rtc.sk7.sh","jwt":"x"}` → `SfuCredentials('wss://matrix-rtc.sk7.sh','x')` ; vérifier que le JSON envoyé contient bien `openid_token.matrix_server_name` ; (d) réponse SFU `{"errcode":"M_UNKNOWN_TOKEN"}` → `SfuAuthException`.
- [ ] **Step 2 :** `flutter test test/rtc/rtc_sfu_client_test.dart` → échec « not defined ».
- [ ] **Step 3 : implémenter** `rtc_sfu_client.dart`. Discovery : GET `/.well-known/matrix/client` sur le homeserver courant (le SDK a `client.homeserver` et un http client — ne pas réinventer l'auth, réutiliser la session). openid : `GET /_matrix/client/v3/user/{urlEncode(userId)}/openid/request_token`. Device id : `client.deviceID`. Logs `.w` prefixés `[RTC]` sur chaque étape SANS secrets.
- [ ] **Step 4 :** `flutter test test/rtc/` → tout vert.
- [ ] **Step 5 : commit** `feat(rtc): client SFU (well-known foci, OpenID, JWT /sfu/get)` avec les tests.

### Task 2 : `RtcMembership` — parse/serialize des events de présence (spec §3.1)

**Files:**
- Create: `lib/utils/rtc/rtc_membership.dart`
- Test: `test/rtc/rtc_membership_test.dart`

**Interfaces:**
- Consumes : rien du task 1.
- Produit :
  - `class RtcSessionMembership { userId, deviceId, callId /* "" en 1:1 */, application /* "m.call" */, expiresMs /* durée relative */, List<RtcFocus> fociPreferred, membershipId, DateTime originServerTs }` avec `bool isExpiredAt(DateTime now)` et `bool get isImplicitRoomCall => callId.isEmpty && application == 'm.call'`.
  - `List<RtcSessionMembership> parseMembershipEvent(Map content, String sender, DateTime originServerTs)` — accepte les DEUX formes : tableau `{"calls":[…]}` et objet plat SessionMembershipData ; retourne `[]` sur contenu invalide (review-focus 1).
  - `Map<String, Object?> buildMembershipContent(RtcSessionMembership m)` — produit la forme lisible par Element ; le champ `expires` est RELATIF en ms, `membershipID` regénéré à chaque build.
  - const `rtcMembershipEventType = 'org.matrix.msc3401.call.member'` (+ préfixe `org.matrix.msc4143.rtc.member` toléré en parse par `parseMembershipEvent` — ignorer proprement le contenu sticky, review-focus).

- [ ] **Step 1 : tests.** fixtures : (a) forme `{"calls":[{…}]}` complète avec `expires: 3600000` → 1 membre, `isExpiredAt` faux à t0, vrai à t0+2h ; (b) forme plate ; (c) contenu `{}` / `{"calls":"pasuneListe"}` / event sticky 4143 → `[]` ; (d) `buildMembershipContent` → re-parse identique (round-trip), `expires` est un nombre relatif, `membershipID` diffère entre deux builds ; (e) multi-membres dans un event (2 devices même user) → 2 entrées.
- [ ] **Step 2 :** Run `flutter test test/rtc/rtc_membership_test.dart` → FAIL.
- [ ] **Step 3 : implémenter.** Parsing défensif total : chaque champ via `.tryGet…`/casts sûrs, jamais de `!` sur le contenu distant (la room peut recevoir n'importe quoi).
- [ ] **Step 4 : tout vert.**
- [ ] **Step 5 : commit** `feat(rtc): parsing/sérialisation des memberships MSC3401`.

### Task 3 : `RtcCall` — machine à états d'un appel (spec §3.3)

**Files:**
- Create: `lib/utils/rtc/rtc_call.dart`
- Test: `test/rtc/rtc_call_test.dart`

**Interfaces:**
- Consumes : `RtcSfuClient` (task 1), `RtcSessionMembership`/`parseMembershipEvent` (task 2).
- Produit :
  - abstraction `abstract class RtcMediaGateway { Future<void> connect(SfuCredentials c); Future<void> startMedia({bool audio, bool video}); Future<void> publish(); Stream<RtcRemoteEvent> get remoteEvents; Future<void> dispose(); … }` — implémentation livekit réelle au task 5 ; FAKE dans les tests de ce task. `RtcRemoteEvent` = enum-ish : `peerJoined, peerLeft, mediaReady, failed`.
  - `class RtcCall { RtcCall({required Room room, required bool wantVideo, RtcSfuClient?, RtcMediaGateway?, now}); CallState state; Stream<CallState> onStateChanged; Future<void> start(); Future<void> accept(); Future<void> hangup(); void onRemoteMembership(RtcSessionMembership m); }` avec `enum CallState { idle, connecting, ringingOut, active, ringingIn, ended, failed }` (ne PAS réutiliser l'enum du legacy — module autonome).
  - Règles : `start()` = credentials → connect → publish → publier membership (état `ringingOut`) ; `accept()` = idem puis `active` dès première `mediaReady` ; `onRemoteMembership` depuis un autre user, appel inactif → `ringingIn` (détection entrant) ; depuis NOUS (même userId, autre deviceId) → ignoré ; glare (review-focus 4) : `ringingOut` + membership distante → `active` (on garde le sortant) SAUF si notre membership n'a pas encore été publiée (`connecting`) → `hangup()` et laisser l'entrant ; expiration : timer de refresh à `expiresMs/2` (fake `now` injectable), `failed` si SFU renvoie `SfuAuthException` après UNE régénération (review-focus 2) ; `ended` propre = gateway.dispose + effacement de notre membership.

- [ ] **Step 1 : tests** avec gateway et client mockés + horloge fake : sortir→`ringingOut` puis membership distante→`active` ; entrant→`ringingIn`→`accept()`→`active` ; hangup → membership effacée + gateway disposed ; refresh au demi-passage de `expires` (2 ticks) ; `SfuAuthException` → retry unique puis `failed` (compter les appels gateway) ; glare (a) et (b) ; membership de notre propre userId → aucun changement d'état ; contenu invalide jamais reçu ici (task 2 filtre) — tester quand même `onRemoteMembership` avec `isExpiredAt==true` → ignoré.
- [ ] **Step 2 :** FAIL attendu.
- [ ] **Step 3 : implémenter.** Pas de Timer directs : `now` et une file de callbacks planifiés injectables pour la testabilité (pattern `fakeAsync` ou horloge à la main).
- [ ] **Step 4 :** verts + `flutter test test/rtc/` entier vert.
- [ ] **Step 5 : commit** `feat(rtc): machine à états RtcCall (entrant/sortant/expiration/glare)`.

### Task 4 : `RtcE2ee` — passkey et to-device `io.element.call.encryption_keys` (spec §5)

**Files:**
- Create: `lib/utils/rtc/rtc_e2ee.dart`
- Test: `test/rtc/rtc_e2ee_test.dart`

**Interfaces:**
- Consumes : `Client.sendToDevice` / `sendToDeviceEncrypted` (SDK existant, signature à vérifier dans `lib/src/client.dart:3609+`).
- Produit : `class RtcE2ee { RtcE2ee({required Client client, required String roomId, required String callId, …}); Uint8List get passkey; Future<void> shareWithDevice(String userId, String deviceId); void handleIncomingKeys(Map content); Stream<Uint8List> get onKey; }`. Event type constant `rtcE2eeEventType = 'io.element.call.encryption_keys'`, contenu `{call_id, keys: [{index, key(base64)}]}` (schéma du `EncryptionKeysEventContent` js-sdk — vérifier en M1 sur le vrai event reçu, fixture de test = ce schéma). Si M1 observe un autre schéma : ajuster ici et dans la spec.

- [ ] **Step 1 : tests** : share → `sendToDevice` appelé avec le bon type + `call_id` + clé base64 décodable ; `handleIncomingKeys` → `onKey` émet la clé décodée ; event avec `call_id` d'un autre appel → ignoré ; jamais de log du contenu (tester via un log collector).
- [ ] **Step 2 :** FAIL.
- [ ] **Step 3 : implémenter** (clé = `Random.secure` 32 octets par appel).
- [ ] **Step 4 : verts.**
- [ ] **Step 5 : commit** `feat(rtc): échange de clés médias e2ee`.

### Task 5 : gateway livekit réel + `LiveKitCallController` (UI sans retouche de page)

**Files:**
- Create: `lib/utils/rtc/livekit_gateway.dart` (implémente `RtcMediaGateway` avec `Room`)
- Create: `lib/pages/call/livekit_call_controller.dart` (implémente `CallController` de `active_call_page.dart`)
- Test: `test/pages/call/livekit_call_page_test.dart`

**Interfaces:**
- Consumes : `RtcCall` (task 3), `RtcE2ee` (task 4), `livekit_client` (`Room().connect(url, token)` ; `localParticipant.setMicrophoneEnabled(true, audioCaptureOptions)` / `setCameraEnabled` ; événements `room.events` de type `TrackSubscribedEvent`/`ParticipantDisconnectedEvent` (noms vus dans `src/events.dart`) ; rendu : widget `VideoTrackRenderer` (`src/widgets/video_track_renderer.dart`) ; e2ee : `room.e2eeManager`).
- Produit : `LiveKitCallController extends CallController { LiveKitCallController(this._call); … }` — `micMuted/cameraOff/speakerOn/…` branchés sur les setters livekit (`setMicrophoneEnabled(false)` = mute réel côté LiveKit, pas de bug de flag SDK vu en legacy) ; `remoteName/remoteMxid` depuis la room/le pair ; widgets vidéo fournis par la page via nouveaux getters `Widget? remoteVideoWidget()/localVideoWidget()` OU passage en paramètres — CHOISIR : mêmes slots `remoteVideo`/`localVideo` d'`ActiveCallPage` (déjà prévue pour), la page reste inchangée ; `localStream/remoteStream` → `null`.

- [ ] **Step 1 : test widget** : instancier `ActiveCallPage(controller: FakeRtcCallController())` où le fake pilote un `RtcCall` sur gateway factice → icônes mute basculent (réutiliser les helpers des tests existants `test/pages/call/active_call_page_test.dart`), `toggleSpeaker` appelle le `VoipBridge` (mock MethodChannel, même pattern que `voip_bridge_test.dart`).
- [ ] **Step 2 :** FAIL.
- [ ] **Step 3 : implémenter gateway + controller.** Le gateway garde la Room privée ; `publish()` = `setMicrophoneEnabled(true)` (+ caméra si vidéo, facing `user`) ; mute = `setMicrophoneEnabled(false)` / `setCameraEnabled(false)` ; le flux `remoteEvents` traduit les events livekit ; câbler `RtcE2ee.onKey` (task 4) vers `room.e2eeManager` et inversement les keys entrantes livekit → rien (réception = `handleIncomingKeys` appelé par `RtcService`, task 6, sur le stream to-device).
- [ ] **Step 4 :** `flutter test test/pages/call/ test/rtc/` tous verts (les 44 + nouveaux). `flutter analyze` propre.
- [ ] **Step 5 : commit** `feat(rtc): passerelle LiveKit et contrôleur d'appel pour l'UI existante`.

### Task 6 : détection entrant + branchement des écrans (spec §3.3, §4)

**Files:**
- Create: `lib/utils/rtc/rtc_service.dart` (singleton par session, créé à côté du `VoIP` dans `MatrixState`/`widgets/matrix.dart`)
- Modify: `lib/utils/voip_plugin.dart` (ou l'endroit où `voip` est instancié — grep `VoIP(` dans `lib/`) pour démarrer `RtcService`
- Modify: `lib/pages/chat/chat.dart` (bouton appel : à côté du sélecteur audio/vidéo existant, option « nouveau protocole » affichée seulement quand `RtcService.rtcAvailable(room)` ; défaut = legacy, mémorisé par room via `AppSettings`, clé `settingKeys.rtcProtocolByRoom` à créer dans `lib/config/setting_keys.dart` — spec §4)
- Test: `test/rtc/rtc_service_test.dart`

**Interfaces:**
- Consumes : `client.onRoomState` (existant, même stream que `voip.dart`), `parseMembershipEvent` (task 2), `RtcCall` (task 3), écrans existants `IncomingCallPage` + `ActiveCallPage`.
- Produit : `class RtcService { static RtcService of(BuildContext)…; Future<bool> rtcAvailable(Room room); Stream<RtcCall> get onIncoming; RtcCall? currentCall; RtcCall callRoom(Room r, {bool video}); }`. L'entrant ouvre `IncomingCallPage` (route existante, même wake-screen + sonnerie natifs que legacy : réutiliser les appels `VoipBridge` déjà faits par `voip_plugin`).

- [ ] **Step 1 : tests** : (a) membership distante valide dans une DM rejointe, pas d'appel actif → `onIncoming` émet (review-focus 3 : 2 members du MÊME userId → un seul `onIncoming`, et les events du NOUEST user → zéro ; (b) redaction/`calls: []` du pair pendant `active` → `ended` ; (c) legacy `m.call.invite` non touché (aucun test nouveau requis, vérifier que les 44 tests passés passent — non-régression) ; (d) `rtcAvailable` false sans `rtc_foci` dans le well-known (mock task 1).
- [ ] **Step 2 : FAIL.**
- [ ] **Step 3 : implémenter** watcher + branchement `chat.dart` + préférence par room. Journal des missed calls : brancher `missed_call_store` (existant) avec `source: 'rtc'`. Côté Hermes (hors repo) : le champ `source` du webhook accepte déjà des valeurs libres — vérifier au M2 que `vox-inbox.py` classe bien `rtc` et l'ajouter à la liste des entrants à répondre si absent.
- [ ] **Step 4 : tous verts.**
- [ ] **Step 5 : commit** `feat(rtc): service, détection d'appel entrant et branchement UI`.

### Task 7 : mode observation M1 + build installable

**Files:**
- Modify: `lib/utils/rtc/rtc_service.dart` (logge en `.w [RTC-RAW]` TOUT event de type membership/to-device `io.element.call.encryption_keys` reçus, contenus tronqués à 400 car, secrets masqués — regex jeton/clé)
- No new tests (observabilité pure, déjà couverte par les tests d'état)

- [ ] **Step 1 :** ajouter le logging raw + `flutter test` vert + `flutter analyze` propre.
- [ ] **Step 2 :** `flutter build apk --release`, `scp` vers control-01 `/tmp/opencode/vox/`, `sha256sum` comparé (procédure fiche projet), `adb install -r -d` sur `mustang`, relancer la capture logcat `[VOIP|RTC]` (`/tmp/opencode/vox/cap-rtc.log`).
- [ ] **Step 3 : commit** `feat(rtc): journal d'observation brut pour le calibrage M1`.

### Task 8 : validation terrain M1→M5 (Bastien requis)

- [ ] **M1** : demander à Bastien de faire appeler VOX par Noémie (Element X). Lire `cap-rtc.log` : forme réelle des memberships, events e2ee oui/non → consigner les verdicts dans la spec (section amendements) + fiche mémoire ; ajuster task 2/4 si écart.
- [ ] **M2** : appel sortant audio VOX→Noémie, Noémie décroche, bi-directionnel (+ micro coupé : elle n'entend PLUS — contrôle du fix mute).
- [ ] **M3** : entrant app ouverte ET app swipée ; raccrocher dans les deux sens ; missed call listé.
- [ ] **M4** : réseau coupé 15 s en cours d'appel → reprise ; appel de Noémie pendant un appel legacy → pas de double sonnerie.
- [ ] **M5** : vidéo aller-retour, bascule caméra ; suite de tests complète + APK release final ; mise à jour des fiches mémoire (`project_vox.md`, `project_matrix_rtc_20261014.md`).
- [ ] Demander explicitement le feu vert `git push gitea main` avant toute poussée.
