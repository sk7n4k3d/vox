import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/composer/attach_menu_sheet.dart';

void main() {
  testWidgets('tapping an item returns its action', (tester) async {
    // Écran assez grand pour que la grille du bottom-sheet tienne entière.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AddPopupMenuActions? picked;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
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
    // Les délégués l10n sont chargés en deferred → laisser l'arbre se construire.
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attach_file')));
    await tester.pumpAndSettle();
    expect(picked, AddPopupMenuActions.file);
  });
}
