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

---

# Audit Dart — complément v2 (2026-10-03 00:20)

- **Branche** : `feature/ux-refonte` @ `06848b6e5`
- **Méthode** : relecture complète du code **post-fix** (`HEAD`), diff des correctifs v1,
  comparaison avec `origin/main` (upstream FluffyChat) et lecture du SDK Matrix 6.2.0
  (`~/.pub-cache/hosted/pub.dev/matrix-6.2.0`). **Aucun fichier source modifié.**
- **But** : ce qui reste après le commit `d0195c01d` (« 4 crashes, 3 fuites, profil obsolète »).

> **Acquis v1 — vérifiés corrigés dans `HEAD`** : comparateur de tri des réactions
> (`message_reactions.dart:55` → `b.count.compareTo(a.count)`), `displayName!` →
> `calcDisplayname()` (`:416`), `events.first` gardé par `if (events.isEmpty)`
> (`chat_event_list.dart:40`), `substring(0,-1)` au Enter borné (`chat.dart:336`),
> `removeObserver(this)` + dispose des 4 controllers (`chat.dart:590-608`), dispose
> complet + `if (!mounted)` dans `_search` (`chat_list.dart:462,703-717`),
> `resetOwnProfileCache()` câblé au logout + changement de compte/bundle. Les 2
> `BackdropFilter` blur 8 par pastille de réaction ont été retirés.

Les points ci-dessous sont **encore présents** dans `HEAD`.

---

## 15. FUITE — `_CuteEventOverlay` ne dispose jamais son `AnimationController`

- **Fichier** : `lib/pages/chat/events/cute_events.dart:106-124`
- **Sévérité** : fuite mémoire + listener fantôme (chaque « câlin / yeux / hug »)
- **Cause** : `_CuteEventOverlayState with TickerProviderStateMixin` crée
  `controller = AnimationController(...)` (l.117), fait `forward()` + `addStatusListener(_hideOverlay)`
  (l.122) mais **n'a aucune méthode `dispose()`**. Le `OverlayEntry` est retiré à la fin
  de l'animation (`onAnimationEnd`), ce qui démonte le State : `SingleTickerProviderStateMixin.dispose`
  lève alors en debug (« disposed with an active Ticker ») et, en release, le controller
  et son status listener restent attachés. Le chemin **automatique** (`addOverlay` depuis
  `initState` si `autoplayImages`) passe par ce code à chaque event `cute_type`.
- **Fix** :
  ```dart
  @override
  void dispose() {
    controller?.removeStatusListener(_hideOverlay);
    controller?.dispose();
    super.dispose();
  }
  ```

## 16. CRASH — `typeEmoji` : `selection.start/end` = -1 non gardés

- **Fichier** : `lib/pages/chat/chat.dart:1155-1163`
- **Sévérité** : crash (`RangeError`) à la sélection d'un emoji depuis le picker
- **Cause** : `text.replaceRange(selection.start, selection.end, emoji.emoji)`.
  Même cause racine que le bug #4 de la v1 (corrigé sur le handler Entrée, **pas ici**) :
  quand le texte est posé par programme (`_loadDraft` l.284, `cancelReplyEventAction`
  l.1479, `editSelectedEventAction` l.1197), `sendController.selection` peut valoir
  `TextSelection.collapsed(offset: -1)` → `replaceRange(-1, -1, …)` lève. Le chemin
  SMS équivalent garde bien `sel.isValid` (`sms_chat_page.dart:535`).
- **Fix** :
  ```dart
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  ```

## 17. CRASH — `scrollToEventId` / `scrollDown` : `timeline!` non gardé + récursion sans `mounted`

- **Fichier** : `lib/pages/chat/chat.dart:1086-1126` et `:1131-1143`
- **Sévérité** : crash (`Null check operator`) / `setState` après dispose
- **Cause** : `scrollToEventId` fait `timeline!.events.firstWhereOrNull(...)` (l.1090) et
  `scrollDown` fait `if (!timeline!.allowNewEvent)` (l.1134) sans garde. Or `timeline`
  est mis à `null` volontairement dans plusieurs chemins (`_getTimeline` échoue, `scrollDown`
  lui-même, `dispose`). Pire : le chemin de rechargement relance
  `WidgetsBinding.instance.addPostFrameCallback((_) { scrollToEventId(eventId); })` (l.1110-1117)
  **sans test `mounted`** → si la page est fermée pendant le rechargement, la callback
  relance une récursion sur un State démonté (`setState`/`timeline!`).
  Appelants : bannière « aller au dernier message », `PinnedEvents`, `MiniAudioPlayer`
  (`mini_audio_player.dart:74`), deep-link `?event=`.
