# VoIP 1:1 audio + vidéo — Plan d'implémentation

**Goal :** rendre les appels 1:1 Matrix (audio + vidéo) fonctionnels dans VOX, y compris quand l'app est swipée, avec une UI neuve aux couleurs VOX.

**Architecture :** on réveille le VoIP legacy `m.call.*` déjà présent dans le fork (SDK Dart + `flutter_webrtc` compilés) au lieu d'écrire une nouvelle couche signalisation. Trois trous Dart sont branchés, un pont Kotlin↔Dart (`VoipBridge`, calqué sur `SmsBridge`) prend en charge ce qu'Android refuse au Dart (service permanent, routage audio, sonnerie), et une UI neuve `lib/pages/call/` remplace le dialer mort.

**Tech Stack :** Flutter 3.47.5 / Dart 3.13.4, `matrix-dart-sdk v6.2.0` patché (`../matrix-dart-sdk-patched`), `flutter_webrtc 1.3.1`, Kotlin Android, MethodChannel + EventChannel.

**Spec :** `docs/superpowers/specs/2026-10-14-voip-call-design.md`

---

## Global Constraints

- **Repo :** `~/Bureau/dev/Applications/fluffychat` sur **edge-01** (10.8.0.2). L'APK se **compile** sur edge-01, s'**installe** depuis control-01 via `adb`.
- **Homonymie assumée :** l'objet Kotlin `VoipBridge` (Task 2) et la classe Dart `VoipBridge` (Task 4) portent le même nom — c'est la convention du dépôt (`SmsBridge.kt` ↔ `sms_bridge.dart`), aucun conflit technique.
- Nom de canaux natifs : préfixe `eu.devlabz.vox/voip` (le SMS utilise `eu.devlabz.vox/sms`).
- Aucune dépendance Play Services (contrainte GrapheneOS).
- Les tests Dart tournent sur edge-01 : `flutter test`. **Il n'y a aucun test Kotlin** (`android/app/src/test/` vide, pas de `testImplementation`) → le code Kotlin se prouve par compilation + `adb shell dumpsys`, pas par test unitaire.
- L'API `m.call.*` et `flutter_webrtc` ne se modifient pas. Tout passe par les delegates `WebRTCDelegate` de `VoipPlugin`.
- Le push de VOX est **UnifiedPush/ntfy** (FCM volontairement désactivé), mais `push_helper.dart:122` se contente de filtrer l'affichage et ne démarre aucun appel. Le service permanent reste donc nécessaire : c'est lui qui garde le client connecté et fournit un contexte à `handleNewCall`.
- Domaine : tout ce qui est réseau s'écrit `sk7.sh`.

## Review Focus

Cinq défaillances qu'aucun test du plan ne couvre implicitement, mais qu'une personne qui utilise l'app rencontrera :

1. **Appel entrant pendant un appel déjà en cours** → attendu : « occupé », l'appel entrant est raccroché proprement. Pas de deux `IncomingCallPage` empilées, pas de fuite de session.
2. **Refus de la permission micro** → attendu : l'appel ne démarre pas et dit pourquoi, plutôt que de planter dans `flutter_webrtc`. Même chose pour la caméra refusée → repli audio seul.
3. **Bascule Bluetooth pendant l'appel** (casque qui se connecte après le début de l'appel) → attendu : le son suit, et si le Bluetooth tombe l'audio revient au haut-parleur sans couper l'appel.
4. **Perte réseau pendant l'appel** → attendu : bandeau « reconnexion… », et fin d'appel propre au timeout, pas une UI figée sur un écran d'appel mort.
5. **App swipée en cours d'appel** → attendu : l'appel continue, la notification persiste, revenir dans l'app affiche l'appel en cours — pas un écran d'appel entrant resurrected.

Chacune de ces lignes a son test ajouté dans la tâche qui possède le code concerné.

---

### Task 1 : Les trois trous Dart + journal des appels manqués

**Files:**
- Modify: `lib/utils/voip_plugin.dart` (lignes 148-180)
- Create: `lib/pages/call/missed_call_store.dart`
- Test: `test/pages/call/missed_call_store_test.dart`

**Interfaces:**
- Consumes: rien (premier jalon).
- Produces:
  - `class MissedCallStore` — ctor `MissedCallStore(AppSettings store)`, champs `List<MissedCall> get recent`, `void add(MissedCall)`, `void clear()`, et `MissedCall({required String callId, required String roomId, required String callerName, required bool video, required DateTime at})`.
  - `VoipPlugin.handleMissedCall(CallSession)` implémenté.
  - `VoipPlugin.keyProvider` renvoie `null` au lieu de `throw UnimplementedError()`.

