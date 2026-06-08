# Effets plein écran (Screen Effects) — Design

**Date** : 2026-06-08
**Branche** : `feature/ux-refonte`
**Statut** : design validé (brainstorming), en attente de plan

## Objectif

Ajouter des animations plein écran façon iMessage/Telegram aux rooms Matrix de
Vox : confettis et animations Lottie riches (feux d'artifice, cœurs, neige,
ballons, fête) déclenchées par un emoji festif seul, un mot-clé FR/EN seul, ou un
choix manuel. Esthétique CYBERCORE (couleurs néon cyan/magenta sur les confettis).

## Périmètre validé (décisions du brainstorming)

| Sujet | Décision |
|---|---|
| Scope | Confettis (particules code) **+** Lottie riches **+** choix manuel |
| Déclenchement | Emoji festif seul **+** mots-clés FR/EN seuls (message == trigger seul) |
| Sync expéditeur↔destinataire | **Détection locale** : chaque client détecte le même body → même effet. Pas de champ custom Matrix. |
| Assets Lottie | **LottieFiles "Lottie Simple License" bundlés** dans l'APK (commercial OK, sans attribution ; wording validé avant intégration). |
| Confettis | `flutter_confetti` (MIT), particules en code, couleurs néon. Aucun asset. |
| Choix manuel | **Long-press sur le bouton emoji existant** → menu des effets (tap = picker emoji, inchangé). |
| Toggle | `AppSettings.screenEffectsEnabled` (défaut true). |
| Accessibilité | Skip si `MediaQuery.disableAnimations` OU toggle off. |
| Anti-spam | Throttle 3 s + un seul effet à la fois. |
| Anti-historique | Ne déclenche que sur events récents (`originServerTs` > now − 10 s). |
| Périmètre | Rooms **Matrix** uniquement (pas SMS). |

## État du code (vérifié)

- `lib/pages/chat/chat.dart:498-505` — `room.getTimeline(onUpdate: updateView)`.
  Le SDK patché (`../matrix-dart-sdk-patched/lib/src/room.dart:1664`) expose
  `getTimeline({onInsert: void Function(int insertID)?, onNewEvent, ...})`.
  → point d'ancrage du déclenchement automatique.
- `lib/pages/chat/chat_input_row.dart` — bouton emoji (`IconButton`,
  `add_reaction_outlined` ↔ `keyboard`, `onPressed: controller.emojiPickerAction`)
  dans la pilule frosted glass. → on y ajoute un `onLongPress`.
- `lib/config/setting_keys.dart` — `AppSettings` (pattern de réglages typés).
  → ajout de `screenEffectsEnabled`.
- `pubspec.yaml` — `lottie` déjà présent (tiré par `animated_emoji`).
  → ajouter `flutter_confetti`.

## Architecture (composants isolés)

### 1. `ScreenEffect` — `lib/utils/screen_effects/screen_effect.dart`
`enum ScreenEffect { confetti, fireworks, hearts, snow, balloons, celebration }`
+ extension décrivant pour chacun : le **mode de rendu** (`particles` pour
confetti, `lottie` pour les autres), le **chemin d'asset Lottie** (`assets/effects/<name>.json`),
et un **label** + emoji d'aperçu pour le menu manuel. Pas de logique. Testable.

### 2. `ScreenEffectDetector` — `lib/utils/screen_effects/screen_effect_detector.dart`
Fonction pure `ScreenEffect? detect(String body)` :
- normalise (`trim().toLowerCase()` pour les mots-clés ; `trim()` pour les emojis).
- table emoji → effet : `🎉🎊→confetti`, `🎂🎈→balloons`, `🎆🎇→fireworks`,
  `❤️😍🥰→hearts`, `❄️🎄→snow`, `🥳→celebration` (emoji seul, 1 cluster).
- table mots-clés (FR+EN) → effet : `joyeux anniversaire`/`happy birthday`→balloons,
  `félicitations`/`bravo`/`congratulations`→confetti,
  `bonne année`/`happy new year`→fireworks, `je t'aime`/`i love you`→hearts.
- renvoie `null` si le body n'est pas **exactement** un trigger (texte autour → null).
- Aucune dépendance Flutter → 100 % testable unitairement.

