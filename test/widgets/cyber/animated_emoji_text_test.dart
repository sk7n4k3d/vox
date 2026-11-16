import 'package:animated_emoji/animated_emoji.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/animated_emoji_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(extensions: [CyberpunkTheme.dark()]),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  setUpAll(() {
    // [VisibilityDetector] bat la visibilité via un Timer périodique global.
    // Intervalle nul en test : plus de timer en attente à la fin du test.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  group('AnimatedEmojiText.hasAnimatable', () {
    test('true for a single animatable emoji', () {
      expect(AnimatedEmojiText.hasAnimatable('👍'), isTrue);
    });

    test('false when the body exceeds maxEmojis', () {
      expect(AnimatedEmojiText.hasAnimatable('👍👍👍👍', maxEmojis: 3), isFalse);
    });

    test('false for plain text', () {
      expect(AnimatedEmojiText.hasAnimatable('bonjour'), isFalse);
    });
  });

  group('AnimatedEmojiText rendering', () {
    testWidgets('non-animatable body renders one Text per grapheme cluster',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const AnimatedEmojiText(text: 'ab', size: 18)),
      );
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets('an animatable emoji renders inside a VisibilityDetector',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const AnimatedEmojiText(text: '👍', size: 18)),
      );
      expect(find.byType(VisibilityDetector), findsOneWidget);
      // Laisse partir les callbacks de visibilité différés avant démontage :
      // ils ne doivent PAS provoquer de setState après dispose.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(_wrap(const SizedBox()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });

    testWidgets('defaults: animation enabled and gated by visibility',
        (tester) async {
      const subject = AnimatedEmojiText(text: '👍', size: 18);
      // L'animation est autorisée…
      expect(subject.animateWhenVisible, isTrue);
      // …mais elle ne démarre qu'au-delà du seuil de visibilité.
      expect(subject.visibilityThreshold, greaterThan(0));
    });

    testWidgets('animateWhenVisible=false keeps the emoji static',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const AnimatedEmojiText(
            text: '👍',
            size: 18,
            animateWhenVisible: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('visible emoji plays a ONE-SHOT burst, never a loop',
        (tester) async {
      await tester.pumpWidget(_wrap(const AnimatedEmojiText(text: '👍', size: 18)));
      // Callback de visibilité (intervalle nul) → l'emoji est vu → animate=true.
      await tester.pump(const Duration(milliseconds: 100));
      final emoji = tester.widget<AnimatedEmoji>(find.byType(AnimatedEmoji));
      // Cœur du correctif perf : `repeat` doit rester false. Un repeat ici =
      // Lottie qui produit des frames à jamais tant que la pastille est à
      // l'écran → thread raster saturé au repos (lag mesuré en room dense).
      expect(emoji.repeat, isFalse,
          reason: 'une réaction ne doit JAMAIS boucler en liste');
      expect(emoji.animate, isTrue);
    });

    testWidgets('OS reduce-motion renders the emoji fully static',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: [CyberpunkTheme.dark()],
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(
              body: Center(child: AnimatedEmojiText(text: '👍', size: 18)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final emoji = tester.widget<AnimatedEmoji>(find.byType(AnimatedEmoji));
      expect(emoji.animate, isFalse,
          reason: 'réducteur de mouvement OS = aucune animation Lottie');
    });
  });
}
