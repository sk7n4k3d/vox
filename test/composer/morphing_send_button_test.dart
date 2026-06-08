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
