import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/code_block_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;

Widget _wrap(Widget child, {ThemeMode mode = ThemeMode.dark}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    themeMode: mode,
    darkTheme: ThemeData.dark(useMaterial3: true),
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(body: child),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('CodeBlockWidget.extractLanguage', () {
    test('parses language-xxx token', () {
      final el = dom.Element.html('<code class="language-python">x</code>');
      expect(CodeBlockWidget.extractLanguage(el), 'python');
    });

    test('returns null when no language class is present', () {
      final el = dom.Element.html('<code class="other-class">x</code>');
      expect(CodeBlockWidget.extractLanguage(el), isNull);
    });

    test('returns null on empty className', () {
      final el = dom.Element.html('<code>x</code>');
      expect(CodeBlockWidget.extractLanguage(el), isNull);
    });

    test('resolves alias js -> javascript', () {
      final el = dom.Element.html('<code class="language-js">x</code>');
      expect(CodeBlockWidget.extractLanguage(el), 'javascript');
    });

    test('resolves alias py -> python', () {
      final el = dom.Element.html('<code class="language-py">x</code>');
      expect(CodeBlockWidget.extractLanguage(el), 'python');
    });

    test('keeps unknown languages as-is (lowercased)', () {
      final el = dom.Element.html(
        '<code class="language-Whatever">x</code>',
      );
      expect(CodeBlockWidget.extractLanguage(el), 'whatever');
    });
  });

  group('CodeBlockWidget render', () {
    testWidgets('renders code body and language pill', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CodeBlockWidget(
            rawCode: 'print("hi")',
            language: 'python',
            fontSize: 14,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('python'), findsOneWidget);
      expect(find.textContaining('print'), findsWidgets);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('no language: pill hidden, copy still visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const CodeBlockWidget(
            rawCode: 'echo hello',
            language: null,
            fontSize: 14,
          ),
        ),
      );
      await _settle(tester);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      // No pill text should be present (only the code text).
      expect(find.text(''), findsNothing);
    });

    testWidgets('unknown language: pill shown, falls back to plaintext', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const CodeBlockWidget(
            rawCode: 'something random',
            language: 'totally-not-real-lang',
            fontSize: 14,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('totally-not-real-lang'), findsOneWidget);
      expect(find.textContaining('something'), findsWidgets);
    });

    testWidgets('copy tap toggles icon to check then back', (tester) async {
      const sample = 'let x = 42;';
      // Mock clipboard so Clipboard.setData does not throw on the test channel.
      String? captured;
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          captured = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });

      await tester.pumpWidget(
        _wrap(
          const CodeBlockWidget(
            rawCode: sample,
            language: 'javascript',
            fontSize: 14,
          ),
        ),
      );
      await _settle(tester);

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(captured, sample);

      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('horizontal scroll view is present for long lines', (
      tester,
    ) async {
      final long = 'x' * 500;
      await tester.pumpWidget(
        _wrap(
          CodeBlockWidget(rawCode: long, language: 'plaintext', fontSize: 14),
        ),
      );
      await _settle(tester);
      final scrollViews = tester.widgetList<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(
        scrollViews.any((sv) => sv.scrollDirection == Axis.horizontal),
        isTrue,
      );
    });
  });
}
