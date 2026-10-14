# VOX — VoIP 1:1 audio + vidéo (design)

Date : 2026-10-14
Statut : approuvé — autonomie totale accordée par Bastien
Périmètre : appels 1:1 Matrix (audio + vidéo), app swipée = sonne quand même, UI neuve aux couleurs VOX
Hors périmètre : appels de groupe, E2EE des appels, MatrixRTC/LiveKit

---

## 1. Point de départ — ce qui existe déjà

Le VoIP de FluffyChat est **présent dans le fork mais non branché**. Relevé vérifié sur edge-01 :

- `lib/utils/voip_plugin.dart` (195 l.) — greffé dans `widgets/matrix.dart`, wake screen + foreground task à l'appel entrant
- `lib/pages/dialer/dialer.dart` (642 l.) — contient le widget `Calling`, l'écran d'appel en cours. **Personne ne l'ouvre** : aucun appelant dans le code.
- `lib/pages/dialer/incoming_call_view.dart` (786 l.) — écran d'appel entrant. Non utilisé.
- `lib/utils/voip/user_media_manager.dart`, `video_renderer.dart` — rendus caméra
- Sortant déjà câblé : `lib/pages/chat/chat.dart:1493` → `voipPlugin.voip.inviteToCall(room, callType)`, avec sélecteur audio/vidéo
- `flutter_webrtc 1.3.1` dans `pubspec.lock`, compilé (APK debug = 311 Mo)
- SDK = `matrix-dart-sdk v6.2.0` patché localement (`../matrix-dart-sdk-patched`), **pas** le Rust SDK. Tout le signaling `m.call.*` est disponible.
- Pattern natif Kotlin ↔ Dart déjà établi : `SmsBridge.kt` ↔ `sms_bridge.dart`, `WearBridge.kt` ↔ `wear_bridge.dart`

**Trois trous qui cassent l'appel entrant :**

1. `voip_plugin.dart:170` `registerListeners` — stub. L'upstream avait supprimé CallKeep sans le remplacer ; tout appel entrant meurt ici avant d'atteindre `handleNewCall`.
2. `voip_plugin.dart:152` `handleMissedCall` — `TODO`, jamais implémenté.
3. `voip_plugin.dart:180` `keyProvider` — `throw UnimplementedError()`. Plantage sur tout appel proposant un chiffrement.

## 2. État de l'infra serveur — déjà prête, rien à installer

Vérifié le 2026-10-14 sur le TrueNAS (10.8.0.101) :

- `TUWUNEL_TURN_URIS=["turn:turn.sk7.sh:3478?transport=udp","turns:turn.sk7.sh:5349?transport=tcp"]`
- `TUWUNEL_TURN_SECRET` présent → le SDK obtient les credentials TURN via `/_matrix/client/v3/voip/turnServer`
- `turn.sk7.sh:3478` **ouvert**
- `turn.sk7.sh:5349` (TURNS/TLS) **fermé** → à ouvrir seulement si les appels échouent sur réseau strict
- `matrix-rtc.sk7.sh` répond 200 (LiveKit) →将来 pour les groupes, hors périmètre

**Conclusion : tout le travail est côté application Android.**

## 3. Contrainte structurante — pas de push

VOX n'embarque **pas** de push FCM : le bloc est neutralisé par le flag de build `//<GOOGLE_SERVICES>` dans `lib/utils/background_push.dart`, et `FcmPushService.kt` n'est alimenté par aucun token.

Conséquence : un `m.call.invite` n'atteint VOX que si **le process Dart tourne**. D'où la décision : un **service foreground permanent démarré au boot** (`RECEIVE_BOOT_COMPLETED` est déjà dans le manifest), pas un service lancé à l'appel comme aujourd'hui (`dialer.dart:299`).

Risques assumés : consommation batterie, comportement à valider sur GrapheneOS, et la mort du process en cas de *force-stop* explicite.

## 4. Architecture

Quatre couches. **Deux sont déjà faites et ne sont pas touchées** (signalisation SDK, transport `flutter_webrtc`). Deux sont neuves.

### Couche 1 — Signalisation (inchangée)
`matrix-dart-sdk-patched`, events `m.call.invite` / `answer` / `hangup` / `select_answer_mode`. Négociation ICE et TURN gérée par le SDK.

