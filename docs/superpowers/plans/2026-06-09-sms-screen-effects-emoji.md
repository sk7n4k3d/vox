# Parité effets plein écran + emojis animés en SMS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déclencher les mêmes effets plein écran et afficher les mêmes emojis animés (jumbomoji) dans les rooms SMS que dans les rooms Matrix, sans dupliquer de code.

**Architecture:** On extrait la logique de décision (quel effet pour un body ? ce body doit-il être un gros emoji animé ?) dans deux fonctions pures publiques et testables (`lib/pages/sms_chat/sms_effects.dart`), puis on les câble dans `SmsChatPage` : un `ScreenEffectController` joué à la réception et à l'envoi, et une branche jumbo dans la bulle SMS. Les composants d'animation (`ScreenEffectDetector`, `ScreenEffectController`, `AnimatedEmojiText`) sont réutilisés tels quels — zéro nouveau composant d'animation.

**Tech Stack:** Flutter / Dart, fvm (flutter SDK `/home/sk7n4k3d/fvm/versions/stable`), `flutter_test`. Lancer les commandes avec `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH"` depuis `/home/sk7n4k3d/Bureau/dev/Applications/fluffychat`.

---

## File Structure

- **Create** `lib/pages/sms_chat/sms_effects.dart` — 2 fonctions pures :
  - `ScreenEffect? smsScreenEffectFor(String body, {required bool effectsEnabled})`
  - `bool smsShouldJumbo({required String body, required bool hasMedia})`
- **Create** `test/sms/sms_effects_test.dart` — tests unitaires des 2 fonctions.
- **Modify** `lib/pages/sms_chat/sms_chat_page.dart` :
  - imports (screen_effect_overlay, animated_emoji_text, sms_effects)
  - `_SmsChatPageState` : champ `ScreenEffectController`, helper `_maybePlayEffect`, appels dans `_listenIncoming` + `_send`, `dispose()`
  - `_SmsBubble._bubbleContent` : branche jumbomoji avant le `SelectableLinkify`

Aucune modification des composants partagés (`screen_effect_detector.dart`, `screen_effect_overlay.dart`, `animated_emoji_text.dart`).

---

## Task 1 : Fonctions de décision pures + tests