- **Fix** : `final tl = timeline; if (tl == null) return;` en tête des deux méthodes, et
  `if (!mounted) return;` dans la closure post-frame.

## 18. CRASH/UX — `onPhoneButtonTap` : `.then` sans `mounted` (régression vs upstream)

- **Fichier** : `lib/pages/chat/chat.dart:1434-1445`
- **Sévérité** : crash (`context` après dispose) + comportement changé
- **Cause** : l'upstream faisait `final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (!mounted) return; … if (sdkInt < 21) { …; return; }`. Le fork a remplacé par un
  `DeviceInfoPlugin().androidInfo.then((value) { if (value.version.sdkInt < 21) {
  Navigator.pop(context); showOkAlertDialog(context: context, …); } });` :
  1. pas de `mounted` → si l'utilisateur quitte l'écran avant la résolution (le plugin
     Android est async), `Navigator.pop(context)`/`showOkAlertDialog` s'exécutent sur un
     contexte démonté ;
  2. il n'y a plus de `return` : même sur Android < 21 on enchaîne le popup d'appel.
- **Fix** : revenir au `await … ; if (!mounted) return; … if (sdkInt < 21) { …; return; }`.

## 19. LOGIQUE — `ChatView.build` déclenche `room.join()` à chaque rebuild (invitation)

- **Fichier** : `lib/pages/chat/chat_view.dart:34-40`
- **Sévérité** : UX/logique (join en double, dialogs empilés)
- **Cause** : `showFutureLoadingDialog(context: context, future: () => controller.room.join())`
  est appelé **dans `build`**, sans condition « déjà en cours », dès que
  `membership == invite`. `ChatView` est reconstruit par plusieurs sources
  (`StreamBuilder` room-state, `FutureBuilder` timeline, `setState` du contrôleur) →
  plusieurs `join()` concurrents et plusieurs dialogs de chargement. (Présent aussi
  upstream, mais réel.)
- **Fix** : déplacer le join dans `initState`/un flag `_joining`, ou tester
  `room.membership == invite && !_joinStarted`.

## 20. UX — `LinkPreviewCard` : décodage Latin-1 au lieu d'UTF-8

- **Fichier** : `lib/utils/sms/link_preview.dart:84`
- **Sévérité** : UX/cosmétique (titres/descriptions illisibles)
- **Cause** : `final html = String.fromCharCodes(bytes);` mappe chaque octet en code
  point → tout corps UTF-8 non-ASCII (accents français, emoji, cyrillique…) devient du
  mojibake (`é` → `Ã©`) dans les cartes d'aperçu de lien (Matrix et SMS).
- **Fix** : `final html = utf8.decode(bytes, allowMalformed: true);` (importer
  `dart:convert`).

## 21. LOGIQUE — `_Reaction` sans `key` : animation sur la mauvaise pastille

- **Fichier** : `lib/pages/chat/events/message_reactions.dart:66-94`
- **Sévérité** : UX/état (animation appliquée au mauvais emoji)
- **Cause** : les pastilles sont construites par `...visible.map((r) => _Reaction(...))`
  **sans `key`**. `_Reaction` est un `StatefulWidget` qui garde un `_lastCount` et un
  `AnimationController` ; `didUpdateWidget` rejoue le pop si `widget.count > _lastCount`.
  Comme `reactionList` est **triée par count décroissant** (l.55), un changement de
  nombre de réactions réordonne la liste : Flutter réapparie les States **par position**
  → un State peut recevoir la `reactionKey` d'une autre réaction, et le pop se déclenche
  sur la pastille voisine (voire sur une réaction dont le count a *baissé*).
- **Fix** : `_Reaction(key: ValueKey(r.key), …)`. (Idem dans `_showAllReactionsSheet`
  l.133.)

## 22. FUITE — `StartPollBottomSheet` et `SendFileDialog` ne disposent pas leurs controllers

- **Fichiers** :
  - `lib/pages/chat/start_poll_bottom_sheet.dart:15-19` (`_bodyController` + `_answers`)
  - `lib/pages/chat/send_file_dialog.dart:44` (`_labelTextController`)
