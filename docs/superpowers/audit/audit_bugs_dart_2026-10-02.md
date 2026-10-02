# Audit bugs Dart — VOX (fork FluffyChat)

- **Date** : 2026-10-02
- **Branche** : `feature/ux-refonte`
- **Périmètre** : `lib/pages/chat_list/`, `lib/pages/chat/`, `lib/pages/sms_chat/`, `lib/widgets/cyber/`
- **Méthode** : lecture statique + `flutter analyze` + inspection du SDK Matrix patché (`~/Bureau/dev/Applications/matrix-dart-sdk-patched/`). **Aucun fichier source modifié.**

## État de l'analyse statique

```
flutter analyze → 22 issues, toutes `info` (deprecations radio, tri d'imports/pubspec).
0 erreur, 0 warning. Le compilateur ne voit donc AUCUN des bugs ci-dessous :
ce sont des bugs d'exécution / de logique / de perf.
```

---

## 1. CRASH — Comparateur de tri des réactions invalide

- **Fichier** : `lib/pages/chat/events/message_reactions.dart:55`
- **Sévérité** : crash potentiel (contrat `List.sort` violé) + ordre instable
- **Cause** : `reactionList.sort((a, b) => b.count - a.count > 0 ? 1 : -1);`
  Le comparateur ne renvoie **jamais 0** et n'est pas antisymétrique : pour deux
  réactions de même score il renvoie toujours `-1`, ce qui contredit la relation
  d'ordre demandée par Dart. Selon l'implémentation (TimSort), cela peut produire
  un ordre incohérent/oscillant des pastilles à chaque rebuild.
- **Fix** :
  ```dart
  reactionList.sort((a, b) => b.count.compareTo(a.count));
  ```

## 2. CRASH — `reactor.displayName!` sur un utilisateur sans displayname

- **Fichier** : `lib/pages/chat/events/message_reactions.dart:430`
- **Sévérité** : crash (null check) sur long-press d'une réaction
- **Cause** : `label: Text(reactor.displayName!)`. Or `User.displayName` est
  **nullable** (`matrix-dart-sdk-patched/lib/src/user.dart:74`) ; un membre
  présent uniquement via `stateKey` (pas de `displayname` dans le state member,
  cas fréquent en room bridgée / membre jamais complété) donne `null`.
  L'avatar juste au-dessus utilise bien le nullable `reactor.displayName` (l.426),
  mais le label force le `!` → `TypeError: Null check operator used on a null value`.
- **Fix** :
  ```dart
  label: Text(reactor.calcDisplayname()),
  ```
  (ou `reactor.displayName ?? reactor.id`).

## 3. CRASH — `events.first` sans garde sur une liste filtrée vide

- **Fichiers** : `lib/pages/chat/chat_event_list.dart:87` et `:132`
- **Sévérité** : crash (`Bad state: No element`)
- **Cause** : le code ne garde que `timeline == null` (l.27). Mais `events` est
  `timeline.events.filterByVisibleInGui(threadId: ...)`. En mode thread, ou si
  `hideRedactedEvents` / `hideUnknownEvents` filtrent tout, `events` peut être
  **vide alors que `timeline.events` ne l'est pas** :
  - l.87 `SeenByRow(event: events.first)` → `StateError`;
  - l.132 `event.eventId == timeline.events.first.eventId` → `StateError`.
- **Fix** : garder `if (events.isEmpty) return const Center(...);` en tête de
  `build`, ou passer par `firstOrNull` (le projet importe déjà `collection`).

## 4. CRASH — `sendController.selection.baseOffset == -1` dans le handler Entrée

- **Fichier** : `lib/pages/chat/chat.dart:327-343` (`_customEnterKeyHandling`)
- **Sévérité** : crash (`RangeError`) sur appui Entrée
- **Cause** : `sendController.text.substring(0, sendController.selection.baseOffset)`.
  Quand le texte est posé programmatiquement (`_loadDraft` l.104 : `sendController.text = draft`,
  ou `cancelReplyEventAction` l.1476, ou `typeEmoji`), la sélection est réinitialisée à
  `TextSelection.collapsed(offset: -1)`. Avec `sendOnEnter = false` (multiligne), un
  appui Entrée entre dans la branche `else if` et fait `substring(0, -1)` → `RangeError`.
- **Fix** : borner l'offset :
  ```dart
  final sel = sendController.selection;
  final offset = sel.isValid ? sel.baseOffset : sendController.text.length;
  ```

## 5. FUITE — `ChatController` n'enlève pas son observer de lifecycle

