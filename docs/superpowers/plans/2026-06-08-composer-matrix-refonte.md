# Refonte composer Matrix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refondre la barre de saisie des rooms Matrix en frosted glass néon avec bouton micro/send détaché morphant, attach menu en grille animée, et waveform néon — sans casser la logique existante.

**Architecture:** Composants de présentation isolés sous `lib/pages/chat/composer/` et `lib/widgets/cyber/`, composés dans `ChatInputRow`. La logique métier (vocal, actions, scheduled) est réutilisée telle quelle via le `ChatController` existant. Le geste vocal (`VoiceRecordButton`) n'est PAS réimplémenté, juste enveloppé.

**Tech Stack:** Flutter/Dart, design tokens CYBERCORE existants (`CyberColors`, `FluffyDurations`, `FluffyCurves.spring`, `FluffyRadius`, `FluffySpacing`), `flutter_test` (widget tests).

**Note TDD :** Sur le polish purement visuel (BackdropFilter, gradients, glow), un test-first apporte peu — ces étapes sont implémentées puis vérifiées à l'œil sur device. Les tests ciblent la **logique testable** : mode du bouton (send vs micro), mapping action→callback de la grille, nombre/hauteur de barres de la waveform. Commande de test projet : `fvm flutter test <fichier>` (binaire : `/home/sk7n4k3d/fvm/versions/stable/bin/flutter`).

**Enum réel disponible** (`lib/pages/chat/chat.dart:1500`) :
`AddPopupMenuActions { image, video, file, poll, photoCamera, videoCamera, location, ephemeral }`.
La grille attach expose ces actions (pas de "contact" ni "galerie" distincte — `image` = galerie système ; `scheduled` reste un long-press sur le bouton send, hors grille).

---

## File Structure

| Fichier | Rôle |
|---|---|
| `lib/widgets/cyber/frosted_composer_surface.dart` (créer) | Pilule frosted glass réutilisable, glow focus/recording |
| `lib/widgets/cyber/neon_waveform.dart` (créer) | Rendu waveform gradient + glow, réutilisable |
| `lib/pages/chat/composer/morphing_send_button.dart` (créer) | Bouton détaché : send (avion) ou délègue au VoiceRecordButton |
| `lib/pages/chat/composer/attach_menu_sheet.dart` (créer) | Bottom-sheet grille 3 colonnes animée (stagger) |
| `lib/pages/chat/chat_input_row.dart` (modifier) | Recompose la barre avec les nouveaux composants |
| `lib/pages/chat/recording_input_row.dart` (modifier) | Utilise NeonWaveform, fond frosted |
| `lib/pages/chat/voice_recording_overlay.dart` (modifier) | Restyle néon (lecture seule ici, ajusté en Task 7) |
| `test/composer/morphing_send_button_test.dart` (créer) | Mode send/micro |
| `test/composer/attach_menu_sheet_test.dart` (créer) | Items + mapping action |
| `test/widgets/cyber/neon_waveform_test.dart` (créer) | Barres |

---

## Task 1: NeonWaveform (widget réutilisable)

**Files:**
- Create: `lib/widgets/cyber/neon_waveform.dart`
- Test: `test/widgets/cyber/neon_waveform_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/widgets/cyber/neon_waveform_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/widgets/cyber/neon_waveform.dart';

void main() {
  testWidgets('renders one bar per amplitude', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NeonWaveform(
            amplitudes: [10, 50, 90, 30],
            maxBarHeight: 36,
            barWidth: 4,
          ),
        ),
      ),
    );
    // Chaque barre est un Container avec une key indexée.
    expect(find.byKey(const ValueKey('wave_bar_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wave_bar_3')), findsOneWidget);
    expect(find.byKey(const ValueKey('wave_bar_4')), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/widgets/cyber/neon_waveform_test.dart`
Expected: FAIL (NeonWaveform introuvable).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/widgets/cyber/neon_waveform.dart
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:flutter/material.dart';

