# Refonte de la composer bar Matrix — Design

**Date** : 2026-06-08
**Branche** : `feature/ux-refonte`
**Statut** : design validé (brainstorming), en attente de plan d'implémentation

## Objectif

Reprendre **complètement** la barre de saisie des rooms Matrix natives (bouton `+`,
emoji, caméra, champ texte, bouton micro vocal) : nouveau visuel néon frosted glass,
animations premium, et features inspirées de l'état de l'art messaging 2025-2026
(Material 3 Expressive, WhatsApp/Telegram/Element X). Le tout en restant cohérent avec
le design system CYBERCORE existant et **sans casser** la logique fonctionnelle déjà en
place (vocal, scheduled, éphémère, link preview, multi-compte).

Cette refonte concerne **uniquement les rooms Matrix** (`ChatInputRow`). La barre SMS
(`SmsChatPage`) n'est pas dans le scope de cette spec.

## Périmètre validé (décisions du brainstorming)

| Sujet | Décision |
|---|---|
| Layout | **C** : pilule frosted glass `[+] [champ] [😊]` + **bouton micro/send rond DÉTACHÉ** à droite |
| Attach menu | **B** : le `+` ouvre un panneau frosted glass montant (stagger), **grille 3 colonnes** |
| Verre | **Frosted glass** (BackdropFilter blur opaque) + hairline néon + glow cyan au focus. PAS de liquid glass. |
| Vocal | Restyler néon le flow existant (slide/lock/overlay) + **waveform live** stylée. Geste inchangé. |
| Transcription | **Hors scope** (retirée). |
| RTE | **Niveau 1** : markdown auto Matrix (déjà natif) + mentions `@` → pill (déjà partiellement en place). |
| Conservé | scheduled send (long-press), éphémère, link preview, account picker multi-compte. |

## État du code existant (vérifié)

- `lib/pages/chat/chat_input_row.dart` (616 l.) — la barre. Contient déjà : `+` en
  `PopupMenuButton` (location/poll/image/video/file/ephemeral), caméra en `PopupMenuButton`
  (photo/vidéo), bouton emoji toggle, `InputBar`, `VoiceRecordButton` ↔ send (morph par
  largeur animée), `_scheduleSend` (long-press), `_EphemeralIndicator`, `_ChatAccountPicker`.
- `lib/pages/chat/voice_record_button.dart` (206 l.) — geste complet : `onLongPressStart`
  → `startRecording`, `onLongPressMoveUpdate` → `computeGestureState` (slide cancel / lock),
  `AnimatedScale` 1.4× pendant l'enregistrement, haptics. **À préserver intégralement.**
- `lib/pages/chat/recording_input_row.dart` (173 l.) — états live-hold + locked, **waveform
  déjà rendue** (`state.amplitudeTimeline` en barres `CyberColors.cyan`). À restyler.
- `lib/pages/chat/recording_view_model.dart` — `amplitudeTimeline`, `isRecording`,
  `isLocked`, `duration`. Inchangé (corrigé récemment).
- `lib/pages/chat/voice_recording_overlay.dart` — overlay slide/lock. À restyler.
- `lib/pages/chat/input_bar.dart` (457 l.) — **mentions `@` déjà gérées** (regex
  `@([-\w]+)`, suggestion `type: user/room`, `user.mention`). Markdown Matrix natif.
- `lib/config/design_tokens.dart` — `FluffyDurations`, `FluffyCurves.spring` /
  `springTight` (`SpringDescription`), `FluffyRadius`, `FluffySpacing`.
- `lib/config/cyberpunk_theme_extension.dart` — `CyberColors` (cyan `#00F0FF`, magenta
  `#FF2E92`, violet `#A78BFA`) + glow réutilisable.

**Conséquence** : mentions et markdown sont quasi acquis ; la waveform et le geste vocal
existent. Le gros du travail est **visuel** (frosted glass, glow, morph spring, grille
attach) + branchements ciblés, pas une réécriture de la logique.

## Architecture

Découpage en composants isolés, chacun testable et à responsabilité unique. Nouveaux
fichiers sous `lib/pages/chat/composer/` et `lib/widgets/cyber/`.

### Nouveaux composants

1. **`FrostedComposerSurface`** (`lib/widgets/cyber/frosted_composer_surface.dart`)
   - Pilule réutilisable : `BackdropFilter(blur)` + fond semi-opaque + hairline néon +
     glow cyan animé piloté par un `bool focused`.
   - Props : `child`, `focused`, `recording` (vire la bordure magenta en enregistrement).
   - Pas de logique métier. Testable en widget test (présence du BackdropFilter, couleur
     de bordure selon focused/recording).

2. **`MorphingSendButton`** (`lib/pages/chat/composer/morphing_send_button.dart`)
   - Bouton rond détaché. Quand le champ a du texte (ou edit en cours) → **send** (avion),
     sinon → délègue au `VoiceRecordButton` existant.
   - Morph cercle↔avion via `AnimatedSwitcher` + scale `FluffyCurves.spring`, glow
     gradient cyan→magenta, haptic au tap send.
   - **Ne réimplémente PAS le geste vocal** : il compose `VoiceRecordButton` quand le mode
     est micro. C'est un wrapper de présentation + le bouton send.

