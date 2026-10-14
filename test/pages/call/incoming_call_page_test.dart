import 'package:fluffychat/pages/call/incoming_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget page({
  required VoidCallback onAnswer,
  required VoidCallback onDecline,
  bool video = true,
  String name = 'Alice',
}) => MaterialApp(
  home: IncomingCallPage(
    callId: 'c1',
    roomId: '!r1:sk7.sh',
    callerName: name,
    video: video,
    onAnswer: onAnswer,
    onDecline: onDecline,
  ),
);

void main() {
  testWidgets('affiche le nom de l\'appelant et les deux boutons', (
    tester,
  ) async {
    await tester.pumpWidget(page(onAnswer: () {}, onDecline: () {}));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.byKey(const Key("incoming-answer")), findsOneWidget);
    expect(find.byKey(const Key("incoming-decline")), findsOneWidget);
  });

  testWidgets('indique la nature de l\'appel', (tester) async {
    await tester.pumpWidget(page(onAnswer: () {}, onDecline: () {}));
    expect(find.text('Appel vidéo entrant'), findsOneWidget);

    await tester.pumpWidget(page(onAnswer: () {}, onDecline: () {}, video: false));
    expect(find.text('Appel vocal entrant'), findsOneWidget);
  });

  testWidgets('appuyer sur répondre déclenche onAnswer une seule fois', (
    tester,
  ) async {
    var answers = 0;
    await tester.pumpWidget(page(onAnswer: () => answers++, onDecline: () {}));

    await tester.tap(find.byKey(const Key('incoming-answer')));
    await tester.tap(find.byKey(const Key('incoming-answer')));
    await tester.pump();

    expect(answers, 1);
  });

  testWidgets('appuyer sur refuser déclenche onDecline une seule fois', (
    tester,
  ) async {
    var declines = 0;
    await tester.pumpWidget(page(onAnswer: () {}, onDecline: () => declines++));

    await tester.tap(find.byKey(const Key('incoming-decline')));
    await tester.tap(find.byKey(const Key('incoming-decline')));
    await tester.pump();

    expect(declines, 1);
  });

  testWidgets('répondre puis refuser ne lance que la réponse', (
    tester,
  ) async {
    var answers = 0;
    var declines = 0;
    await tester.pumpWidget(
      page(onAnswer: () => answers++, onDecline: () => declines++),
    );

    await tester.tap(find.byKey(const Key('incoming-answer')));
    await tester.tap(find.byKey(const Key('incoming-decline')));
    await tester.pump();

    expect(answers, 1);
    expect(declines, 0);
  });

  testWidgets('les deux boutons se désactivent après une action', (
    tester,
  ) async {
    await tester.pumpWidget(page(onAnswer: () {}, onDecline: () {}));

    final InkWell before = tester.widget(find.descendant(
      of: find.byKey(const Key('incoming-answer')),
      matching: find.byType(InkWell),
    ));
    expect(before.onTap, isNotNull);

    await tester.tap(find.byKey(const Key('incoming-answer')));
    await tester.pump();

    final InkWell after = tester.widget(find.descendant(
      of: find.byKey(const Key('incoming-answer')),
      matching: find.byType(InkWell),
    ));
    expect(after.onTap, isNull);
  });
}