import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/aurora_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [CyberpunkTheme.dark()]),
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('AuroraBackground', () {
    testWidgets('paints a CustomPaint', (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(), reduceMotion: true),
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('under reduce-motion: no animation host (no ticker)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(), reduceMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // The animator's AnimatedBuilder must be absent, and the painted layer
      // must not be rebuilt by a ticker.
      expect(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
    });

    testWidgets('when motion is allowed: animation host is present',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(period: Duration(seconds: 1))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(AnimatedBuilder),
        ),
        findsOneWidget,
      );
    });

    testWidgets('applies the requested opacity', (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(opacity: 0.4), reduceMotion: true),
      );
      final opacity = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 0.4);
    });
  });
}
