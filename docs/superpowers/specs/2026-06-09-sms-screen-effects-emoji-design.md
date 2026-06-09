# Parité effets plein écran + emojis animés dans les rooms SMS

Date : 2026-06-09
Statut : design validé, prêt pour plan d'implémentation

## Contexte

VOX (fork FluffyChat, `eu.devlabz.vox`) possède deux features d'animation dans les
conversations **Matrix** :

1. **Effets plein écran** — pluie, paillettes, bisous (cœurs Lottie), grande fête
   (confettis), neige, feu… déclenchés quand le corps d'un message *est* un emoji
   ou un mot-clé festif. Implémenté dans `lib/utils/screen_effects/` +
   `lib/widgets/cyber/screen_effect_overlay.dart`, câblé côté Matrix dans
   `lib/pages/chat/chat.dart` (controller ligne 110, `_maybePlayScreenEffect`
   ~529-541, `dispose` ~591).
2. **Jumbomoji** — un message de 1-3 emojis seuls est rendu en grand et animé
   (Noto animé). Widget `lib/widgets/cyber/animated_emoji_text.dart`, câblé dans
   `lib/pages/chat/events/message_content.dart` (~284-335) et
   `message_reactions.dart`.

Les **conversations SMS** (`lib/pages/sms_chat/sms_chat_page.dart`, couche native
custom hors timeline Matrix) n'ont **jamais** été câblées à ces deux features
(confirmé par pickaxe git sur `lib/pages/sms_chat/` : aucune occurrence historique
de `ScreenEffectDetector` ni `AnimatedEmojiText`). Les bulles SMS ont été rendues
visuellement identiques aux bulles Matrix, mais la logique d'animation n'a pas
suivi. Ce n'est donc pas une régression — c'est une feature absente sur ce chemin.

## Objectif

Parité comportementale : les rooms SMS déclenchent les mêmes effets plein écran et
affichent les mêmes emojis animés que les rooms Matrix, sans dupliquer de code.

## Principe directeur

Zéro nouveau composant d'animation. On réutilise tel quel :
- `ScreenEffectDetector.detect(String body) : ScreenEffect?` — détection emoji/mot-clé.
- `ScreenEffectController.play(BuildContext, ScreenEffect) : bool` — joue l'effet
  (auto-suffisant : `Confetti.launch(context)` + `Overlay.of(context, rootOverlay: true)`,
  **aucun widget overlay à monter**) ; gère déjà throttle 3s, reduce-motion, anti-doublon.
- `AnimatedEmojiText` + `AnimatedEmojiText.hasAnimatable(body, maxEmojis: 3)`.
- Gate `AppSettings.screenEffectsEnabled` (réglage commun, partagé avec Matrix).

## Design

### A. Effets plein écran (réception + envoi)

Dans `_SmsChatPageState` :
- Champ `final ScreenEffectController _screenEffectController = ScreenEffectController();`
  (miroir de `chat.dart:110`). Appel `_screenEffectController.dispose()` dans `dispose()`.
- Helper :
  ```dart
  void _maybePlayEffect(String body) {
    if (!mounted) return;
    if (!AppSettings.screenEffectsEnabled.value) return;
    final fx = ScreenEffectDetector.detect(body);
    if (fx != null) _screenEffectController.play(context, fx);
  }
  ```
- **Réception** : dans `_listenIncoming`, appeler `_maybePlayEffect(sms.body)` **uniquement
  si le SMS entrant appartient à la conversation actuellement ouverte** (même filtre
  que l'affichage du message dans la room courante).
- **Envoi** : dans `_send`, appeler `_maybePlayEffect(body)` après un envoi réussi, sur
  le corps texte envoyé.

Pas de filtre de récence (un message du listener vient d'arriver, un envoi est immédiat).
Le throttle 3s du contrôleur suffit contre le spam.

### B. Jumbomoji dans les bulles SMS

Dans `_SmsBubble` (rendu d'une bulle SMS), avant le rendu texte (`SelectableLinkify`) :
- Si le message **n'a aucun attachement média MMS** ET `AnimatedEmojiText.hasAnimatable(body)`
  → rendre `AnimatedEmojiText(text: body, size: ...)` avec la **même formule de taille
  que Matrix** (`message_content.dart` : `fontSizeFactor * messageFontSize * 5`).
- Sinon : rendu texte actuel, inchangé.

## Hors-scope (YAGNI)

- Pas de déclenchement manuel (long-press du bouton emoji / `showScreenEffectPicker`) :
  décidé hors scope.
- Pas de modification du composer SMS.
- Pas de réactions emoji animées (les SMS n'ont pas de réactions).

## Tests (TDD)

- Détection emoji/mot-clé : déjà couverte par `screen_effect_detector_test.dart`.
- **Widget test `_SmsBubble`** :
  - `body="❤️"`, sans média → rend `AnimatedEmojiText`.
  - `body="salut"` → rend le texte normal (pas de jumbo).
  - `body="❤️"` **avec** média MMS → rend le texte/média normal (pas de jumbo).
- **Test de décision `_maybePlayEffect`** : respecte le gate `screenEffectsEnabled`
  (off → aucun effet ; on + body déclencheur → effet). Le rendu particules/Lottie
  lui-même n'est pas testé unitairement (overlay/confetti) ; on teste la décision.

## Edge cases gérés

- Effet à la réception limité à la **conversation ouverte** (pas d'effet déclenché par
  un SMS d'une autre conversation).
- Jumbo **uniquement sans média** (un MMS image + emoji reste en rendu normal).
- Throttle 3s anti-spam (contrôleur).
- Reduce-motion respecté (contrôleur : `MediaQuery.disableAnimations`).
- Réglage commun avec Matrix : un seul switch `screenEffectsEnabled`.

## Fichiers touchés (prévisionnel)

- `lib/pages/sms_chat/sms_chat_page.dart` — controller + helper + appels réception/envoi
  + branche jumbomoji dans `_SmsBubble` + imports.
- Test : `test/` — widget test `_SmsBubble` (chemin exact défini au plan).
- Aucune modification des composants d'effet/emoji partagés (réutilisation pure).