- [ ] **Step 1 : Écrire le test qui échoue**

`test/pages/call/missed_call_store_test.dart` :

```dart
test('ajoute un appel manqué et le restitue du plus récent au plus ancien', () {
  final store = MissedCallStore(TestAppSettings());
  store.add(MissedCall(callId: 'a', roomId: 'r1', callerName: 'Alice',
      video: false, at: DateTime(2026, 10, 14, 10)));
  store.add(MissedCall(callId: 'b', roomId: 'r2', callerName: 'Bob',
      video: true, at: DateTime(2026, 10, 14, 11)));
  expect(store.recent.map((c) => c.callId), ['b', 'a']);
});

test('ne garde que les 50 derniers appels manqués', () { /* 51 ajouts -> length == 50 */ });

test('clear vide le journal', () { /* ... */ });
```

Vérifier l'instance de settings existante : si `test/utils/test_client.dart` ne fournit pas de double de `AppSettings`, utiliser un faux `AppSettings` réel avec valeurs par défaut plutôt qu'un mock.

- [ ] **Step 2 : Lancer le test, vérifier qu'il échoue**

Run: `cd ~/Bureau/dev/Applications/fluffychat && flutter test test/pages/call/missed_call_store_test.dart`
Expected: FAILED — `MissedCallStore` n'existe pas.

- [ ] **Step 3 : Implémenter `lib/pages/call/missed_call_store.dart`**

Classe pure au-dessus de la persistance `AppSettings` existante (même clé que `voip_plugin.dart:127` qui écrit déjà `wasForeground`). Liste triée décroissante par `at`, plafonnée à 50, sérialisée en JSON.

- [ ] **Step 4 : Brancher `handleMissedCall` et `keyProvider` dans `lib/utils/voip_plugin.dart`**

`handleMissedCall(session)` : lire `session.callId`, `session.roomId`, `session.isVideo` → `MissedCallStore.add(...)`. Remplacer `keyProvider => throw UnimplementedError()` par `keyProvider => null`.

Le refus de permission (**Review Focus n°2**) est traité en Task 8, pas ici : à ce stade les permissions ne sont pas encore demandées au runtime.

- [ ] **Step 5 : Relancer les tests**