### 3. `ScreenEffectController` + `ScreenEffectOverlay` — `lib/widgets/cyber/screen_effect_overlay.dart`
`ScreenEffectController` (objet, pas widget) :
- `play(BuildContext, ScreenEffect)` :
  - garde-fous : ignore si `< _throttle` (3 s) depuis le dernier, ou si un effet
    est déjà actif, ou si `MediaQuery.disableAnimations`.
  - `confetti` → `Confetti.launch(context, options: ...)` (couleurs
    `CyberColors.cyan`/`.magenta`, auto-dismiss).
  - `lottie` → insère un `OverlayEntry` plein écran : `IgnorePointer` +
    `Lottie.asset(path, controller, fit: BoxFit.cover, errorBuilder: → remove)`,
    `controller.forward().whenComplete(() => entry.remove())`.
  - `_lastPlayed` (timestamp) pour le throttle ; `_activeEntry` pour l'unicité.
- `dispose()` retire un overlay actif (anti-fuite).

### 4. Hook timeline — modif `ChatController._getTimeline` (`chat.dart`)
Ajout d'un paramètre `onInsert` au `getTimeline` :
```
onInsert: (insertID) => _maybePlayScreenEffect(insertID),
```
`_maybePlayScreenEffect(int insertID)` :
- `if (!AppSettings.screenEffectsEnabled.value) return;`
- `final event = timeline.events[insertID];` (borne l'index)
- garde **anti-historique** : `event.originServerTs` postérieur à
  `DateTime.now() - const Duration(seconds: 10)`, sinon return.
- `final effect = ScreenEffectDetector.detect(event.body);`
- `if (effect != null) _screenEffectController.play(context, effect);`

### 5. Choix manuel — `ScreenEffectPickerSheet` (`screen_effect_overlay.dart`)
`onLongPress` sur le bouton emoji de `ChatInputRow` → `showModalBottomSheet`
listant les 6 effets (vignette emoji + label, style frosted glass). Au choix :
**insère l'emoji déclencheur** correspondant dans `controller.sendController`
(ex. effet hearts → insère `❤️`) puis ferme la feuille. L'utilisateur envoie
normalement ; la détection locale joue l'effet chez les deux interlocuteurs.
Aucun champ custom Matrix.

### 6. Toggle réglages — `AppSettings.screenEffectsEnabled`
Bool typé (défaut `true`) dans `setting_keys.dart`, exposé dans les réglages chat
(case à cocher « Effets plein écran »).

## Flux de données

```
message inséré → Timeline.onInsert(insertID)
  → guard screenEffectsEnabled + event récent (<10s) + !disableAnimations
  → ScreenEffectDetector.detect(body) → ScreenEffect?
  → throttle 3s + un seul actif → ScreenEffectController.play
      → confetti : Confetti.launch (néon, auto-dismiss)
      → lottie   : OverlayEntry plein écran IgnorePointer, retiré à la fin
```

## Gestion d'erreur / edge cases

- **Anti-historique** (critique) : `onInsert` est appelé pour de vieux events au
  premier sync / scroll-back → le guard `originServerTs récent` les écarte.
- **Anti-spam** : throttle 3 s + `_activeEntry` unique → pas d'overlays empilés.
- **Asset Lottie manquant/corrompu** : `errorBuilder` retire l'overlay, effet annulé
  silencieusement (assets bundlés → pas de dépendance réseau).
- **Accessibilité** : `disableAnimations` (système) OU toggle off → skip total.
- **dispose mid-effet** : controller retire l'`OverlayEntry` au dispose.
- **Faux positifs** : `detect` exige body == trigger seul (« bravo » seul oui,
  « bravo à tous » non).

## Tests

- `screen_effect_detector_test.dart` (unitaire — le cœur) : chaque emoji festif
  seul → bon effet ; chaque mot-clé FR/EN seul → bon effet ; texte autour → null ;
  casse/espaces tolérés ; emoji/mot non festif → null.
- `screen_effect_controller_test.dart` (widget) : 2e `play` < 3 s ignoré
  (throttle) ; skip si `disableAnimations` ; `play` confetti ne throw pas.
- Pas de test du rendu Lottie/confetti (visuel pur, vérifié sur device).

## Hors scope

- Champ custom Matrix `effect` (sync protocolaire fidèle iMessage) — détection
  locale suffit.
- Effets bulle (sur la bulle seule) — seulement plein écran.
- Effets sur SMS.
- Effets sur réactions (déjà couvert par les emojis animés d'une autre feature).

## Critère de succès

1. Envoyer/recevoir `🎉` seul ou « joyeux anniversaire » seul joue l'effet plein
   écran chez les deux interlocuteurs.
2. Long-press bouton emoji → menu → choix → insère l'emoji → effet au prochain envoi.
3. Aucun effet au démarrage/scroll-back (anti-historique), pas d'empilement (throttle),
   skip si animations réduites ou toggle off.
4. `flutter analyze` clean, détecteur couvert par tests, build + install Pixel OK.
