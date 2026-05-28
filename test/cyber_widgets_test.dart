import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: [CyberpunkTheme.dark()],
      ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('CyberColors', () {
    testWidgets('falls back to dark() when extension missing', (tester) async {
      late CyberpunkTheme resolved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = CyberColors.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved.cyan, const Color(0xFF00F0FF));
      expect(resolved.magenta, const Color(0xFFFF2E92));
    });

    testWidgets('reads the registered extension', (tester) async {
      late CyberpunkTheme resolved;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              resolved = CyberColors.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved.violet, const Color(0xFFA78BFA));
    });
  });

  group('CyberGlass', () {
    testWidgets('renders its child', (tester) async {
      await tester.pumpWidget(_wrap(const CyberGlass(child: Text('hello'))));
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('invokes onTap', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        _wrap(CyberGlass(onTap: () => tapped++, child: const Text('tap'))),
      );
      await tester.tap(find.text('tap'));
      expect(tapped, 1);
    });
  });

  group('CyberSettingsTile', () {
    testWidgets('shows title + subtitle and fires onTap', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        _wrap(
          CyberSettingsTile(
            icon: Icons.lock,
            accent: const Color(0xFF00F0FF),
            title: 'Privacy',
            subtitle: 'E2EE keys',
            onTap: () => tapped++,
          ),
        ),
      );
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('E2EE keys'), findsOneWidget);
      await tester.tap(find.text('Privacy'));
      expect(tapped, 1);
    });
  });

  group('CyberField focus state', () {
    testWidgets('lights the cyan border when focused', (tester) async {
      await tester.pumpWidget(
        _wrap(const CyberField(focused: true, child: Text('field'))),
      );
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect((decoration.border! as Border).top.color,
          const Color(0xFF00F0FF));
      expect(decoration.boxShadow, isNotNull);
    });

    testWidgets('uses the hairline border when unfocused', (tester) async {
      await tester.pumpWidget(
        _wrap(const CyberField(child: Text('field'))),
      );
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.boxShadow, isNull);
    });
  });

  group('CyberPrimaryButton', () {
    testWidgets('fires onPressed when enabled', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _wrap(
          CyberPrimaryButton(label: 'Go', onPressed: () => pressed++),
        ),
      );
      await tester.tap(find.text('Go'));
      expect(pressed, 1);
    });

    testWidgets('shows spinner and blocks tap when loading', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _wrap(
          CyberPrimaryButton(
            label: 'Go',
            loading: true,
            onPressed: () => pressed++,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(CyberPrimaryButton));
      expect(pressed, 0);
    });
  });
}