- **Fichier** : `lib/pages/chat/chat.dart:398` (addObserver) vs `:588-606` (dispose)
- **Sévérité** : fuite mémoire + callbacks sur State mort
- **Cause** : `WidgetsBinding.instance.addObserver(this)` est appelé dans `initState`,
  mais `dispose()` ne fait **jamais** `removeObserver(this)` (confirmé par grep :
  aucune occurrence dans le fichier). Chaque room ouverte/fermée laisse un observer
  enregistré à vie. `didChangeAppLifecycleState` (l.546) s'exécutera sur le State
  disposé ; il est gardé par `mounted`, donc pas de crash, mais la liste grossit
  indéfiniment (N observers après N rooms visitées).
- **Fix** : `WidgetsBinding.instance.removeObserver(this);` en tête de `dispose()`.

## 6. FUITE — 4 controllers/notifiers non disposés dans `ChatController`

- **Fichier** : `lib/pages/chat/chat.dart` — `dispose()` l.588-606
- **Sévérité** : fuite mémoire (4 objets + leurs listeners par room)
- **Cause** : jamais disposés :
  - `sendController` (TextEditingController, l.608)
  - `inputFocus` (FocusNode, l.122 — porte un `onKeyEvent`)
  - `scrollController` (AutoScrollController, l.120)
  - `_displayChatDetailsColumn` (ValueNotifier, l.1483)
- **Fix** : les `dispose()` dans `dispose()`. (Le `scrollController.removeListener`
  existant ne remplace pas le `dispose()` : le listener interne d'AutoScrollController
  reste attaché.)

## 7. FUITE / CRASH — `ChatListController.dispose()` incomplet (+ timer de recherche)

- **Fichier** : `lib/pages/chat_list/chat_list.dart:701-710`
- **Sévérité** : crash possible + fuite
- **Cause** : ne libère ni `_coolDown` (Timer, l.425), ni `searchController` (l.457),
  ni `searchFocusNode` (l.459), ni `scrolledToTop` (ValueNotifier, l.553), ni
  `_clientStream` (StreamController.broadcast, l.555). Le `_coolDown` programme
  `_search` à +500 ms : si l'écran est quitté entre-temps, `_search()` lit
  `Matrix.of(context)` (l.462) sur un contexte démonté puis fait `setState` (l.508)
  sans garde `mounted` → exception. Le `catch` l.463 utilise aussi `ScaffoldMessenger.of(context)`.
- **Fix** : `_coolDown?.cancel();` + `searchController.dispose(); searchFocusNode.dispose();
  scrolledToTop.dispose(); _clientStream.close();` dans `dispose()`, et
  `if (!mounted) return;` avant le `setState` final de `_search()`.

## 8. UX/SÉCURITÉ — Le profil mis en cache n'est jamais invalidé au logout

- **Fichier** : `lib/pages/chat_list/liquid_glass_app_bar.dart:16-25`
- **Sévérité** : UX (mauvais nom/avatar) voire fuite d'identité entre comptes
- **Cause** : `_ownProfileFuture` est mémorisé process-wide et la fonction
  `resetOwnProfileCache()` **n'a aucun appelant** (grep sur tout le repo : seule la
  définition + le commentaire). Après déconnexion puis connexion d'un autre compte,
  l'AppBar continue d'afficher les données du profil précédent (le `Future` résolu
  est servi tel quel).
- **Fix** : appeler `resetOwnProfileCache()` dans le chemin de logout
  (`lib/pages/settings/settings.dart:63 logoutAction` et/ou le handler
  `onLoginStateChanged` de `lib/widgets/matrix.dart`), ou indexer le cache par `userID`.

---

## 9. PERF — `BackdropFilter` de l'AppBar : re-flou à chaque frame

- **Fichiers** :
  - `lib/pages/chat/chat_liquid_glass_app_bar.dart:65-66` (blur 20)
  - clone SMS : `lib/pages/sms_chat/sms_chat_page.dart:2117-2118` (`_SmsLiquidGlassAppBar`)
- **Sévérité** : perf
- **Cause (confirmée)** : le `BackdropFilter` échantillonne la couche située
  derrière lui. Comme la timeline scrolle **sous** l'AppBar
  (`extendBodyBehindAppBar: true`) et que l'`AuroraBackground` derrière elle est
  animée en continu, le flou doit être recalculé **à chaque frame**. Le
  `RepaintBoundary` (l.61 / l.2113) protège le sous-arbre de l'AppBar mais
  **n'empêche pas** le re-flou du backdrop — c'est une propriété du `BackdropFilter`,
  pas un défaut de boundary.