Run: `flutter test test/pages/call/missed_call_store_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6 : Commit**

```bash
git add lib/pages/call/missed_call_store.dart lib/utils/voip_plugin.dart test/pages/call/missed_call_store_test.dart
git commit -m "fix(voip): branche handleMissedCall + keyProvider (les 2 trous qui tuaient l'appel entrant)"
```

---

### Task 2 : Service permanent Kotlin (survie au swipe + boot)

**Files:**
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBridge.kt`
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBridgeService.kt`
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBootReceiver.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: rien de Task 1 (indépendante).
- Produces: `object VoipBridge` avec
  - `const val CHANNEL_PERSISTENT = "voip_persistent"`, `const val CHANNEL_INCALL = "voip_incall"`
  - `fun startPersistent(context: Context)`, `fun stopPersistent(context: Context)`
  - `var onIncomingCall: ((Map<String, Any?>) -> Unit)?` — payload `{callId, roomId, callerName, video}`
  - `var onAudioRouteChanged: ((String) -> Unit)?` — `speaker` | `wired` | `bluetooth`

- [ ] **Step 1 : Créer `VoipBridge.kt` — objet singleton, aucun test unitaire possible**

Reprendre la docstring et la structure de `SmsBridge.kt` (mêmes conventions : `const val TAG = "VoipBridge"`, callbacks `@Volatile var ... : ((Map<String, Any?>) -> Unit)? = null`).

Trois responsabilités :
1. **Service permanent** : `startPersistent` crée un `Service` foreground notification non dismissible, canal `voip_persistent`, `START_STICKY`. Sur API 34+ le type est `specialUse` avec `android:foregroundServiceType="specialUse"` — **pas** `microphone`, qui exige un appel en cours.
2. **Routage audio** : `setAudioRoute(route)` via `AudioManager` — `MODE_IN_COMMUNICATION` + `setSpeakerphoneOn(true)` pour `speaker`, `startBluetoothSco()` pour `bluetooth`, `stopBluetoothSco()` sinon. Un `BroadcastReceiver` sur `AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED` + `BluetoothProfile.STATE_CONNECTED` repousse chaque changement via `onAudioRouteChanged` — c'est le **Review Focus n°3**.
3. **Sonnerie** : `startRinging()` sur `RingtoneManager` canal `voip_incall` + `Vibrator` motif `[500, 800, 500]`, `stopRinging()` idempotent.

- [ ] **Step 2 : Créer `VoipBootReceiver.kt`**

`BroadcastReceiver` sur `Intent.ACTION_BOOT_COMPLETED` **et** `Intent.ACTION_MY_PACKAGE_REPLACED`, qui appelle `VoipBridge.startPersistent(context)`. Sans ça, le service ne survit pas à un redémarrage du téléphone.

- [ ] **Step 3 : Modifier le manifest**

Ajouter au `<application>` : le `<service>` `foregroundServiceType="specialUse"` + la sous-balise `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="voip"/>`, le `<receiver android:exported="true" android:enabled="true">` pour `VoipBootReceiver` avec les deux intent-filters, et le `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>`.

`RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK`, `VIBRATE` et `FOREGROUND_SERVICE` sont **déjà** au manifest : ne pas les dupliquer.

- [ ] **Step 4 : Vérifier par compilation**

Run: `cd ~/Bureau/dev/Applications/fluffychat/android && ./gradlew :app:compileDebugKotlin`
Expected: `BUILD SUCCESSFUL`. Un manifest mal formé ne se voit qu'ici.

- [ ] **Step 5 : Vérifier par le manifest fusionné**

Run: `grep -A 4 "VoipBridgeService" build/app/intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml`
Expected: service avec `foregroundServiceType="specialUse"` + `<property ... PROPERTY_SPECIAL_USE_FGS_SUBTYPE>`, receiver présent, `FOREGROUND_SERVICE_SPECIAL_USE` dans les permissions.

- [ ] **Step 6 : Commit**

```bash
git add android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/ android/app/src/main/AndroidManifest.xml
git commit -m "feat(voip): service permanent + boot receiver + routage audio natif"
```

---

### Task 3 : Le pont Kotlin↔Dart (MethodChannel / EventChannel)

**Files:**
- Create: `android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBridgePlugin.kt`
- Modify: `android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt`

**Interfaces:**
- Consumes: `VoipBridge` de Task 2.
- Produces: `object VoipBridgePlugin` avec `fun register(context: Context, engine: FlutterEngine)` et `fun attachActivity(activity: Activity?)`.
- Channels : MethodChannel `eu.devlabz.vox/voip`, EventChannel `eu.devlabz.vox/voip_events`.

**Méthodes MethodChannel (contrat figé, repris tels quels par Task 4) :**
- `startPersistentService()` → Boolean
- `stopPersistentService()` → Boolean
- `setAudioRoute(route: String)` → Boolean — `route` ∈ `speaker` | `wired` | `bluetooth`
- `acquireAudioFocus()` → Boolean
- `abandonAudioFocus()` → Boolean
- `startRinging(video: Boolean)` → Boolean
- `stopRinging()` → Boolean
- `requestCallPermissions()` → Boolean (lance `ActivityCompat.requestPermissions` pour RECORD_AUDIO + CAMERA, `REQ_CALL_PERMS = 4212`)
- `isCallPermissionGranted(permission: String)` → Boolean
- `isIgnoringBatteryOptimizations()` / `requestIgnoreBatteryOptimizations()` → Boolean

**Events EventChannel (une Map, champ `kind`) :**
- `{ kind: "incoming_call", callId, roomId, callerName, video }`
- `{ kind: "audio_route", route }`
- `{ kind: "service_killed" }`

- [ ] **Step 1 : Créer `VoipBridgePlugin.kt`**

Copier la structure de `SmsBridgePlugin.kt` : `private constructor`, `MethodChannel.MethodCallHandler` + `EventChannel.StreamHandler`, `CoroutineScope(SupervisorJob() + Dispatchers.IO)`, `Handler(Looper.getMainLooper())`, `launchReply { }` qui route **toujours** une réponse sur le main thread (le commentaire du fichier SMS explique pourquoi : sans ça le Future Dart pend). Reprendre aussi le re-bind de `instance` à chaque `register()` — le Pixel Fold recrée l'Activity et l'ancien messenger meurt.

- [ ] **Step 2 : Câbler dans `MainActivity.configureFlutterEngine`**

Ajouter `VoipBridgePlugin.register(applicationContext, flutterEngine)` à côté de `SmsBridgePlugin.register(...)`, et `VoipBridgePlugin.attachActivity(this)` dans `onCreate`.

- [ ] **Step 3 : Vérifier par compilation**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4 : Commit**

```bash
git add android/app/src/main/kotlin/chat/fluffy/fluffychat/voip/VoipBridgePlugin.kt android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt
git commit -m "feat(voip): pont Kotlin<->Dart (canaux voip / voip_events)"
```

---

### Task 4 : Le client Dart du pont

**Files:**
- Create: `lib/pages/call/voip_bridge.dart`
- Test: `test/pages/call/voip_bridge_test.dart`

**Interfaces:**
- Consumes: le contrat de canaux de Task 3.
- Produces: `class VoipBridge` avec
  - `static const MethodChannel channel = MethodChannel('eu.devlabz.vox/voip')`
  - `static const EventChannel events = EventChannel('eu.devlabz.vox/voip_events')`
  - `Stream<VoipEvent> get eventStream` — `VoipEvent` est une classe Dart simple avec `kind`, `callId`, `roomId`, `callerName`, `video`, `route`
  - `Future<bool> startPersistentService()`, `Future<void> stopPersistentService()`
  - `Future<void> setAudioRoute(AudioRoute route)` avec `enum AudioRoute { speaker, wired, bluetooth }`
  - `Future<bool> requestCallPermissions()`
  - `Future<bool> isCallPermissionGranted(String permission)`

- [ ] **Step 1 : Écrire le test qui échoue**

`test/pages/call/voip_bridge_test.dart`, en s'appuyant sur le helper de channel mocking déjà présent dans le dépôt si il existe (chercher `TestDefaultBinaryMessengerBinding` dans `test/`) :

```dart
test('un event incoming_call est exposé sur eventStream', () async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('eu.devlabz.vox/voip_events', ...);
  // attendu : VoipEvent.kind == 'incoming_call', callId == 'c1', video == true
});