3. **`AttachMenuSheet`** (`lib/pages/chat/composer/attach_menu_sheet.dart`)
   - Panneau frosted glass montant (slide-up + fade) déclenché par le `+`.
   - **Grille 3 colonnes** de discs colorés. Items = actions existantes
     (`AddPopupMenuActions` + scheduled). Apparition en **stagger** (cascade).
   - Émet l'action choisie via callback `onAction(AddPopupMenuActions)` →
     réutilise `controller.onAddPopupMenuButtonSelected`. Le `+` morph en `✕`.
   - Implémenté en `showModalBottomSheet` custom (barrier transparent, fond glass) OU
     `OverlayEntry` ancré. Choix : `showModalBottomSheet` (gère le dismiss/back nativement).

4. **`NeonWaveform`** (`lib/widgets/cyber/neon_waveform.dart`)
   - Extrait le rendu des barres d'amplitude de `RecordingInputRow` en widget réutilisable.
   - Barres avec `ShaderMask` gradient cyan→magenta + glow (shadow) sur les pics.
   - Props : `amplitudes`, `maxBarHeight`, `barWidth`. Pur affichage.

### Composants modifiés

- **`ChatInputRow`** : remplace la `Row` interne. Nouvelle structure :
  `[ FrostedComposerSurface( Row[ + , InputBar , 😊 ] ) ][ MorphingSendButton ]`.
  Le `+` ouvre `AttachMenuSheet` au lieu du `PopupMenuButton`. La caméra **sort de la barre**
  (déplacée dans la grille attach pour épurer — décision layout C). `_scheduleSend`
  (long-press) reste sur le `MorphingSendButton` en mode send. Le mode select (forward/delete/
  reply) reste inchangé.
- **`RecordingInputRow`** + **`voice_recording_overlay`** : utilisent `NeonWaveform`, fond
  frosted, bordure magenta en enregistrement. Logique inchangée.
- **`InputBar`** : ajout du glow focus (via `focusNode` déjà présent) — remonté au parent
  `FrostedComposerSurface` par un `ValueListenable<bool>` sur le focus. Vérifier le rendu
  pill des mentions `@` ; styler la pill néon si rendu insuffisant.

## Flux de données

- Le focus du champ (`controller.inputFocus`) pilote `FrostedComposerSurface.focused` →
  glow cyan. Un `FocusNode.addListener` dans `ChatInputRow` expose un `ValueNotifier<bool>`.
- `controller.sendController.text.isNotEmpty` pilote le mode du `MorphingSendButton`
  (send vs micro) — déjà la source de vérité actuelle (`textMessageOnly`).
- L'enregistrement (`recordingViewModel.isRecording/isLocked`) pilote l'état néon
  (bordure magenta, waveform) — déjà câblé via `RecordingViewModel` builder.
- `AttachMenuSheet` → `onAction` → `controller.onAddPopupMenuButtonSelected(action)`.

## Animations (Material 3 Expressive, via tokens existants)

- **Morph send↔micro** : `AnimatedSwitcher` + `ScaleTransition` avec `FluffyCurves.spring`.
- **Glow focus** : `AnimatedContainer` boxShadow cyan, `FluffyDurations.fast`.
- **Attach sheet** : slide-up + fade (`SlideTransition`/`FadeTransition`), items en stagger
  via délais incrémentaux (`Interval` dans un `AnimationController`).
- **Pulse enregistrement** : le `AnimatedScale` 1.4× existant, conservé.
- **Haptics** : `HapticFeedback.lightImpact` au send, `mediumImpact` au lock (déjà là).

## Gestion d'erreur / edge cases

- Permission micro refusée → déjà géré par `RecordingViewModel` (dialog + reset).
- Reload/dispose mid-record → `RecordingViewModel._reset` déjà robuste.
- `BackdropFilter` coûteux : un seul par barre (la pilule), pas par item. Vérifier les
  perfs au scroll (la barre est fixe, donc OK — pas dans une liste).
- Mode select (events sélectionnés) : la barre bascule sur les actions forward/delete/reply
  — `FrostedComposerSurface` n'est pas affiché dans ce mode (inchangé).
- `accessibleNavigation` : le `VoiceRecordButton` a déjà un fallback tap ; `MorphingSendButton`
  doit le préserver (déléguer sans casser).
- Desktop/web (`!isMobile`) : pas de micro → le bouton est toujours send. La grille attach
  s'affiche quand même (location masquée si `!isMobile`, comme aujourd'hui).

## Tests

- `FrostedComposerSurface` : widget test — bordure cyan si `focused`, magenta si `recording`,
  présence d'un `BackdropFilter`.
- `MorphingSendButton` : widget test — icône send si texte non vide, délègue au
  `VoiceRecordButton` si vide ; tap send appelle le callback.
- `AttachMenuSheet` : widget test — 9 items rendus, tap émet la bonne `AddPopupMenuActions`.
- `NeonWaveform` : widget test — n barres pour n amplitudes, hauteur proportionnelle.
- Non-régression : le geste vocal (`voice_record_button`) n'est pas modifié → tests existants
  doivent rester verts.

## Hors scope (explicite)

- Galerie photos inline dans l'attach menu.
- Transcription vocale (Whisper).
- Toolbar de formatage (RTE niveau 2/3), mode plein écran.
- Liquid glass translucide.
- Refonte de la barre SMS (`SmsChatPage`) — autre spec si besoin.

## Critère de succès

1. La barre Matrix a le nouveau look frosted glass néon, le bouton détaché morphant, la
   grille attach 3 colonnes animée, la waveform néon.
2. Aucune régression : envoi texte/image/vidéo/fichier/sondage/lieu, vocal (record/slide/
   lock/send), scheduled (long-press), éphémère, mentions `@`, markdown, multi-compte.
3. `flutter analyze` sans warning, build release OK, installé et testé sur le Pixel.