- **Sévérité** : fuite mémoire (mineure, par ouverture de dialog)
- **Cause** : aucun `dispose()` dans `_StartPollBottomSheetState` ni dans
  `SendFileDialogState` ; seuls les controllers d'`_answers` retirés manuellement sont
  disposés (`start_poll_bottom_sheet.dart:106`). `_bodyController` + les réponses
  restantes + `_labelTextController` restent attachés à leurs listeners.
- **Fix** : ajouter
  ```dart
  @override
  void dispose() {
    _bodyController.dispose();
    for (final a in _answers) { a.dispose(); }
    _labelTextController.dispose();
    super.dispose();
  }
  ```

## 23. PERF — `fetchOwnProfile()` dans `FutureBuilder` re-fetché à chaque rebuild

- **Fichiers** :
  - `lib/pages/chat/chat_input_row.dart:496` et `:505` (`_ChatAccountPicker`)
  - `lib/pages/chat_list/client_chooser_button.dart:118` et `:170`
- **Sévérité** : perf (requête réseau + rebuild à chaque frappe/scroll)
- **Cause** : la v1 a mémoïsé le profil de l'AppBar (`liquid_glass_app_bar.dart`), mais
  les deux autres surfaces refont `fetchOwnProfile()` **directement dans le `FutureBuilder`** :
  à chaque rebuild du composer (toggle emoji, focus, sélection…) un nouveau Future est créé
  → nouvel appel réseau et flash « vide » entre deux snapshots. Le sélecteur de compte du
  composer (`chat_input_row.dart:505`) le fait même pour **chaque client** à chaque
  ouverture du menu.
- **Fix** : réutiliser `_ownProfileCached(client)` (déjà écrit pour l'AppBar) dans ces
  deux widgets, ou mémoïser par `client.userID`.

## 24. PERF — flux `onSync` recréés à chaque build (subtitle, seen-by, typing)

- **Fichiers** :
  - `lib/pages/chat/chat_liquid_glass_app_bar.dart:480-483` (`_SubtitleLine`)
  - `lib/pages/chat/seen_by_row.dart:17-23`
  - `lib/pages/chat/typing_indicators.dart:21-27`
- **Sévérité** : perf (allocation + abonnements inutiles)
- **Cause** : chacun construit `room.client.onSync.stream.where(...).rateLimit(...)`
  **dans le `build`**. Chaque rebuild crée un nouveau Stream et un nouveau `StreamBuilder`
  s'y réabonne ; le `Timer` interne du `rateLimit` (`utils/stream_extension.dart:23`)
  n'est pas annulé à l'annulation (il s'auto-neutralise via `isClosed`, donc pas de
  crash, mais du travail jeté à chaque frame de scroll). Comme l'AppBar/timeline se
  rebuild souvent (drag, typing, sélection), c'est du déchet permanent.
- **Fix** : hoister le stream (champ `late final` du State) et le réutiliser.

## 25. PERF — `BackdropFilter` plein écran animé sur les overlays modaux

- **Fichiers** :
  - `lib/pages/chat/events/message_context_overlay.dart:411-412` (blur 24 plein écran)
  - `lib/pages/chat/voice_recording_overlay.dart:132-135` (blur 24 derrière le panneau)
- **Sévérité** : perf (transitoire mais coûteux)
- **Cause** : le menu contextuel long-press floute **tout l'écran** (`Positioned.fill`)
  pendant que 3 `AnimationController` animent la bulle/les réactions/les actions
  (`AnimatedBuilder`, l.380-382) → re-flou complet recalculé à chaque frame de l'entrée
  ET de la sortie. Idem pour l'overlay d'enregistrement vocal, qui pulse en plus
  (`_PulseRecDot`, `_SlideToCancelChevrons`, `_LockBadge`).
- **Fix** : figer le blur pendant l'animation (n'animer que l'opacité d'un fond déjà
  flouté), le réduire, ou utiliser `BackdropFilter.grouped` + `BackdropGroup`.

## 26. CRASH (edge) — `_showScrollUpMaterialBanner(eventContextId!)` avec `eventContextId` null