- **Fix** : envelopper le couple fond + contenu scrollable dans un
  `BackdropGroup` et utiliser `BackdropFilter.grouped(...)` (un seul calcul de flou
  par frame réutilisé par les 2+ backdrops de l'écran), et/ou baisser `blurSigma`.
  À défaut, masquer l'aurora derrière l'AppBar.

## 10. PERF — Un `BackdropFilter` blur 8 par pastille de réaction

- **Fichier** : `lib/pages/chat/events/message_reactions.dart:309-310` (pastille) et `:352-353` (`_OverflowChip`)
- **Sévérité** : perf
- **Cause (confirmée)** : chaque pastille de réaction instancie son propre
  `BackdropFilter(blur 8)`. Dans une room avec beaucoup de messages réagis, on
  empile des dizaines de couches à flouter en plus de la liste qui scrolle → chaque
  pastille est recalculée à chaque frame où son arrière-plan change. Le fond de la
  pastille est déjà `surfaceContainerHighest` à alpha 0.6, le flou n'apporte
  quasiment rien visuellement.
- **Fix** : remplacer le `BackdropFilter` par un simple fond opaque/translucide
  (ou `BackdropFilter.grouped` partagé). Le look change à peine, le coût tombe à zéro.

## 11. PERF — Composer et liste partagent le même `State` → rebuild complet de la liste

- **Fichiers** :
  - `lib/pages/chat/chat.dart:1373-1378` (`onInputBarChanged` → `setState`)
  - `lib/pages/chat/chat_view.dart:136-288` (la liste `ChatEventList` est construite
    dans le `build` de `ChatController`)
  - équivalent SMS : `lib/pages/sms_chat/sms_chat_page.dart:156-159` + `:816`
- **Sévérité** : perf
- **Nuance importante** : ce n'est **pas littéralement à chaque frappe**. Le
  `TextEditingController` n'est pas écouté par le contrôleur ; `setState` n'est
  déclenché que quand le texte **franchit la frontière vide ↔ non-vide**
  (`_inputTextIsEmpty != text.isEmpty`), soit ~2 fois par message. Mais à chaque
  fois, tout `ChatController.build` est reconstruit : `ChatView` → `ChatEventList`
  → `ListView.custom` (tous les items visibles), alors que seule la zone composer
  devait changer. Idem pour les autres `setState` du contrôleur (emoji picker,
  `_scrolledUp`, `dragging`, sélection…).
- **Fix** : isoler le composer dans un widget `StatefulWidget`/`ValueListenableBuilder`
  qui ne dépend que de `sendController` et de `_inputTextIsEmpty`, et ne plus faire
  `setState` sur le `ChatController` pour ces changements locaux.

## 12. PERF — `CyberPrimaryButton` : le balayage continue de tourner quand le bouton est désactivé

- **Fichier** : `lib/widgets/cyber/cyber_widgets.dart:304-327` (`_CyberPrimaryButtonState`)
- **Sévérité** : perf
- **Cause** : `_sweep.repeat()` est (re)piloté uniquement dans `didChangeDependencies`.
  Il n'y a **pas de `didUpdateWidget`**. Si `loading` passe à `true` (ou `onPressed`
  à `null`) sans qu'une dépendance héritée change, `_sweep` continue de ticker à
  chaque frame alors que le widget de balayage est retiré de l'arbre (l.352).
  Ticker fantôme permanent tant que le widget vit.
- **Fix** : extraire la logique dans `_syncAnimation()` et l'appeler aussi depuis
  `didUpdateWidget`.

## 13. PERF — Squelettes de chargement : 1 ticker répété par barre

- **Fichiers** : `lib/pages/chat_list/dummy_chat_list_item.dart:22-52` + `lib/widgets/cyber/cyber_skeleton.dart:41-57`
- **Sévérité** : perf (état de chargement uniquement)
- **Cause** : chaque `CyberSkeleton` a son propre `AnimationController..repeat()`.
  L'écran de chargement affiche 4 `DummyChatListItem`, chacun avec 5 squelettes
  animés → jusqu'à **20 tickers simultanés**. `DummyChatListItem(animate: true)` est
  bien utilisé pour le shimmer (chat_list_body.dart:110-113).
- **Fix** : partager un unique `AnimationController` via un `InheritedWidget`/provider
  ou un `ShaderMask` parent, ou passer `animate: false` et animer le parent.

## 14. LOGIQUE — Conversation SMS « nouveau numéro » : `threadId` reste vide

- **Fichiers** : `lib/pages/sms_chat/new_sms_page.dart:49-57` →
  `lib/pages/sms_chat/sms_chat_page.dart:102, 176, 186, 202-209, 279`