test('setAudioRoute(bluetooth) invoque la méthode native avec le bon nom', () async {
  // intercepter l'appel MethodChannel 'setAudioRoute'
  // attendu : argument 'route' == 'bluetooth'
});
```

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `flutter test test/pages/call/voip_bridge_test.dart`
Expected: FAILED — `VoipBridge` n'existe pas.

- [ ] **Step 3 : Implémenter `lib/pages/call/voip_bridge.dart`**

`eventStream` = `events.receiveBroadcastStream().map(_parse)` où `_parse` transforme la Map en `VoipEvent`. Chaque méthode Dart→Kotlin retourne `true` si le `PlatformException` n'a pas été levée (enveloppé dans un `try/catch` qui log et renvoie `false` — un pont natif qui plante ne doit jamais faire planter l'app).

- [ ] **Step 4 : Relancer**

Run: `flutter test test/pages/call/voip_bridge_test.dart`
Expected: PASS.

- [ ] **Step 5 : Commit**

```bash
git add lib/pages/call/voip_bridge.dart test/pages/call/voip_bridge_test.dart
git commit -m "feat(voip): client Dart du pont VoipBridge"
```

---

### Task 5 : UI neuve — écran d'appel entrant + thème

**Files:**
- Create: `lib/pages/call/call_theme.dart`
- Create: `lib/pages/call/incoming_call_page.dart`
- Test: `test/pages/call/incoming_call_page_test.dart`

**Interfaces:**
- Consumes: `VoipBridge` (Task 4), `MissedCallStore` (Task 1).
- Produces:
  - `class CallTheme` — couleurs cyber VOX, réutilisées par Task 6
  - `class IncomingCallPage extends StatefulWidget` — ctor `IncomingCallPage({required String callId, required String roomId, required String callerName, required bool video, required VoidCallback onAnswer, required VoidCallback onDecline})`

- [ ] **Step 1 : Écrire le test qui échoue**

`test/pages/call/incoming_call_page_test.dart`, en `testWidgets` :

```dart
testWidgets('affiche le nom de l\'appelant et les deux boutons', (tester) async {
  await tester.pumpWidget(MaterialApp(home: IncomingCallPage(
    callId: 'c1', roomId: 'r1', callerName: 'Alice', video: true,
    onAnswer: () {}, onDecline: () {})));
  expect(find.text('Alice'), findsOneWidget);
  expect(find.byIcon(Icons.call), findsOneWidget);
  expect(find.byIcon(Icons.call_end), findsOneWidget);
});