- **Fichier** : `lib/pages/chat/chat.dart:516-518`
- **Sévérité** : crash (`Null check operator`) sur un chemin d'erreur
- **Cause** : `_getTimeline` force `eventContextId = null` en tête quand l'id est invalide
  (l.497-500). Le `catch` teste ensuite `if (e is TimeoutException || e is IOException)
  _showScrollUpMaterialBanner(eventContextId!)`. Un `getTimeline()` initial (id null)
  qui expire, ou une id invalide + timeout → `eventContextId!` lève.
  (Présent aussi upstream.)
- **Fix** : `if (eventContextId != null && (e is TimeoutException || e is IOException)) …`.

---

## Points mineurs additionnels

- `lib/pages/chat/events/cute_events.dart:18` : `_isOverlayShown` est un `static` de
  State partagé entre tous les widgets — un overlay déjà affiché bloque l'autoplay des
  autres events `cute` (voulu), mais si `onAnimationEnd` n'est jamais appelé (controller
  non disposé, cf. #15) le drapeau reste bloqué et **aucun** overlay ne se réaffiche plus
  pour la session.
- `lib/widgets/avatar_with_status_ring.dart:207-212` : `_PulseRing` démarre son ticker
  dans l'initialiseur de champ `late final` (donc avant `initState`). Ticker muté
  automatiquement hors écran par `TickerMode`, mais **toutes** les lignes non-lues
  visibles de la liste pulsent simultanément (N tickers 60 fps). Envisager un seul
  contrôleur partagé, comme pour les skeletons (#13 v1).
- `lib/pages/chat_list/chat_list_body.dart:473-516` : `_ChatListSections.layout` re-trie
  toute la liste à chaque build (à chaque sync, debounce SMS, frappe en recherche) et
  `_bucketForTs` appelle `DateTime.now()` par item. Correct mais O(n log n) par frame de
  sync ; un cache par `(lastEvent, now.day)` éviterait le re-tri.
- `lib/pages/chat/events/message_context_overlay.dart:192-204` : `_withSelectedEvent`
  mute `controller.selectedEvents` **sans `setState`** alors que le même `ChatController`
  pilote l'AppBar en mode sélection ; la sélection peut rester « fantôme » jusqu'au
  prochain rebuild.
- `lib/pages/chat/events/message.dart:1029-1052` (`_AnimateIn`) : `addPostFrameCallback`
  appelé **depuis `build`** pour passer `_animationFinished` → un frame supplémentaire
  systématique par bulle animée ; `_AnimateInOnce` du SMS a le même schéma. Cosmétique.
- `lib/pages/chat/chat.dart:373` + `:595` : l'ordre `inputFocus.removeListener(...)` puis
  `inputFocus.dispose()` est correct ; RAS depuis la v1.
- `lib/pages/chat/events/message_reactions.dart:387-424` : `reactionEntry!` /
  `reactors!` restent forcés (toujours construits ensemble) — fragile, pas un bug actif.

---

## Top 10 du complément (par sévérité)

| # | Sévérité | Emplacement | Résumé |
|---|----------|-------------|--------|
| 1 | crash | `chat.dart:1155-1163` (`typeEmoji`) | `selection.start/end` = -1 → `RangeError` |
| 2 | crash | `chat.dart:1086-1143` | `timeline!` non gardé + récursion post-frame sans `mounted` |
| 3 | crash/UX | `chat.dart:1434-1445` | `onPhoneButtonTap` `.then` sans `mounted` + `return` perdu |
| 4 | fuite | `cute_events.dart:106-124` | `AnimationController` + status listener jamais disposés |
| 5 | UX/logique | `chat_view.dart:34-40` | `room.join()` déclenché depuis `build` (join en double) |
| 6 | UX | `link_preview.dart:84` | décodage Latin-1 au lieu d'UTF-8 (mojibake) |
| 7 | état | `message_reactions.dart:66` | `_Reaction` sans `key` → pop sur la mauvaise pastille |
| 8 | fuite | `start_poll_bottom_sheet.dart:15` / `send_file_dialog.dart:44` | controllers non disposés |
| 9 | perf | `chat_input_row.dart:496,505` / `client_chooser_button.dart:118,170` | `fetchOwnProfile()` par rebuild |
| 10 | perf | `chat_liquid_glass_app_bar.dart:480` / `seen_by_row.dart:17` / `typing_indicators.dart:21` | flux `onSync` recréés à chaque build |

**Hors top-10 mais à traiter** : `chat.dart:517` (`eventContextId!` null, edge), overlays
modaux à blur plein écran animé (#25), tickers de pastilles non-lues (#points mineurs).