**Files:**
- Create: `lib/pages/sms_chat/sms_effects.dart`
- Test: `test/sms/sms_effects_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/sms/sms_effects_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/pages/sms_chat/sms_effects.dart';

void main() {
  group('smsScreenEffectFor', () {
    test('detects a festive emoji when effects are enabled', () {
      expect(smsScreenEffectFor('🎉', effectsEnabled: true), isNotNull);
    });
    test('returns null when effects are disabled (gate)', () {
      expect(smsScreenEffectFor('🎉', effectsEnabled: false), isNull);
    });
    test('returns null for a plain text message', () {
      expect(smsScreenEffectFor('salut ça va', effectsEnabled: true), isNull);
    });
  });

  group('smsShouldJumbo', () {
    test('true for a lone animatable emoji without media', () {
      expect(smsShouldJumbo(body: '😀', hasMedia: false), isTrue);
    });
    test('false for plain text', () {
      expect(smsShouldJumbo(body: 'Bonjour tout le monde', hasMedia: false),
          isFalse);
    });
    test('false when the message carries media (MMS image)', () {
      expect(smsShouldJumbo(body: '😀', hasMedia: true), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && flutter test test/sms/sms_effects_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'fluffychat/pages/sms_chat/sms_effects.dart'` (le fichier source n'existe pas encore).

- [ ] **Step 3: Write minimal implementation**

Create `lib/pages/sms_chat/sms_effects.dart`:

```dart
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect_detector.dart';
import 'package:fluffychat/widgets/cyber/animated_emoji_text.dart';

/// Effet plein écran à jouer pour le corps [body] d'un message SMS, ou null.
/// Respecte le réglage commun [effectsEnabled] (= AppSettings.screenEffectsEnabled),
/// puis délègue la détection emoji/mot-clé au détecteur partagé avec Matrix.
ScreenEffect? smsScreenEffectFor(String body, {required bool effectsEnabled}) {
  if (!effectsEnabled) return null;
  return ScreenEffectDetector.detect(body);
}

/// Vrai si la bulle SMS doit rendre le corps en gros emoji animé (jumbomoji) :
/// le message ne porte aucun média ET son corps est 1-3 emojis animables.
/// Même critère que le chemin Matrix (AnimatedEmojiText.hasAnimatable).
bool smsShouldJumbo({required String body, required bool hasMedia}) {
  if (hasMedia) return false;
  if (body.isEmpty) return false;
  return AnimatedEmojiText.hasAnimatable(body);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && flutter test test/sms/sms_effects_test.dart`
Expected: PASS (6 tests). Si le test `'😀'` jumbo échoue (emoji non couvert par le package `animated_emoji`), remplacer `'😀'` par `'❤️'` dans le test — les deux sont des Noto animated standards ; garder celui qui passe.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/sms_chat/sms_effects.dart test/sms/sms_effects_test.dart
git commit -m "feat(sms): décision effets/jumbomoji extraite et testée (sms_effects)"
```

---

## Task 2 : Jumbomoji dans la bulle SMS

**Files:**
- Modify: `lib/pages/sms_chat/sms_chat_page.dart` (imports + `_SmsBubble._bubbleContent` ~1514)

- [ ] **Step 1: Add imports**

Dans `lib/pages/sms_chat/sms_chat_page.dart`, ajouter aux imports existants (après la ligne 18 `import '...sms/sms_bridge.dart';`) :

```dart
import 'package:fluffychat/pages/sms_chat/sms_effects.dart';
import 'package:fluffychat/widgets/cyber/animated_emoji_text.dart';
```

(`AppConfig` et `AppSettings` sont déjà importés via `app_config.dart` et `setting_keys.dart`.)

- [ ] **Step 2: Replace the text branch with a jumbo-or-text choice**

Dans `_bubbleContent` (~ligne 1514), remplacer le bloc :

```dart
        if (hasText)
          Padding(
            // Same interior padding as the Matrix bubble (16 / 8).
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.sm,
            ),
            child: SelectableLinkify(
```

par (on insère la branche jumbo AVANT le `SelectableLinkify`, en réutilisant le même `Padding`) :

```dart
        if (hasText &&
            smsShouldJumbo(
              body: message.body,
              hasMedia: media.isNotEmpty || files.isNotEmpty,
            ))
          Padding(
            // Gros emoji animé (parité Matrix message_content.dart) : même taille
            // ×5 que la bulle Matrix jumbo.
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.sm,
            ),
            child: AnimatedEmojiText(
              text: message.body,
              size: AppConfig.messageFontSize *
                  AppSettings.fontSizeFactor.value *
                  5,
            ),
          )
        else if (hasText)
          Padding(
            // Same interior padding as the Matrix bubble (16 / 8).
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.sm,
            ),
            child: SelectableLinkify(
```

Le reste du `SelectableLinkify(...)` (lignes 1526-1562) et la fermeture `)` + le `LinkPreviewCard` qui suit restent INCHANGÉS.

- [ ] **Step 3: Verify it compiles**

Run: `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && flutter analyze lib/pages/sms_chat/sms_chat_page.dart`
Expected: pas d'erreur (warnings préexistants tolérés). Vérifier en particulier qu'il n'y a pas de `if/else if` mal apparié.

- [ ] **Step 4: Commit**

```bash
git add lib/pages/sms_chat/sms_chat_page.dart
git commit -m "feat(sms): gros emoji animé (jumbomoji) dans les bulles SMS"
```

---

## Task 3 : Effets plein écran — controller + réception + envoi

**Files:**
- Modify: `lib/pages/sms_chat/sms_chat_page.dart` (import, champ State, helper, `_listenIncoming` ~319, `_send` ~369, `dispose` ~182)

- [ ] **Step 1: Add the controller import**

Ajouter aux imports (sous ceux de la Task 2) :

```dart
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';
```

- [ ] **Step 2: Add the controller field + helper in `_SmsChatPageState`**

Juste après le champ `bool _showEmoji = false;` (~ligne 154), ajouter :

```dart
  /// Effets plein écran (pluie/cœurs/confettis…) — même contrôleur que le chat
  /// Matrix (chat.dart). Throttle 3s, reduce-motion et anti-doublon intégrés.
  final ScreenEffectController _screenEffectController = ScreenEffectController();

  /// Joue l'effet plein écran correspondant au [body] si le réglage est actif.
  void _maybePlayEffect(String body) {
    if (!mounted) return;
    final fx = smsScreenEffectFor(
      body,
      effectsEnabled: AppSettings.screenEffectsEnabled.value,
    );
    if (fx != null) _screenEffectController.play(context, fx);
  }
```

- [ ] **Step 3: Dispose the controller**

Dans `dispose()` (~ligne 182), ajouter avant `super.dispose();` :

```dart
    _screenEffectController.dispose();
```

- [ ] **Step 4: Play on incoming (already filtered to this conversation)**

Dans `_listenIncoming`, le `setState`/ajout est déjà gardé par `if (!sameThread && !sameAddress) return;` (ligne 293) → le message appartient à la conversation ouverte. Ajouter l'appel juste après `_scrollToBottom();` (~ligne 319), à la toute fin du callback `.listen((sms) { ... })` :

```dart
      _scrollToBottom();
      _maybePlayEffect(sms.body);
```

- [ ] **Step 5: Play on send (immediate, optimistic)**

Dans `_send`, jouer l'effet dès l'ajout optimiste (réactivité « j'envoie ❤️ → effet immédiat », sans attendre l'aller-retour réseau). Juste après `_scrollToBottom();` qui suit le `setState` optimiste (~ligne 370) :

```dart
    _scrollToBottom();
    _maybePlayEffect(body);
```

(`body` est la variable locale capturée ligne 324 `final body = _composer.text.trim();`.)

> Note d'écart vs spec : le spec disait « après envoi réussi » ; on le joue à l'optimiste (immédiat) pour l'UX. Si un envoi échoue après coup l'effet aura été joué — coût négligeable, gain de réactivité réel.

- [ ] **Step 6: Verify it compiles**

Run: `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && flutter analyze lib/pages/sms_chat/sms_chat_page.dart`
Expected: pas d'erreur.

- [ ] **Step 7: Run the unit tests (no regression)**

Run: `export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && flutter test test/sms/sms_effects_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 8: Commit**

```bash
git add lib/pages/sms_chat/sms_chat_page.dart
git commit -m "feat(sms): effets plein écran à la réception et à l'envoi"
```

---

## Task 4 : Build, install, validation device

**Files:** aucun (build + test manuel)

- [ ] **Step 1: Build the signed release APK**

Run:
```bash
export PATH="/home/sk7n4k3d/fvm/versions/stable/bin:$PATH" && export JAVA_HOME=/usr/lib/jvm/default
flutter build apk --release
```
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`.

- [ ] **Step 2: Install on the Pixel**

Run:
```bash
export PATH="/home/sk7n4k3d/Android/Sdk/platform-tools:$PATH"
adb -s 10.8.0.31:33153 install -r build/app/outputs/flutter-apk/app-release.apk
```
Expected: `Success`. (Si le device a décroché : `adb mdns services` → `adb connect 10.8.0.31:<port>`.)

- [ ] **Step 3: Manual validation (real device)**

Dans une room SMS :
- Recevoir / s'envoyer « ❤️ » seul → gros cœur animé dans la bulle (jumbomoji) + effet plein écran (cœurs).
- Recevoir / s'envoyer « 🎉 » → confettis. « ✨ » → paillettes.
- Envoyer un texte normal → aucun effet, aucun jumbo.
- Envoyer un MMS image + « ❤️ » → pas de jumbo (texte normal sous l'image).
- Réglage effets désactivé → aucun effet (le jumbo reste, c'est un rendu pas un effet).

---

## Notes pour l'implémenteur

- `flutter test` complet est lourd ; pour ce plan, lancer uniquement `test/sms/sms_effects_test.dart`.
- `_SmsBubble` est une classe **privée** → pas de widget test direct ; la logique jumbo est couverte par `smsShouldJumbo` (Task 1) + validation device (Task 4).
- Ne PAS toucher aux composants partagés (`screen_effect_*.dart`, `animated_emoji_text.dart`) : la parité vient de leur réutilisation.
- Réglage : `AppSettings.screenEffectsEnabled` (`lib/config/setting_keys.dart:37`, défaut `true`).