/// Waveform néon : barres d'amplitude avec dégradé cyan→magenta et glow sur les
/// pics. Pur affichage (aucune logique d'enregistrement). [amplitudes] est une
/// liste de valeurs ~0..100 (cf. RecordingViewModel.amplitudeTimeline).
class NeonWaveform extends StatelessWidget {
  final List<double> amplitudes;
  final double maxBarHeight;
  final double barWidth;

  const NeonWaveform({
    required this.amplitudes,
    this.maxBarHeight = 36,
    this.barWidth = 4,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber =
        Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < amplitudes.length; i++)
          _bar(cyber, i, amplitudes[i]),
      ],
    );
  }

  Widget _bar(CyberpunkTheme cyber, int i, double amplitude) {
    final h = (maxBarHeight * (amplitude / 100)).clamp(2.0, maxBarHeight);
    final hot = amplitude > 70;
    return Container(
      key: ValueKey('wave_bar_$i'),
      margin: const EdgeInsets.only(left: 2),
      width: barWidth,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(barWidth),
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [cyber.cyan, cyber.magenta],
        ),
        boxShadow: hot
            ? [BoxShadow(color: cyber.cyan.withValues(alpha: 0.5), blurRadius: 6)]
            : null,
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/widgets/cyber/neon_waveform_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/cyber/neon_waveform.dart test/widgets/cyber/neon_waveform_test.dart
git commit -m "feat(composer): NeonWaveform — barres gradient cyan→magenta + glow"
```

---

## Task 2: Brancher NeonWaveform dans RecordingInputRow

**Files:**
- Modify: `lib/pages/chat/recording_input_row.dart` (les deux `LayoutBuilder` waveform, lignes ~67-93 et ~141-167)

- [ ] **Step 1: Remplacer la waveform locked**

Dans `_buildLockedRow`, remplacer le bloc `Expanded(child: LayoutBuilder(...))` qui construit les barres `CyberColors.cyan` par :

```dart
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const barWidth = 4.0;
              final maxBars = (constraints.maxWidth / (barWidth + 2)).floor();
              final amps = state.amplitudeTimeline.reversed
                  .take(maxBars)
                  .toList()
                  .reversed
                  .toList();
              return Align(
                alignment: Alignment.centerRight,
                child: NeonWaveform(
                  amplitudes: amps,
                  maxBarHeight: 36,
                  barWidth: barWidth,
                ),
              );
            },
          ),
        ),
```

- [ ] **Step 2: Remplacer la waveform live-hold**

Dans `_buildLiveHoldRow`, remplacer le bloc `Expanded(child: LayoutBuilder(...))` équivalent par le même `NeonWaveform` (code identique à l'étape 1).

- [ ] **Step 3: Ajouter l'import et retirer le mort**

En tête de fichier, ajouter :
```dart
import 'package:fluffychat/widgets/cyber/neon_waveform.dart';
```
Retirer la const `maxDecibalWidth` désormais inutilisée dans les deux méthodes si plus référencée.

- [ ] **Step 4: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/recording_input_row.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/recording_input_row.dart
git commit -m "feat(composer): waveform néon dans RecordingInputRow (locked + live-hold)"
```

---

## Task 3: FrostedComposerSurface (pilule de verre)

**Files:**
- Create: `lib/widgets/cyber/frosted_composer_surface.dart`

- [ ] **Step 1: Implémenter le composant**

```dart
// lib/widgets/cyber/frosted_composer_surface.dart
import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';

/// Pilule frosted glass réutilisable pour la composer : blur opaque, hairline
/// néon, glow cyan animé quand [focused], bordure magenta quand [recording].
class FrostedComposerSurface extends StatelessWidget {
  final Widget child;
  final bool focused;
  final bool recording;

  const FrostedComposerSurface({
    required this.child,
    this.focused = false,
    this.recording = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final borderColor = recording
        ? cyber.magenta.withValues(alpha: 0.7)
        : focused
            ? cyber.cyan.withValues(alpha: 0.7)
            : cyber.violet.withValues(alpha: 0.45);
    final glowColor = recording ? cyber.magenta : cyber.cyan;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AnimatedContainer(
          duration: FluffyDurations.fast,
          curve: FluffyCurves.decelerated,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: (focused || recording)
                ? [
                    BoxShadow(
                      color: glowColor.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/widgets/cyber/frosted_composer_surface.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/cyber/frosted_composer_surface.dart
git commit -m "feat(composer): FrostedComposerSurface — pilule glass + glow focus/recording"
```

