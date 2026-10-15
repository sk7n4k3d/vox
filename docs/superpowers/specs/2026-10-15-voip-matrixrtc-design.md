# VOX — appels MatrixRTC 1:1 (design)

Date : 2026-10-15
Statut : en relecture — design validé en conversation par Bastien le 15/10 (« ok ma poule »)
Périmètre : appels 1:1 MatrixRTC (audio + vidéo) entre VOX et les clients Element X / Element Web, média relayé par le LiveKit `matrix-rtc.sk7.sh` ; coexistence avec le VoIP legacy `m.call.*`
Hors périmètre : appels de groupe, notifications push dédiées « appel entrant » (v1 = détection au réveil de l'app), bascule automatique de protocole, vidéo sur la montre

---

## 1. Point de départ — faits vérifiés (15/10), pas des suppositions

- **Infra prête et éprouvée** : `matrix-rtc.sk7.sh` = LiveKit SFU + `lk-jwt-service` (conteneurs podman du VPS, cf. [[project_matrix_rtc_20261014]]). `.well-known` du homeserver sert bien `org.matrix.msc4143.rtc_foci = [{type: livekit, livekit_service_url: https://matrix-rtc.sk7.sh}]` (vérifié par curl le 15/10). Tuwunel expose `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` (chemin unstable seulement).
- **Spike auth réussi (15/10, reproduit 2 fois)** : la voie « session mot de passe » est vivante malgré la migration OIDC d'Element. Séquence exacte testée en réel :
  1. `POST /_matrix/client/v3/login` (mot de passe) → `access_token`
  2. `POST /_matrix/client/v3/user/{uid}/openid/request_token` → token OpenID (`matrix_server_name`, `expires_in`)
  3. `POST https://matrix-rtc.sk7.sh/sfu/get` avec le body legacy (cf. §3.2) → **`{"url": "wss://matrix-rtc.sk7.sh", "jwt": ...}`**, JWT avec `video.canPublish` + `canSubscribe`, room = `fvad/<hash de roomId>`, identité `sub = <user>:<device_id>`.
  - Appareil de test supprimé après chaque essai. Le device_id du JWT est celui de la session qui a demandé le token OpenID — la présence Matrix et le JWT doivent venir de la MÊME session sinon Element ignore le flux.
- **`livekit_client` 2.13.1** est dans `pubspec.yaml` ; la version résolue du lock **dépend de `flutter_webrtc: 1.6.2+hotfix.4`** — exactement la version déjà compilée dans l'APK (commentation du pubspec : « avoid version conflicts between WebRTC-SDK pods »). Pas de second fork natif WebRTC : les deux piles partagent la même lib (l'APK du 15/10 ne contient qu'une `libjingle_peerconnection_so.so`). **Zéro risque de cohabitation.**
- **`livekit_client` sait chiffrer** : `lib/src/e2ee/` (E2EEManager, KeyProvider) présent dans le package (lu dans les sources du pub cache le 15/10).
- **Le mécanisme MSC3401 du SDK patché est dans un dialecte INCOMPATIBLE** : `EventTypes.GroupCallMember = 'com.famedly.call.member'`, contenu `{'memberships': [...]}` avec `expires_ts`/`foci_active` (`lib/src/voip/models/call_membership.dart`). Element X publie `org.matrix.msc3401.call.member` — preuve dans les logs VOX du 15/10 : `Ignoring call event org.matrix.msc3401.call.member for room !y2jT1plx…` (l'appel de Noémie). Le backend `LiveKitBackend` du SDK ne fait que la gestion de clés e2ee + events Matrix ; toutes ses méthodes média lèvent `UnimplementedError('Use livekit sdk for this')`.
- **L'UI d'appel est déjà découplée** : `ActiveCallPage` ne connaît que l'interface `CallController` (`lib/pages/call/active_call_page.dart:15`) et reçoit ses rendus vidéo en widgets (`remoteVideo`/`localVideo`). Le `VoipCallController` legacy reste le seul implémenteur. Un second pilote RTC se branche sans retoucher la page.
- **Le pont natif est réutilisable** : `VoipBridge.kt` (service foreground `specialUse`, routage audio, sonnerie, capteur de proximité, relance au boot) ne dépend pas du protocole.

## 2. Décision d'architecture

**Module RTC dans l'app** (`lib/utils/rtc/` + contrôleur), le SDK ne servant que de brique HTTP/crypto existante. Alternatives écartées :

1. *Patcher le SDK pour parler le dialecte standard* — écarté : le SDK devrait aussi porter la pile média LiveKit qu'il délègue volontairement au client (« Use livekit sdk for this ») ; un fork du SDK s'éloigne d'upstream à chaque release FluffyChat.
2. *Bridge serveur « legacy transfer bot »* — écarté : média qui traverse deux fois, composant serveur de plus à maintenir, et ne règle pas les appels sortants depuis VOX.

Conséquence : **coexistence** des deux protocoles (décision du 15/10), l'ancien `m.call.*` gardant Alice/werift et Element Web en legacy.

## 3. Le protocole — ce qu'on envoie et ce qu'on lit

### 3.1 Noms d'events (sources officielles, relevés 15/10 dans matrix-js-sdk develop)

| Rôle | Type | Forme |
|---|---|---|
| Présence dans l'appel (legacy, **ce que publie Element X**) | state `org.matrix.msc3401.call.member` | contenu `SessionMembershipData` (voir ci-dessous) |
| Présence sticky (récente) | state `org.matrix.msc4143.rtc.member` | à tolérer en LECTURE seulement, pas de production en v1 |
| Objet appel explicite (groupes) | state `org.matrix.msc3401.call` | **non requis en 1:1** : appel implicite, `call_id = ""` |
| Clés e2ee média | to-device `io.element.call.encryption_keys` | `{call_id, keys: [{index, key}]}` + variante request |
| Ring ciblé | to-device `org.matrix.msc4075.call.notify` | hors v1 (on détecte par membership) |

Contenu `SessionMembershipData` attendu (forme exacte **calibrée par le jalon M1**, c'est-à-dire en écoutant un vrai appel de Noémie) : au niveau du state event, `device_id`, `application: "m.call"`, `call_id: ""`, `scope: "m.room"`, `expires` (durée en millisecondes à partir de `origin_server_ts`, pas un timestamp absolu), `foci_preferred: [{type: "livekit", livekit_service_url}]`, `membershipID` (cache-buster aléatoire, régénéré à chaque envoi) ; et l'ancienne forme à tableau `{"calls": [ …mêmes champs… ]}`. Le parseur accepte les deux ; le sérialiseur écrit la forme que M1 aura vue sortir d'Element X.

### 3.2 Réserver sa place sur le SFU (prouvé en spike)

```
POST {livekit_service_url}/sfu/get
{
  "room": "<room_id>",
  "device_id": "<device_id de CETTE session>",
  "openid_token": {
    "access_token": "<token OpenID>",
    "token_type": "Bearer",
    "matrix_server_name": "<nom du homeserver>",
    "expires_in": <secondes>
  }
}
→ {"url": "wss://matrix-rtc.sk7.sh", "jwt": "<JWT LiveKit>"}
```

Puis `Room().connect(url, jwt)`. Le nom de la room LiveKit (hash `fvad/…`) est porté par le JWT : le client ne le choisit pas.

### 3.3 Cycle de vie d'un appel

- **Sortant** : choix du protocole (voir §4) → `/sfu/get` → `connect` → publier micro (+ caméra si vidéo, l'appelant publie dès la connexion) → publier sa membership → état « sonne ». L'appel est établi quand la membership distante apparaît.
- **Entrant** : dans une DM rejointe, une membership distante nouvelle (non expirée, pas nous) ⇒ écran d'appel entrant (ring natif via `VoipBridge`). Décrocher = `/sfu/get` + `connect` + souscription + notre membership. Refuser = rien publier + tracer dans `missed_call_store`.
- **Accrocher** : `disconnect` LiveKit, effacer notre presence (event `calls: []` / champ session absent), stopper la route audio.
- **Expiration** : refresh de notre membership avant 50 % de sa durée de vie ; si une membership distante expire sans se renouveler (client tué), l'appel distant est considéré perdu après 2 cycles → fin d'appel propre.
- **Erreurs** : `/sfu/get` en 401 → relancer le flow OpenID une fois (token expiré) ; connexion LiveKit en échec → message + retour écran conversation ; perte réseau en cours d'appel → reconnexion LiveKit automatique (la lib le fait), membership rafraîchie au retour ; si l'autre côté a disparu depuis > 1 cycle → fin d'appel avec « appel interrompu ».

## 4. Choix du protocole et UI

- Le sélecteur existe déjà pour l'appel sortant (audio/vidéo). On ajoute un troisième plan : ** RTC / legacy **. Par défaut = legacy ; la préférence est mémorisée par room (`AppSettings`, clé par `roomId`) ; après un appel réussi, VOX propose silencieusement de retenir le protocole utilisé.
- **Entrant** : pas de choix à faire, on suit le protocole de l'event reçu (`m.call.invite` → écran legacy existant ; membership RTC → écran RTC).
- Les deux écrans existants (`incoming_call_page.dart`, `active_call_page.dart`) sont conservés : `ActiveCallPage` reçoit un `CallController` et des widgets vidéo — le pilote RTC fournit ses propres `VideoView` livekit, le legacy ses `RTCVideoRenderer` actuels. Les champs `localStream`/`remoteStream` (type WrappedMediaStream) restent nullables et non utilisés par la page côté RTC.
- Journal d'appels/webhook : la source `rtc` rejoint `call|sms|mms|matrix` côté Hermes — même pipe, champ source à ajouter (petit correctif `vox-inbox.py`, hors repo VOX).

## 5. Chiffrement de bout en bout

- `livekit_client` embarque KeyProvider/E2EEManager. VOX génère une clé aléatoire par appel (passkey), la partage via `io.element.call.encryption_keys` (to-device, chiffré Olm si la room l'est — le DM de Noémie l'est), et l'injecte dans le KeyProvider pour envoyer ET recevoir.
- **Inconnue à trancher en M1** : est-ce que `livekit.yaml` du VPS a `e2ee.enabled: true` (pas de SSH sur le VPS depuis control-01 — vérifié : permission refusée ; et le service JWT n'expose pas ce flag). Plan : M1 écoute les to-device `io.element.call.encryption_keys` pendant un appel de Noémie → s'il y en a, e2ee obligatoire (Element X l'exige), sinon flux clair (SRTP hop-par-hop seulement) et le module garde le chiffrement en option désactivée. Comportement Element X avec SFU non-e2ee = vérification terrain M1, pas une supposition.
- Clés média jamais persistées sur disque ; purge mémoire à la fin de l'appel.

## 6. Fichiers touchés

| Fichier | Rôle |
|---|---|
| `lib/utils/rtc/rtc_call.dart` (nouveau) | machine à états d'un appel RTC : SFU, Room livekit, membership, timers d'expiration |
| `lib/utils/rtc/rtc_membership.dart` (nouveau) | parse/sérialisation `org.matrix.msc3401.call.member` (2 formes) + refresh |
| `lib/utils/rtc/livekit_call_controller.dart` (nouveau) | implémente `CallController` pour `ActiveCallPage` ; rendus livekit |
| `lib/utils/rtc/rtc_e2ee.dart` (nouveau) | passkey + events `io.element.call.encryption_keys` ↔ KeyProvider |
| `lib/utils/rtc/rtc_incoming_watcher.dart` (nouveau) | écoute `client.onRoomState` (DM rejointes) → `IncomingCallPage` |
| `lib/pages/chat/chat.dart` | entrée d'appel : choix protocole + branchement |
| `lib/config/setting_keys.dart` | clé préférence protocole par room |
| `lib/pages/call/*` | au besoin uniquement (la page est déjà protocol-agnostique) |
| SDK patché : **aucune modification prévue** (les briques HTTP/to-device existent côté `Client`) |

## 7. Tests

- **Unitaires (test/pages + test/rtc)** : parse/sérial des 2 formes de membership ; expiration/refresh (horloge fake) ; machine à états `RtcCall` avec `Room` factice (mêmes principes que les FakeCallController de la page) ; corps de requête `/sfu/get` (fixture du spike) ; event e2ee aller/retour.
- **Non-régression** : suite existante `test/pages/call/` (44 tests) doit rester verte — l'interface `CallController` ne change pas de signature.
- **E2E terrain (Bastien)** : M1 appel de Noémie reçu et journalisé ; M2 audio VOX→Noémie ; M3 appel entrant + raccrocher des deux côtés ; M5 vidéo aller-retour ; Alice (legacy) continue d'appeler sans rien changer.
- `flutter analyze` sans nouveau diagnostic (5 infos préexistantes tolérées).

## 8. Jalons

1. **M1 — observation** : module d'écoute passif ; Noémie appelle → journalisation brute (state events + to-device + présence/absence de clés e2ee). Sortie : calage exact du §3.1 et du §5, consigné dans la fiche mémoire.
2. **M2 — sortant audio** : `/sfu/get` + connect + publish + membership ; Noémie décroche depuis Element X. APK de validation.
3. **M3 — entrant** : détection membership → `IncomingCallPage` → décrochage LiveKit ; hangup propre dans les deux sens ; missed calls.
4. **M4 — e2ee + robustesse** : chiffrement selon verdict M1 ; refresh/expiration ; perte réseau ; hardening (taille des events, timeouts).
5. **M5 — vidéo + finition** : caméra avant/arrière (pattern `facingMode` du legacy existe), sélecteur protocole mémorisé, tests verts, APK release + note mémoire.

## 9. Hypothèses explicites (modifiables par Bastien)

- Coexistence, pas remplacement (l'ancien protocole garde Alice).
- 1:1 seulement ; le legacy reste le choix par défaut d'un appel sortant.
- En v1, un appel entrant réveille l'app mais ne « sonne » pas si l'app est totalement fermée sans push dédié — la détection se fait au prochain sync. (Amélioration push ensuite : règle serveur sur l'event membership.)
- Le DM avec Noémie reste chiffré (Olm) pour les events ; les médias suivent le §5.