testWidgets('appuyer sur répondre déclenche onAnswer une seule fois', (tester) async { /* tap + double-tap -> compteur == 1 */ });
```

Le second test couvre le **Review Focus n°1** au niveau UI : le bouton répondre se désactive immédiatement après le tap (un double-tap ne doit pas lancer deux sessions).

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `flutter test test/pages/call/incoming_call_page_test.dart`
Expected: FAILED — fichier introuvable.

- [ ] **Step 3 : Créer `call_theme.dart`**

Reprendre la palette existante de VOX plutôt que d'en inventer une : `lib/pages/chat/chat_liquid_glass_app_bar.dart` utilise déjà `cyber.cyan` et un verre liquide. Exposer les couleurs + les rayons + l'échelle d'espacement, pour que Task 6 ait une source unique.

- [ ] **Step 4 : Créer `incoming_call_page.dart`**

Plein écran, avatar en grand, nom, badge vidéo si `video`, deux boutons circulaires (répondre vert, refuser rouge) avec animation d'appui. `onAnswer` appelé une seule fois : `bool _answered` remis à false au début de `initState`, passé à true avant l'appel, bouton désactivé après.

- [ ] **Step 5 : Relancer**

Run: `flutter test test/pages/call/incoming_call_page_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6 : Commit**

```bash
git add lib/pages/call/call_theme.dart lib/pages/call/incoming_call_page.dart test/pages/call/incoming_call_page_test.dart
git commit -m "feat(voip): ecran d'appel entrant aux couleurs VOX"
```

---

### Task 6 : UI neuve — écran d'appel en cours + barre flottante

**Files:**
- Create: `lib/pages/call/active_call_page.dart`
- Create: `lib/pages/call/call_bar.dart`
- Test: `test/pages/call/active_call_page_test.dart`

**Interfaces:**
- Consumes: `CallTheme` (Task 5), `CallSession` du SDK.
- Produces:
  - `class ActiveCallPage extends StatefulWidget` — ctor `ActiveCallPage({required CallSession session, required CallType type})`
  - `class CallBar extends StatefulWidget` — ctor `CallBar({required CallSession session, required VoidCallback onExpand})`

- [ ] **Step 1 : Écrire les tests qui échouent**

`test/pages/call/active_call_page_test.dart`, en `testWidgets` :

```dart
testWidgets('les 5 controles sont presents', (tester) async { /* micro, camera, haut-parleur, flip, raccrocher */ });
testWidgets('couper le micro appelle localAudioStream.setEnabled(false)', (tester) async { /* ... */ });
testWidgets('le mode hors-champ est propose au troisieme appui', (tester) async { /* PIP */ });
testWidgets('raccrocher appelle session.hangup() une seule fois', (tester) async { /* ... */ });
```

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `flutter test test/pages/call/active_call_page_test.dart`
Expected: FAILED — fichier introuvable.

- [ ] **Step 3 : Créer `active_call_page.dart`**

Rendu vidéo via le `video_renderer.dart` existant pour le flux distant, et un `VideoRenderer` en PiP pour le flux local. Les 5 boutons d'action manipulent `session` (micro, caméra via `switchCamera()`, `setAudioRoute`, raccrocher via `hangup()`). Bandeau de reconnexion piloté par l'état ICE de `session` — c'est le **Review Focus n°4**.

- [ ] **Step 4 : Créer `call_bar.dart`**

Barre compacte flottante (avatar + nom + bouton raccrocher), état global via `ValueNotifier<CallSession?>` pour rester au-dessus de la navigation.

- [ ] **Step 5 : Relancer**

Run: `flutter test test/pages/call/active_call_page_test.dart`
Expected: PASS.

- [ ] **Step 6 : Commit**

```bash
git add lib/pages/call/active_call_page.dart lib/pages/call/call_bar.dart test/pages/call/active_call_page_test.dart
git commit -m "feat(voip): ecran d'appel en cours + barre flottante"
```

---

### Task 7 : Branchement dans `VoipPlugin` + suppression du dialer mort