- **Sévérité** : UX/logique
- **Cause** : `NewSmsPage._openConversation` pousse `SmsChatPage(threadId: '')`.
  La page ne met **jamais** à jour `widget.threadId` après le premier envoi (le
  `rowId` retourné n'est pas converti en threadId). Conséquences pour ce fil :
  - `setActiveThread('')` → la protection « pas de notif du fil ouvert » ne marche
    pas : les SMS entrants de ce fil continuent de notifier ;
  - `cancelNotification('')` / `markRead('')` : no-op silencieux ;
  - `EphemeralMessages.smsConvId('')` : politique d'éphémères rattachée à une clé vide ;
  - `_listenIncoming` ne matche que par adresse (fallback), pas par thread.
- **Fix** : résoudre le `threadId` existant en `initState` via
  `listConversations()`/recherche par adresse, ou récupérer le thread natif après
  le premier `sendSms` (`getOrCreateThreadId`) et le stocker dans un état local.

---

## Points secondaires (non bloquants)

- `lib/pages/chat/chat.dart:1174` `typeEmoji` : `selection.start/end` peuvent être
  `-1` (mêmes causes que #4) → `replaceRange(-1, …)` peut lever. Contrairement au
  SMS (`sms_chat_page.dart:174-184`) qui, lui, garde `sel.isValid`.
- `lib/pages/chat/events/message_reactions.dart:422` : `reactionEntry!` et
  `reactors!` forcés — OK en pratique (toujours construits ensemble) mais fragile.
- `lib/pages/chat/chat_list_body.dart:284-331` `_StaggeredFadeIn` : le commentaire
  annonce « grâce au flag local `_shown` » mais aucun `_shown` n'existe ; l'absence
  de rejeu repose uniquement sur `initState`. Commentaire trompeur, pas un bug.
- Barres de sync/typing (`_SubtitleLine` `chat_liquid_glass_app_bar.dart:480`,
  `TypingIndicators`, `SeenByRow`) : recréent un `Stream` + `rateLimit` à chaque
  build ; le `Timer` interne du `rateLimit` n'est pas annulé à l'annulation
  (`lib/utils/stream_extension.dart:23`), il s'auto-neutralise via `isClosed`. Coût
  faible mais évitable en hoistant le stream.
- `lib/pages/chat_list/liquid_glass_app_bar.dart` : `_GreetingLine` calcule
  `DateTime.now()` et un `FutureBuilder` profil une fois mis en cache ; le message
  d'accueil (matin/soir) reste figé jusqu'au prochain rebuild. Cosmétique.

## TODO / FIXME / HACK

**14 occurrences dans `lib/`, et AUCUNE dans le périmètre audité**
(`chat_list/`, `chat/`, `sms_chat/`, `widgets/cyber/`). Le fork n'a pas laissé de
dette marquée dans les écrans principaux. Les 14 sont :

```
lib/pages/settings_emotes/import_archive_dialog.dart:222  TODO: support Lottie
lib/pages/key_verification/key_verification_dialog.dart:317 TODO: better error UI
lib/utils/voip_plugin.dart:164,169,173,179,183              TODO: group call / keyProvider
lib/utils/matrix_sdk_extensions/matrix_locals.dart:280,297,308 TODO: i18n events
lib/utils/date_time_extension.dart:67                       TODO: Add localization
lib/utils/background_push.dart:378                          TODO: onNoDistribDialogDismissed
lib/utils/url_launcher.dart:192                             TODO: navigate to space
lib/widgets/matrix.dart:94                                  TODO: Multi-client VoiP
```

---

## Top 10 (par sévérité)

| # | Sévérité | Emplacement | Résumé |
|---|----------|-------------|--------|
| 1 | crash | `message_reactions.dart:55` | Comparateur de tri invalide |
| 2 | crash | `message_reactions.dart:430` | `displayName!` nullable |
| 3 | crash | `chat_event_list.dart:87,132` | `events.first` sur liste filtrée vide |
| 4 | crash | `chat.dart:327-343` | `substring(0, -1)` au Enter |
| 5 | fuite | `chat.dart:588` | `removeObserver` manquant |
| 6 | fuite | `chat.dart:588` | 4 controllers non disposés |
| 7 | fuite/crash | `chat_list.dart:701` | dispose incomplet + timer `_search` |
| 8 | UX/sécu | `liquid_glass_app_bar.dart:16` | cache profil jamais invalidé |
| 9 | perf | `chat_liquid_glass_app_bar.dart:65` + `sms_chat_page.dart:2117` | BackdropFilter re-flou chaque frame |
| 10 | perf | `message_reactions.dart:309,352` | blur 8 par pastille de réaction |
