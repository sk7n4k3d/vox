# Effets plein écran — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Animations plein écran (confettis néon + Lottie riches) déclenchées par emoji/mot-clé festif seul ou choix manuel, dans les rooms Matrix de Vox.

**Architecture:** Détecteur pur (testable) → controller d'overlay (throttle + accessibilité) branché sur le `onInsert` de la timeline Matrix. Choix manuel via long-press sur le bouton emoji existant qui insère l'emoji déclencheur (détection locale, pas de protocole custom).

**Tech Stack:** Flutter/Dart, `flutter_confetti` (MIT, à ajouter), `lottie` (déjà présent), tokens CYBERCORE, `AppSettings` enum, `flutter_test`. Test : `/home/sk7n4k3d/fvm/versions/stable/bin/flutter`.

**Ancrages vérifiés :**
- `getTimeline({onInsert: void Function(int insertID)?})` existe (SDK patché room.dart:1664).
- `AppSettings` = enum, entrée `name<bool>('key', default)` (setting_keys.dart:30+).
- Bouton emoji : `IconButton(onPressed: controller.emojiPickerAction)` dans chat_input_row.dart:311.
- Assets pubspec déclarés sous `assets:` (pubspec.yaml:112).

---

## File Structure

| Fichier | Rôle |
|---|---|
| `lib/utils/screen_effects/screen_effect.dart` (créer) | enum ScreenEffect + métadonnées (rendu, asset, label, emoji) |
| `lib/utils/screen_effects/screen_effect_detector.dart` (créer) | `detect(body)` pur → ScreenEffect? |
| `lib/widgets/cyber/screen_effect_overlay.dart` (créer) | ScreenEffectController (play/throttle/overlay) + ScreenEffectPickerSheet |
| `lib/pages/chat/chat.dart` (modifier) | hook `onInsert` → `_maybePlayScreenEffect` |
| `lib/pages/chat/chat_input_row.dart` (modifier) | `onLongPress` bouton emoji → picker d'effets |
| `lib/config/setting_keys.dart` (modifier) | `screenEffectsEnabled` |
| `pubspec.yaml` (modifier) | `flutter_confetti` + `assets/effects/` |
| `assets/effects/*.json` (ajouter) | Lottie bundlées (fireworks, hearts, snow, balloons, celebration) |
| `test/screen_effects/screen_effect_detector_test.dart` (créer) | détecteur |
| `test/screen_effects/screen_effect_controller_test.dart` (créer) | throttle + accessibilité |

---

## Task 1: enum ScreenEffect + métadonnées

**Files:**
- Create: `lib/utils/screen_effects/screen_effect.dart`

- [ ] **Step 1: Implémenter**

```dart
// lib/utils/screen_effects/screen_effect.dart

/// Mode de rendu d'un effet plein écran.
enum ScreenEffectRender { particles, lottie }

/// Les effets plein écran disponibles (style iMessage/Telegram).
enum ScreenEffect {
  confetti,
  fireworks,
  hearts,
  snow,
  balloons,
  celebration,
}

extension ScreenEffectMeta on ScreenEffect {
  ScreenEffectRender get render => switch (this) {
        ScreenEffect.confetti => ScreenEffectRender.particles,
        _ => ScreenEffectRender.lottie,
      };

  /// Chemin de l'asset Lottie (vide pour les effets en particules).
  String get assetPath => switch (this) {
        ScreenEffect.confetti => '',
        ScreenEffect.fireworks => 'assets/effects/fireworks.json',
        ScreenEffect.hearts => 'assets/effects/hearts.json',
        ScreenEffect.snow => 'assets/effects/snow.json',
        ScreenEffect.balloons => 'assets/effects/balloons.json',
        ScreenEffect.celebration => 'assets/effects/celebration.json',
      };

  /// Emoji représentatif (vignette du menu manuel + insertion déclencheur).
  String get emoji => switch (this) {
        ScreenEffect.confetti => '🎉',
        ScreenEffect.fireworks => '🎆',
        ScreenEffect.hearts => '❤️',
        ScreenEffect.snow => '❄️',
        ScreenEffect.balloons => '🎂',
        ScreenEffect.celebration => '🥳',
      };

  /// Libellé FR pour le menu manuel.
  String get label => switch (this) {
        ScreenEffect.confetti => 'Confettis',
        ScreenEffect.fireworks => 'Feux d\'artifice',
        ScreenEffect.hearts => 'Cœurs',
        ScreenEffect.snow => 'Neige',
        ScreenEffect.balloons => 'Ballons',
        ScreenEffect.celebration => 'Fête',
      };
}
```

