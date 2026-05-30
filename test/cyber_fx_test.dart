import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';

Widget _wrap(Widget child, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [CyberpunkTheme.dark()]),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('CyberMotion', () {
    testWidgets('reflects disableAnimations', (tester) async {
      late bool reduced;
      await tester.pumpWidget(
        _wrap(
          Builder(builder: (c) {
            reduced = CyberMotion.reduced(c);
            return const SizedBox();
          }),
          reduceMotion: true,
        ),
      );
      expect(reduced, isTrue);
    });
  });

  group('CyberGlitchText', () {
    testWidgets('renders plain Text under reduce-motion', (tester) async {
      await tester.pumpWidget(
        _wrap(const CyberGlitchText('JARVIS'), reduceMotion: true),
      );
      expect(find.text('JARVIS'), findsOneWidget);
    });
  });

  group('CyberNeonFrame', () {
    testWidgets('renders child and static glow under reduce-motion',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CyberNeonFrame(child: Text('btn')),
          reduceMotion: true,
        ),
      );
      expect(find.text('btn'), findsOneWidget);
      // static fallback = a DecoratedBox with a glow shadow, no shader widget
      final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      final hasGlow = boxes.any((b) {
        final d = b.decoration;
        return d is BoxDecoration && (d.boxShadow?.isNotEmpty ?? false);
      });
      expect(hasGlow, isTrue);
    });

    testWidgets('renders child when disabled', (tester) async {
      await tester.pumpWidget(
        _wrap(const CyberNeonFrame(enabled: false, child: Text('btn'))),
      );
      expect(find.text('btn'), findsOneWidget);
    });
  });
}