**Files:**
- Modify: `lib/utils/voip_plugin.dart`
- Delete: `lib/pages/dialer/dialer.dart`, `lib/pages/dialer/incoming_call_view.dart`, `lib/pages/dialer/pip/`
- Test: `test/pages/call/voip_plugin_integration_test.dart`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: `VoipPlugin.handleNewCall` qui pousse `IncomingCallPage`, `handleCallEnded` qui dépile, et `MatrixState.voipPlugin` inchangé.

- [ ] **Step 1 : Écrire le test qui échoue**

```dart
testWidgets('un appel entrant affiche exactement un IncomingCallPage', (tester) async {
  // MatrixState de test + VoipPlugin
  // appeler handleNewCall(session) deux fois
  // attendu : findsOneWidget (Review Focus n°1)
});

testWidgets('handleCallEnded retire l\'ecran et rend la main', (tester) async {
  // attendu : findsNothing
});
```

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `flutter test test/pages/call/voip_plugin_integration_test.dart`
Expected: FAILED.

- [ ] **Step 3 : Brancher `handleNewCall` / `handleCallEnded`**

`handleNewCall` : si `!canHandleNewCall` → `call.hangup()` immédiatement et return (occupé). Sinon sonnerie via `VoipBridge.startRinging()`, `IncomingCallPage` en `rootOverlay: true` (le fix déjà documenté dans `addCallingOverlay` pour le bug `Null check operator`), puis `ActiveCallPage` après réponse. `handleCallEnded` : arrêter la sonnerie, rendre l'audio focus, retirer l'overlay, **ne pas** arrêter le service permanent.

- [ ] **Step 4 : Supprimer le dialer mort et réparer les imports**

`grep -rn "pages/dialer" lib/` → corriger chaque référence. `FlutterForegroundTask.init/startService/stopService` disparaissent avec `dialer.dart` : le service permanent passe par `VoipBridge.startPersistentService()`.

- [ ] **Step 5 : Vérifier analyse + tests**

Run: `flutter analyze lib/pages/call lib/utils/voip_plugin.dart && flutter test test/pages/call/`
Expected: aucun issue, tous PASS.

- [ ] **Step 6 : Commit**

```bash
git add -A lib/ test/
git commit -m "feat(voip): branche l'appel entrant sur la nouvelle UI, supprime le dialer mort"
```

---

### Task 8 : Permissions runtime + build de preuve

**Files:**
- Modify: `lib/pages/chat/chat.dart` (avant `inviteToCall`)
- Modify: `lib/pages/call/incoming_call_page.dart` (avant la sonnerie)

- [ ] **Step 1 : Demander les permissions avant d'appeler**

Avant `voipPlugin.voip.inviteToCall(...)` dans `chat.dart`, appeler `VoipBridge().requestCallPermissions()`. Micro refusé → `_showOkCancelAlertDialog` avec la raison et `return` (**Review Focus n°2**). Caméra refusée sur un appel vidéo → continuer en audio seul avec un bandeau.

- [ ] **Step 2 : Analyser et tester**

Run: `flutter analyze lib/ && flutter test test/pages/call/`
Expected: aucun issue, tous PASS.

- [ ] **Step 3 : Compiler l'APK**

Run: `cd ~/Bureau/dev/Applications/fluffychat && flutter build apk --debug`
Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4 : Installer sur le Pixel depuis control-01**

Run: `scp sk7n4k3d@10.8.0.2:~/Bureau/dev/Applications/fluffychat/build/app/outputs/flutter-apk/app-debug.apk /tmp/opencode/vox/ && sha256sum /tmp/opencode/vox/app-debug.apk && adb install -r /tmp/opencode/vox/app-debug.apk`
Expected: `Success`. Comparer le SHA256 avec celui calculé sur edge-01.

- [ ] **Step 5 : Prouver le service permanent**

Run: `adb shell dumpsys activity services eu.devlabz.vox | head -20`
Expected: un service `voip_persistent` `isForeground=true`.

Run: `adb shell input keyevent KEYCODE_HOME && adb shell am force-stop eu.devlabz.vox && adb shell monkey -p eu.devlabz.vox 1`
Expected: le service repart.

- [ ] **Step 6 : Test entrant avec Element Web**

Depuis un navigateur, `https://app.element.io` connecté sur `matrix.sk7.sh`, appeler le compte VOX. Attendu : `IncomingCallPage` au-dessus du lockscreen après `adb shell input keyevent 26` (écran éteint) — **Review Focus n°5**.

- [ ] **Step 7 : Commit**

```bash
git add lib/ && git commit -m "feat(voip): permissions runtime avant appel + APK de preuve"
```