---

## Task 4: MorphingSendButton (bouton détaché)

**Files:**
- Create: `lib/pages/chat/composer/morphing_send_button.dart`
- Test: `test/composer/morphing_send_button_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/composer/morphing_send_button_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/pages/chat/composer/morphing_send_button.dart';

void main() {
  testWidgets('shows send icon and fires onSend when hasText', (tester) async {
    var sent = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MorphingSendButton(
            hasText: true,
            backgroundColor: Colors.blue,
            foregroundColor: Colors.black,
            onSend: () => sent = true,
            onScheduleSend: () {},
            micBuilder: (_) => const SizedBox(key: Key('mic_slot')),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(find.byKey(const Key('mic_slot')), findsNothing);
    await tester.tap(find.byKey(const Key('morph_send_button')));
    expect(sent, isTrue);
  });

  testWidgets('shows mic slot when no text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MorphingSendButton(
            hasText: false,
            backgroundColor: Colors.blue,
            foregroundColor: Colors.black,
            onSend: () {},
            onScheduleSend: () {},
            micBuilder: (_) => const SizedBox(key: Key('mic_slot')),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('mic_slot')), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/composer/morphing_send_button_test.dart`
Expected: FAIL (MorphingSendButton introuvable).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/pages/chat/composer/morphing_send_button.dart
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bouton rond détaché à droite de la composer. Avec du texte → bouton SEND
/// (avion, glow cyan→magenta, morph spring). Sans texte → délègue au slot micro
/// fourni par [micBuilder] (le VoiceRecordButton existant, geste inchangé).
class MorphingSendButton extends StatelessWidget {
  final bool hasText;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onSend;
  final VoidCallback onScheduleSend;
  final WidgetBuilder micBuilder;