- [ ] **Step 2: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/utils/screen_effects/screen_effect.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/utils/screen_effects/screen_effect.dart
git commit -m "feat(effects): enum ScreenEffect + métadonnées (rendu/asset/emoji/label)"
```

---

## Task 2: ScreenEffectDetector (pur, testé)

**Files:**
- Create: `lib/utils/screen_effects/screen_effect_detector.dart`
- Test: `test/screen_effects/screen_effect_detector_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/screen_effects/screen_effect_detector_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect_detector.dart';

void main() {
  test('emoji festif seul → effet', () {
    expect(ScreenEffectDetector.detect('🎉'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('🎂'), ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('🎆'), ScreenEffect.fireworks);
    expect(ScreenEffectDetector.detect('❤️'), ScreenEffect.hearts);
    expect(ScreenEffectDetector.detect('❄️'), ScreenEffect.snow);
    expect(ScreenEffectDetector.detect('🥳'), ScreenEffect.celebration);
  });

  test('emoji entouré d\'espaces toléré', () {
    expect(ScreenEffectDetector.detect('  🎉 '), ScreenEffect.confetti);
  });

  test('mot-clé FR/EN seul → effet', () {
    expect(ScreenEffectDetector.detect('Joyeux anniversaire'),
        ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('happy birthday'),
        ScreenEffect.balloons);
    expect(ScreenEffectDetector.detect('Félicitations'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('BRAVO'), ScreenEffect.confetti);
    expect(ScreenEffectDetector.detect('Bonne année'), ScreenEffect.fireworks);
  });

  test('texte autour du trigger → null', () {
    expect(ScreenEffectDetector.detect('bravo à tous'), isNull);
    expect(ScreenEffectDetector.detect('regarde 🎉 ce truc'), isNull);
  });

  test('contenu non festif → null', () {
    expect(ScreenEffectDetector.detect('bonjour'), isNull);
    expect(ScreenEffectDetector.detect('😀'), isNull);
    expect(ScreenEffectDetector.detect(''), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/screen_effects/screen_effect_detector_test.dart`
Expected: FAIL (ScreenEffectDetector introuvable).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/utils/screen_effects/screen_effect_detector.dart
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';

/// Détecte un effet plein écran à partir du corps d'un message. Ne déclenche que
/// si le message EST exactement un emoji festif ou un mot-clé connu (rien autour).
/// Fonction pure → testable sans Flutter.
abstract class ScreenEffectDetector {
  static const Map<String, ScreenEffect> _byEmoji = {
    '🎉': ScreenEffect.confetti,
    '🎊': ScreenEffect.confetti,
    '🎂': ScreenEffect.balloons,
    '🎈': ScreenEffect.balloons,
    '🎆': ScreenEffect.fireworks,
    '🎇': ScreenEffect.fireworks,
    '❤️': ScreenEffect.hearts,
    '😍': ScreenEffect.hearts,
    '🥰': ScreenEffect.hearts,
    '❄️': ScreenEffect.snow,
    '🎄': ScreenEffect.snow,
    '🥳': ScreenEffect.celebration,
  };

  static const Map<String, ScreenEffect> _byKeyword = {
    'joyeux anniversaire': ScreenEffect.balloons,
    'happy birthday': ScreenEffect.balloons,
    'félicitations': ScreenEffect.confetti,
    'felicitations': ScreenEffect.confetti,
    'bravo': ScreenEffect.confetti,
    'congratulations': ScreenEffect.confetti,
    'bonne année': ScreenEffect.fireworks,
    'bonne annee': ScreenEffect.fireworks,
    'happy new year': ScreenEffect.fireworks,
    "je t'aime": ScreenEffect.hearts,
    'i love you': ScreenEffect.hearts,
  };

  static ScreenEffect? detect(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    // Emoji seul (exactement le cluster, espaces déjà retirés).
    final emoji = _byEmoji[trimmed];
    if (emoji != null) return emoji;
    // Mot-clé seul (insensible à la casse).
    return _byKeyword[trimmed.toLowerCase()];
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/screen_effects/screen_effect_detector_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/utils/screen_effects/screen_effect_detector.dart test/screen_effects/screen_effect_detector_test.dart
git commit -m "feat(effects): ScreenEffectDetector — emoji/mot-clé festif seul → effet"
```

---

## Task 3: Ajouter flutter_confetti + dossier assets

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Ajouter la dépendance**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter pub add flutter_confetti`
Expected: ajoute `flutter_confetti: ^0.5.1` (ou version résolue) dans pubspec.yaml.

- [ ] **Step 2: Déclarer le dossier d'assets effets**

Dans `pubspec.yaml`, sous la clé `assets:` (vers la ligne 112), ajouter après `- assets/vodozemac/` :
```yaml
    - assets/effects/
```

- [ ] **Step 3: Créer le dossier (placeholder pour que pub n'échoue pas)**

Run: `mkdir -p assets/effects`
(Les vrais .json Lottie sont posés à la Task 4.)

- [ ] **Step 4: Vérifier la résolution**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter pub get`
Expected: résolution OK (pas d'erreur ; un dossier assets vide est toléré tant qu'il existe).

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "build(effects): ajoute flutter_confetti + dossier assets/effects"
```

---

## Task 4: Récupérer et bundler les Lottie (Simple License)

**Files:**
- Add: `assets/effects/{fireworks,hearts,snow,balloons,celebration}.json`

- [ ] **Step 1: Valider la licence puis télécharger**

Pour chaque effet (fireworks, hearts, snow, balloons, celebration), récupérer une
animation Lottie depuis LottieFiles filtrée **"Lottie Simple License"** (usage
commercial OK, sans attribution obligatoire). AVANT de bundler : confirmer le wording
de la licence sur la page de l'asset (commercial autorisé, pas "Individual/Free Plan
non-commercial"). Télécharger le `.json` (pas le `.lottie` zippé) via le bouton
download de LottieFiles ou l'URL `lottie.host`.

Placer chaque fichier sous le nom exact attendu par `ScreenEffectMeta.assetPath` :
`assets/effects/fireworks.json`, `hearts.json`, `snow.json`, `balloons.json`,
`celebration.json`.

- [ ] **Step 2: Vérifier que ce sont des Lottie JSON valides**

Run:
```bash
for f in fireworks hearts snow balloons celebration; do
  head -c 60 "assets/effects/$f.json"; echo " ← $f"
done
```
Expected: chaque fichier commence par `{"v":` ou `{"nm":`/`{"fr":` (en-tête Lottie JSON).

- [ ] **Step 3: Commit**

```bash
git add assets/effects/*.json
git commit -m "assets(effects): Lottie plein écran (Lottie Simple License, commercial OK)"
```

---

## Task 5: AppSettings.screenEffectsEnabled

**Files:**
- Modify: `lib/config/setting_keys.dart`

- [ ] **Step 1: Ajouter l'entrée enum**

Dans l'enum `AppSettings`, après `swipeRightToLeftToReply<bool>(...)` (vers la ligne 36), ajouter :
```dart
  screenEffectsEnabled<bool>('chat.fluffy.screen_effects_enabled', true),
```

- [ ] **Step 2: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/config/setting_keys.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/config/setting_keys.dart
git commit -m "feat(effects): réglage screenEffectsEnabled (défaut true)"
```

---

## Task 6: ScreenEffectController + overlay + picker

**Files:**
- Create: `lib/widgets/cyber/screen_effect_overlay.dart`
- Test: `test/screen_effects/screen_effect_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/screen_effects/screen_effect_controller_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';

void main() {
  testWidgets('throttle: 2e play immédiat est ignoré', (tester) async {
    final ctrl = ScreenEffectController(throttle: const Duration(seconds: 3));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    );
    expect(ctrl.play(ctx, ScreenEffect.confetti), isTrue);
    expect(ctrl.play(ctx, ScreenEffect.confetti), isFalse); // throttlé
    ctrl.dispose();
  });

  testWidgets('skip si animations désactivées', (tester) async {
    final ctrl = ScreenEffectController();
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ),
      ),
    );
    expect(ctrl.play(ctx, ScreenEffect.confetti), isFalse);
    ctrl.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/screen_effects/screen_effect_controller_test.dart`
Expected: FAIL (ScreenEffectController introuvable).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/widgets/cyber/screen_effect_overlay.dart
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:lottie/lottie.dart';

/// Joue les effets plein écran avec throttle, unicité et respect du reduce-motion.
/// Retourne true si l'effet a été lancé, false s'il a été ignoré (throttle /
/// déjà actif / animations désactivées). Non-widget : un par ChatController.
class ScreenEffectController {
  final Duration throttle;
  DateTime? _lastPlayed;
  OverlayEntry? _activeEntry;
  AnimationController? _activeAnim;

  ScreenEffectController({this.throttle = const Duration(seconds: 3)});

  bool play(BuildContext context, ScreenEffect effect) {
    if (MediaQuery.of(context).disableAnimations) return false;
    if (_activeEntry != null) return false;
    final now = DateTime.now();
    if (_lastPlayed != null && now.difference(_lastPlayed!) < throttle) {
      return false;
    }
    _lastPlayed = now;

    if (effect.render == ScreenEffectRender.particles) {
      final cyber = CyberColors.of(context);
      Confetti.launch(
        context,
        options: ConfettiOptions(
          particleCount: 80,
          spread: 70,
          y: 0.6,
          colors: [cyber.cyan, cyber.magenta, Colors.white],
        ),
      );
      return true;
    }

    // Lottie plein écran en overlay, IgnorePointer, auto-dismiss.
    final overlay = Overlay.of(context, rootOverlay: true);
    final anim = AnimationController(vsync: overlay);
    _activeAnim = anim;
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: SizedBox.expand(
          child: Lottie.asset(
            effect.assetPath,
            controller: anim,
            fit: BoxFit.cover,
            onLoaded: (composition) {
              anim
                ..duration = composition.duration
                ..forward().whenComplete(_clearActive);
            },
            errorBuilder: (_, __, ___) {
              // Asset manquant/corrompu : on annule proprement après ce frame.
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _clearActive());
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
    return true;
  }

  void _clearActive() {
    _activeEntry?.remove();
    _activeEntry = null;
    _activeAnim?.dispose();
    _activeAnim = null;
  }

  void dispose() => _clearActive();
}

/// Bottom-sheet de choix manuel : tape un effet → insère son emoji déclencheur
/// dans le composer (détection locale → l'effet se joue chez les deux).
Future<ScreenEffect?> showScreenEffectPicker(BuildContext context) {
  return showModalBottomSheet<ScreenEffect>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final e in ScreenEffect.values)
              InkWell(
                key: ValueKey('effect_${e.name}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).pop(e);
                },
                child: Container(
                  width: 92,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(e.emoji, style: const TextStyle(fontSize: 28)),
                      const SizedBox(height: 6),
                      Text(e.label,
                          style: Theme.of(context).textTheme.labelSmall,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/screen_effects/screen_effect_controller_test.dart`
Expected: PASS (les deux cas : throttle + reduce-motion renvoient false).

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/cyber/screen_effect_overlay.dart test/screen_effects/screen_effect_controller_test.dart
git commit -m "feat(effects): ScreenEffectController (confetti+Lottie, throttle, reduce-motion) + picker"
```

---

## Task 7: Hook timeline dans ChatController

**Files:**
- Modify: `lib/pages/chat/chat.dart`

- [ ] **Step 1: Ajouter le controller + le hook**

Dans la classe `ChatController`, ajouter un champ :
```dart
  final ScreenEffectController screenEffectController = ScreenEffectController();
```
Dans `dispose()` du controller (chercher la méthode `dispose`), ajouter :
```dart
    screenEffectController.dispose();
```

- [ ] **Step 2: Brancher onInsert sur getTimeline**

Dans `_getTimeline` (chat.dart:489), modifier les DEUX appels `room.getTimeline(onUpdate: updateView, ...)` pour ajouter `onInsert` :
```dart
      timeline = await room.getTimeline(
        onUpdate: updateView,
        onInsert: _maybePlayScreenEffect,
        eventContextId: eventContextId,
      );
```
et le fallback :
```dart
      timeline = await room.getTimeline(
        onUpdate: updateView,
        onInsert: _maybePlayScreenEffect,
      );
```

- [ ] **Step 3: Implémenter _maybePlayScreenEffect**

Ajouter dans `ChatController` :
```dart
  /// Joue un effet plein écran si l'event inséré est un message RÉCENT dont le
  /// corps est un déclencheur (emoji/mot-clé festif seul). Le garde « récent »
  /// évite le déluge d'effets au premier sync / scroll-back de l'historique.
  void _maybePlayScreenEffect(int insertID) {
    if (!mounted) return;
    if (!AppSettings.screenEffectsEnabled.value) return;
    final tl = timeline;
    if (tl == null || insertID < 0 || insertID >= tl.events.length) return;
    final event = tl.events[insertID];
    if (event.type != EventTypes.Message) return;
    final age = DateTime.now().difference(event.originServerTs);
    if (age > const Duration(seconds: 10)) return;
    final effect = ScreenEffectDetector.detect(event.body);
    if (effect == null) return;
    screenEffectController.play(context, effect);
  }
```

- [ ] **Step 4: Ajouter les imports**

En tête de `chat.dart`, ajouter :
```dart
import 'package:fluffychat/utils/screen_effects/screen_effect_detector.dart';
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';
```
(`AppSettings`, `EventTypes`, `event.body`, `event.originServerTs` sont déjà disponibles via les imports existants.)

- [ ] **Step 5: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/chat.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add lib/pages/chat/chat.dart
git commit -m "feat(effects): déclenche les effets sur message récent (timeline onInsert)"
```

---

## Task 8: Long-press bouton emoji → picker d'effets

**Files:**
- Modify: `lib/pages/chat/chat_input_row.dart`

- [ ] **Step 1: Ajouter l'action long-press**

Dans `_ChatInputRowState`, ajouter une méthode :
```dart
  /// Long-press sur le bouton emoji : choisir un effet plein écran → insère son
  /// emoji déclencheur dans le composer (la détection locale jouera l'effet à
  /// l'envoi, chez l'expéditeur ET le destinataire).
  Future<void> _pickScreenEffect() async {
    final effect = await showScreenEffectPicker(context);
    if (effect == null || !mounted) return;
    final c = controller.sendController;
    final sep = c.text.isEmpty ? '' : ' ';
    c.text = '${c.text}$sep${effect.emoji}';
    c.selection =
        TextSelection.collapsed(offset: c.text.length);
    controller.inputFocus.requestFocus();
  }
```

- [ ] **Step 2: Envelopper le bouton emoji dans un GestureDetector long-press**

Repérer l'`IconButton` du bouton emoji (`onPressed: controller.emojiPickerAction`, icône `add_reaction_outlined`/`keyboard`). L'envelopper :
```dart
                            GestureDetector(
                              onLongPress: _pickScreenEffect,
                              child: IconButton(
                                tooltip: L10n.of(context).emojis,
                                color: theme.colorScheme.onPrimaryContainer,
                                icon: Icon(
                                  controller.showEmojiPicker
                                      ? Icons.keyboard
                                      : Icons.add_reaction_outlined,
                                  key: ValueKey(controller.showEmojiPicker),
                                ),
                                onPressed: controller.emojiPickerAction,
                              ),
                            ),
```

- [ ] **Step 3: Ajouter l'import**

En tête de `chat_input_row.dart` :
```dart
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';
```

- [ ] **Step 4: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/chat_input_row.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/chat_input_row.dart
git commit -m "feat(effects): long-press bouton emoji → choix manuel d'effet plein écran"
```

---

## Task 9: Toggle dans les réglages chat

**Files:**
- Modify: l'écran de réglages chat (à localiser).

- [ ] **Step 1: Localiser l'écran de réglages chat**

Run:
```bash
grep -rln "swipeRightToLeftToReply\|sendOnEnter\|SettingsSwitchListTile\|AppSettings.autoplayImages" lib/pages/settings_chat/ lib/pages/ 2>/dev/null | head
```
Identifier le fichier où les bascules booléennes de chat sont rendues (même pattern que `autoplayImages`/`sendOnEnter`).

- [ ] **Step 2: Ajouter la bascule**

Sur le modèle EXACT d'une bascule existante (ex. `autoplayImages`), ajouter une entrée pour `AppSettings.screenEffectsEnabled` avec le libellé « Effets plein écran ». Réutiliser le widget de switch déjà utilisé dans ce fichier (ne pas inventer un nouveau composant).

- [ ] **Step 3: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze <fichier réglages modifié>`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add <fichier réglages>
git commit -m "feat(effects): bascule 'Effets plein écran' dans les réglages chat"
```

---

## Task 10: Validation finale

**Files:** aucun (vérification)

- [ ] **Step 1: Analyze global**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/utils/screen_effects/ lib/widgets/cyber/screen_effect_overlay.dart lib/pages/chat/`
Expected: No issues found.

- [ ] **Step 2: Tests effets**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/screen_effects/`
Expected: All tests passed.

- [ ] **Step 3: Build release**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter build apk --release`
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`.

- [ ] **Step 4: Install Pixel**

Run:
```bash
adb connect 10.8.0.31:37719
adb -s 10.8.0.31:37719 install -r build/app/outputs/flutter-apk/app-release.apk
```
Expected: `Success`. (Si le port a changé, demander le nouveau.)

- [ ] **Step 5: Vérif manuelle sur device**

Checklist : envoyer `🎉` seul → confettis néon ; `🎂` seul → ballons (Lottie) ;
« joyeux anniversaire » seul → ballons ; texte normal → rien ; long-press bouton
emoji → menu → choix → emoji inséré → effet à l'envoi ; pas d'effet au scroll-back ;
rafale de 🎉 → un seul effet (throttle) ; toggle off → plus d'effet.