### Couche 2 — Transport média (inchangée)
`flutter_webrtc`. `applyConstraints` est fourni mais jamais appelé → à câbler depuis la couche 3.

### Couche 3 — Pont Kotlin ↔ Dart (nouveau)
`android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBridge.kt`, calqué sur `SmsBridge.kt`. Couvre ce qu'Android n'autorise pas au Dart :

| Dart → Kotlin | Rôle |
|---|---|
| `startPersistentService` / `stopPersistentService` | service foreground permanent + boot receiver |
| `setAudioRoute(route)` | haut-parleur / écouteur / Bluetooth (A2DP + SCO) |
| `acquireAudioFocus()` | silence la musique pendant l'appel |
| `startRinging` / `stopRinging` | sonnerie canal audio + vibration |
| `requestCallPermissions()` | RECORD_AUDIO + CAMERA à chaud |

| Kotlin → Dart | Rôle |
|---|---|
| `onIncomingCall` | `m.call.invite` reçu, process vivant |
| `onCallAnswered` / `onCallEnded` | transitions |
| `onAudioRouteChanged` | bascule Bluetooth perdue/reprise |
| `onServiceKilled` | Android a tué le service → le Dart doit le savoir |

### Couche 4 — UI (nouveau)
`lib/pages/call/` : `incoming_call_page.dart`, `active_call_page.dart`, `call_bar.dart` (barre flottante), `call_theme.dart` (palette cyber / liquid glass de VOX). Remplace intégralement `lib/pages/dialer/`, qui est supprimé une fois branché.

## 5. Flux

**Sortant** (déjà fonctionnel, à valider) : bouton appel → `showModalActionPopup` audio/vidéo → `inviteToCall` → ICE via TURN → WebRTC → `ActiveCallPage`.

**Entrant** (à construire) : le service permanent maintient le client connecté → le SDK reçoit `m.call.invite` → `VoipPlugin.handleNewCall` → `VoipBridge.startRinging` + notification full-screen → sonnerie → répondre/raccrocher → `handleCallEnded` → arrêt service d'appel, retour au service permanent.

**Écran éteint** : `wakeUpScreen()` + `USE_FULL_SCREEN_INTENT` (déjà au manifest) → l'écran d'appel entrant remonte par-dessus le lockscreen.

## 6. Permissions

Déjà déclarées dans le manifest : `RECORD_AUDIO`, `CAMERA`, `MODIFY_AUDIO_SETTINGS`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`, `USE_FULL_SCREEN_INTENT`, `WAKE_LOCK`. Il manque la **demande runtime** et le cas du refus (appel audio seul avec avertissement).

## 7. Cas limites

- Permission micro refusée → appel audio refusé, raison affichée. Permission caméra refusée → audio seul.
- Perte réseau pendant l'appel → bandeau « reconnexion… », puis fin d'appel après timeout ICE.
- Deuxième appel entrant pendant un appel en cours → « occupé », pas de file d'attente.
- App swipée en cours d'appel → le service tient, l'appel continue.
- Mode économie d'énergie Android → process tué, appel coupé. Documenté, pas corrigé.
- `keyProvider` → `null` : les pairs qui forcent l'E2EE des appels échoueront. Accepté pour le v1.

## 8. Tests

| Jalon | Contenu | Preuve |
|---|---|---|
| 1 | Les 3 trous Dart + squelette du pont Kotlin + service permanent au boot | APK compile, service visible dans `dumpsys`, survit au swipe |
| 2 | Sortant audio 1:1 | Appel vers Element Web, audio bidirectionnel |
| 3 | Entrant, app au premier plan | Élément appelle VOX, l'écran s'affiche |
| 4 | Entrant, app swipée / écran éteint | Sonnerie + full-screen intent au-dessus du lockscreen |
| 5 | Vidéo | Self-view + remote view, bascule caméra avant/arrière |
| 6 | Audio & finitions | Bluetooth, écouteurs filaires, haut-parleur, appel manqué, barre flottante |

Référence de test : vieux téléphone avec Element (pilote humain), Element Web en complément.

## 9. Décisions prises

- VoIP legacy `m.call.*` plutôt que MatrixRTC/LiveKit — interop avec tous les clients, code déjà là.
- UI entièrement neuve, pas de re-skin de l'existant.
- Rebase upstream : aucun souci, pas d'isolation forcée du dossier.
- Pas de push FCM introduit — le service permanent suffit.