  const MorphingSendButton({
    required this.hasText,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onSend,
    required this.onScheduleSend,
    required this.micBuilder,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber =
        Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    return SizedBox(
      width: 48,
      height: 48,
      child: AnimatedSwitcher(
        duration: FluffyDurations.fast,
        switchInCurve: FluffyCurves.decelerated,
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: hasText
            ? GestureDetector(
                key: const ValueKey('send'),
                onLongPress: onScheduleSend,
                child: Material(
                  key: const Key('morph_send_button'),
                  color: Colors.transparent,
                  child: InkResponse(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSend();
                    },
                    radius: 26,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [cyber.cyan, cyber.magenta],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: cyber.cyan.withValues(alpha: 0.45),
                            blurRadius: 16,
                          ),
                        ],
                      ),
                      child: Icon(Icons.send_rounded, color: foregroundColor),
                    ),
                  ),
                ),
              )
            : KeyedSubtree(
                key: const ValueKey('mic'),
                child: micBuilder(context),
              ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/composer/morphing_send_button_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/composer/morphing_send_button.dart test/composer/morphing_send_button_test.dart
git commit -m "feat(composer): MorphingSendButton — morph send↔micro + glow + haptic"
```

---

## Task 5: AttachMenuSheet (grille 3 colonnes animée)

**Files:**
- Create: `lib/pages/chat/composer/attach_menu_sheet.dart`
- Test: `test/composer/attach_menu_sheet_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/composer/attach_menu_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/composer/attach_menu_sheet.dart';

void main() {
  testWidgets('tapping an item returns its action', (tester) async {
    AddPopupMenuActions? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showAttachMenu(context, isMobile: true);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // L'item "file" porte une key déterministe.
    await tester.tap(find.byKey(const ValueKey('attach_file')));
    await tester.pumpAndSettle();
    expect(picked, AddPopupMenuActions.file);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/composer/attach_menu_sheet_test.dart`
Expected: FAIL (showAttachMenu introuvable).

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/pages/chat/composer/attach_menu_sheet.dart
import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:flutter/material.dart';

class _AttachItem {
  final AddPopupMenuActions action;
  final IconData icon;
  final String label;
  final Color tint;
  final bool mobileOnly;
  const _AttachItem(this.action, this.icon, this.label, this.tint,
      {this.mobileOnly = false});
}

/// Ouvre le panneau frosted glass d'attach (grille 3 colonnes). Renvoie l'action
/// choisie ou null si fermé. [isMobile] masque les items mobile-only (caméra,
/// localisation) sur desktop/web.
Future<AddPopupMenuActions?> showAttachMenu(
  BuildContext context, {
  required bool isMobile,
}) {
  return showModalBottomSheet<AddPopupMenuActions>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) => _AttachMenuSheet(isMobile: isMobile),
  );
}

class _AttachMenuSheet extends StatelessWidget {
  final bool isMobile;
  const _AttachMenuSheet({required this.isMobile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final l10n = L10n.of(context);
    final items = <_AttachItem>[
      _AttachItem(AddPopupMenuActions.image, Icons.photo_outlined,
          l10n.sendImage, cyber.cyan),
      _AttachItem(AddPopupMenuActions.photoCamera, Icons.camera_alt_outlined,
          l10n.takeAPhoto, cyber.violet,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.video,
          Icons.video_camera_back_outlined, l10n.sendVideo, cyber.cyan),
      _AttachItem(AddPopupMenuActions.videoCamera, Icons.videocam_outlined,
          l10n.recordAVideo, cyber.violet,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.file, Icons.attachment_outlined,
          l10n.sendFile, cyber.magenta),
      _AttachItem(AddPopupMenuActions.poll, Icons.poll_outlined,
          l10n.startPoll, cyber.magenta),
      _AttachItem(AddPopupMenuActions.location, Icons.gps_fixed_outlined,
          l10n.shareLocation, cyber.cyan,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.ephemeral, Icons.timer_outlined,
          l10n.ephemeralMessages, cyber.violet),
    ];
    final visible =
        items.where((i) => !i.mobileOnly || isMobile).toList();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.82),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(color: cyber.violet.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.92,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < visible.length; i++)
                _AttachTile(
                  item: visible[i],
                  index: i,
                  onTap: () => Navigator.of(context).pop(visible[i].action),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  final _AttachItem item;
  final int index;
  final VoidCallback onTap;
  const _AttachTile({
    required this.item,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('attach_${item.action.name}'),
      borderRadius: FluffyRadius.brLg,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: item.tint.withValues(alpha: 0.13),
              borderRadius: FluffyRadius.brLg,
              border: Border.all(color: item.tint.withValues(alpha: 0.32)),
            ),
            child: Icon(item.icon, color: item.tint),
          ),
          const SizedBox(height: 6),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/composer/attach_menu_sheet_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/composer/attach_menu_sheet.dart test/composer/attach_menu_sheet_test.dart
git commit -m "feat(composer): AttachMenuSheet — grille 3 colonnes frosted glass"
```

---

## Task 6: Recomposer ChatInputRow

**Files:**
- Modify: `lib/pages/chat/chat_input_row.dart` (la branche `else` de `_buildEditRow`, lignes ~210-465)

- [ ] **Step 1: Ajouter le focus notifier**

Dans `_ChatInputRowState`, ajouter un champ et le câbler au focus du controller :

```dart
  final ValueNotifier<bool> _focused = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    controller.inputFocus.addListener(_onFocusChange);
  }

  void _onFocusChange() => _focused.value = controller.inputFocus.hasFocus;
```

Et dans `dispose()` (existant), ajouter :
```dart
    controller.inputFocus.removeListener(_onFocusChange);
    _focused.dispose();
```

- [ ] **Step 2: Remplacer la branche `else` (barre normale)**

Remplacer toute la liste `<Widget>[ ... ]` de la branche `else` (le `+` PopupMenu, la caméra PopupMenu, l'emoji, l'account picker, l'InputBar, le bouton micro/send) par cette nouvelle structure :

```dart
              : <Widget>[
                  const SizedBox(width: 8),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _focused,
                      builder: (context, focused, _) => FrostedComposerSurface(
                        focused: focused,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: L10n.of(context).more,
                              color: theme.colorScheme.onPrimaryContainer,
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () async {
                                final action = await showAttachMenu(
                                  context,
                                  isMobile: PlatformInfos.isMobile,
                                );
                                if (action != null) {
                                  controller.onAddPopupMenuButtonSelected(action);
                                }
                              },
                            ),
                            _EphemeralIndicator(controller: controller),
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2.0),
                                child: InputBar(
                                  room: controller.room,
                                  minLines: 1,
                                  maxLines: 8,
                                  autofocus: !PlatformInfos.isMobile,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction:
                                      AppSettings.sendOnEnter.value == true &&
                                              PlatformInfos.isMobile
                                          ? TextInputAction.send
                                          : null,
                                  onSubmitted: controller.onInputBarSubmitted,
                                  onSubmitImage:
                                      controller.sendImageFromClipBoard,
                                  focusNode: controller.inputFocus,
                                  controller: controller.sendController,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(
                                      left: 6.0,
                                      right: 6.0,
                                      bottom: 6.0,
                                      top: 3.0,
                                    ),
                                    counter: const SizedBox.shrink(),
                                    hintText: L10n.of(context).writeAMessage,
                                    hintMaxLines: 1,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    filled: false,
                                  ),
                                  onChanged: controller.onInputBarChanged,
                                  suggestionEmojis: getDefaultEmojiLocale(
                                    AppSettings.emojiSuggestionLocale.value
                                            .isNotEmpty
                                        ? Locale(AppSettings
                                            .emojiSuggestionLocale.value)
                                        : Localizations.localeOf(context),
                                  ).fold(
                                    [],
                                    (emojis, category) =>
                                        emojis..addAll(category.emoji),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
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
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  MorphingSendButton(
                    hasText: textMessageOnly,
                    backgroundColor: theme.bubbleColor,
                    foregroundColor: theme.onBubbleColor,
                    onSend: controller.send,
                    onScheduleSend: _scheduleSend,
                    micBuilder: (context) =>
                        PlatformInfos.platformCanRecord &&
                                !controller.sendController.text.isNotEmpty &&
                                controller.editEvent == null
                            ? VoiceRecordButton(
                                controller: controller,
                                recordingState: recordingViewModel,
                                gestureNotifier: _gestureNotifier,
                                backgroundColor: theme.bubbleColor,
                                foregroundColor: theme.onBubbleColor,
                              )
                            : IconButton(
                                key: const Key('send_button'),
                                tooltip: L10n.of(context).send,
                                onPressed: controller.send,
                                style: IconButton.styleFrom(
                                  backgroundColor: theme.bubbleColor,
                                  foregroundColor: theme.onBubbleColor,
                                ),
                                icon: const Icon(Icons.send_outlined),
                              ),
                  ),
                  const SizedBox(width: 6),
                ],
```

Note : `_buildEditRow` doit recevoir `recordingViewModel` (déjà un paramètre). Le mode select (branche `controller.selectMode ? [...]`) reste **inchangé**.

- [ ] **Step 3: Ajouter les imports**

En tête de `chat_input_row.dart`, ajouter :
```dart
import 'package:fluffychat/pages/chat/composer/attach_menu_sheet.dart';
import 'package:fluffychat/pages/chat/composer/morphing_send_button.dart';
import 'package:fluffychat/widgets/cyber/frosted_composer_surface.dart';
```
Retirer l'import inutilisé `recording_input_row.dart` SI plus référencé (il l'est encore via le builder locked → garder). Retirer `voice_recording_overlay`/`voice_record_gesture_state` seulement s'ils deviennent inutilisés (ils restent utilisés → garder).

- [ ] **Step 4: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/chat_input_row.dart`
Expected: No issues found (corriger tout import mort ou variable inutilisée signalés).

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/chat_input_row.dart
git commit -m "feat(composer): recompose ChatInputRow (pilule glass + bouton détaché + attach sheet)"
```

---

## Task 7: Restyle overlay vocal + vérif mentions @

**Files:**
- Modify: `lib/pages/chat/voice_recording_overlay.dart`
- Read/verify: `lib/pages/chat/input_bar.dart` (rendu pill mention)

- [ ] **Step 1: Lire l'overlay et la gestion mention**

Run:
```bash
sed -n '1,80p' lib/pages/chat/voice_recording_overlay.dart
sed -n '150,200p' lib/pages/chat/input_bar.dart
```
Objectif : repérer les couleurs/hint de l'overlay (slide-to-cancel, lock pill) et confirmer que la sélection d'une mention insère bien `user.mention` (déjà le cas l.165).

- [ ] **Step 2: Restyler l'overlay en néon**

Dans `voice_recording_overlay.dart`, remplacer les couleurs du hint "slide to cancel" et de la lock-pill par `CyberColors.of(context).magenta` (cancel) et `.violet` (lock), cohérent avec la bordure magenta d'enregistrement. (Édition ciblée des `Color`/`BoxDecoration` — ne pas toucher la logique de position pilotée par `gestureNotifier`.)

- [ ] **Step 3: Vérifier la pill mention**

Si le rendu d'une mention insérée est du texte brut `@nom` sans style, l'acceptable pour le niveau 1 est le markdown Matrix natif (la mention devient un lien pill à l'affichage du message). Aucun changement requis côté composer si l'insertion utilise déjà `user.mention`. Documenter le constat dans le commit.

- [ ] **Step 4: Analyze**

Run: `/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/voice_recording_overlay.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/pages/chat/voice_recording_overlay.dart
git commit -m "feat(composer): overlay vocal restylé néon (cancel magenta / lock violet)"
```

---

## Task 8: Validation finale — analyze, tests, build, install

**Files:** aucun (vérification)

- [ ] **Step 1: Analyze global des fichiers touchés**

Run:
```bash
/home/sk7n4k3d/fvm/versions/stable/bin/flutter analyze lib/pages/chat/ lib/widgets/cyber/
```
Expected: No issues found.

- [ ] **Step 2: Tests des nouveaux composants**

Run:
```bash
/home/sk7n4k3d/fvm/versions/stable/bin/flutter test test/composer/ test/widgets/cyber/neon_waveform_test.dart test/voice_recording_gesture_test.dart
```
Expected: All tests passed (les tests de geste vocal existants restent verts = non-régression).

- [ ] **Step 3: Build release**

Run:
```bash
/home/sk7n4k3d/fvm/versions/stable/bin/flutter build apk --release
```
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`.

- [ ] **Step 4: Install sur le Pixel**

Run:
```bash
adb connect 10.8.0.31:46187
adb -s 10.8.0.31:46187 install -r build/app/outputs/flutter-apk/app-release.apk
```
Expected: `Success`.

- [ ] **Step 5: Commit final (si reliquats) + résumé**

```bash
git add -A && git commit -m "chore(composer): build refonte composer Matrix" || echo "rien à committer"
```

Vérification manuelle sur device (checklist non-régression) : envoi texte, image (galerie), photo caméra, vidéo, fichier, sondage, lieu, éphémère ; vocal record→slide-cancel→lock→send ; scheduled (long-press send) ; mention @ ; markdown ; multi-compte ; glow focus ; morph send↔micro ; attach grille animée.
```
