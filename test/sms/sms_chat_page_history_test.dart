// Volet « historique » des tests d'intégration de la conversation SMS : ce qui
// se joue sans événements live (pagination d'un scroll, relecture des statuts
// après un envoi). Le fil live avec événements est dans
// sms_chat_page_live_test.dart (le singleton SmsBridge mémoïse son flux par
// isolate).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sms_chat_live_harness.dart';

void main() {
  testWidgets('pagination : un MMS ancien partageant l id d un SMS chargé '
      "n'est pas englouti", (tester) async {
    final fx = await installSmsHarness(tester);
    // Page 1 : 50 SMS (ids 1..50). Page antérieure : un MMS d'id 7 — même id
    // qu'un SMS déjà chargé. L'ancien trie `seen.contains(m.id)` le filtrait à
    // jamais ; la déduplication sur (id, isMms) doit l'afficher.
    fx.latestPage = [
      for (var i = 1; i <= 50; i++)
        smsRow(id: i, body: 'sms-$i', date: 1793800000000 + i * 1000),
    ];
    fx.olderPage = [
      mmsRow(
        id: 7,
        body: 'mms-ancien-7',
        date: 1793700000000,
        attachments: [mmsPart(420, 'image/jpeg', 'vieux.jpg')],
      ),
    ];
    await openSmsPage(tester);

    var found = false;
    for (var i = 0; i < 60 && !found; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      found = find.text('mms-ancien-7').evaluate().isNotEmpty;
    }
    expect(
      found,
      isTrue,
      reason: 'le MMS ancien a été filtré par la dédup sur id nu',
    );
    expect(
      find.descendant(
        of: liveBubble('mms:7'),
        matching: find.text('mms-ancien-7'),
      ),
      findsOneWidget,
    );
    // Puis on redescend vérifier que le SMS du même id a survécu (le ListView
    // est lazy : hors viewport, le widget n'existe pas).
    var backDown = false;
    for (var i = 0; i < 60 && !backDown; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      backDown = find.text('sms-7').evaluate().isNotEmpty;
    }
    expect(backDown, isTrue, reason: 'le SMS voisin a disparu du fil');
    await disposeSmsPage(tester);
  });

  testWidgets('rafraîchissement statut : fusion type/status sans écraser le '
      'voisin', (tester) async {
    final fx = await installSmsHarness(tester);
    // Le fil contient déjà un MMS d'id 99. L'envoi d'un SMS renvoie le rowId
    // 99 : la relecture des statuts renvoie les DEUX lignes (même id nu).
    // Ancien code : byId écrasait l'une par l'autre et remplaçait la ligne
    // entière (body, date, media). Nouveau : uniquement type/status, par
    // couple (id, isMms).
    const oldDate = 1793899000000;
    fx.latestPage = [
      mmsRow(
        id: 99,
        body: 'mms-99-histoire',
        date: oldDate,
        attachments: [mmsPart(500, 'image/jpeg', 'mms99.jpg')],
      ),
    ];
    await openSmsPage(tester);
    expect(find.text('mms-99-histoire'), findsOneWidget);

    // Envoi d'un SMS qui retombe sur le rowId 99.
    fx.sendRowId = 99;
    await tester.enterText(find.byType(TextField), 'coucou');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.descendant(of: liveBubble('sms:99'), matching: find.text('coucou')),
      findsOneWidget,
    );

    // La relecture de statut renvoie le SMS passé à status 0 (prouvé) et un
    // MMS au corps provider différent — la fusion ne doit toucher QUE le
    // statut, jamais le corps/la date/le média affichés.
    fx.latestPage = [
      smsRow(id: 99, body: 'coucou', date: oldDate + 5000, type: 2, status: 0),
      mmsRow(id: 99, body: 'CORPS-PROVIDER-DIFFERENT', date: oldDate ~/ 1000),
    ];
    await tester.pump(const Duration(seconds: 4)); // 1re relecture à 3 s
    await tester.pump();

    // Le SMS passe à « Distribué » sans changer de corps.
    expect(find.text('Distribué'), findsOneWidget);
    expect(
      find.descendant(of: liveBubble('sms:99'), matching: find.text('coucou')),
      findsOneWidget,
    );
    // Le MMS garde son corps affiché (pas de remplacement corps à corps).
    expect(
      find.descendant(
        of: liveBubble('mms:99'),
        matching: find.text('mms-99-histoire'),
      ),
      findsOneWidget,
    );
    expect(find.text('CORPS-PROVIDER-DIFFERENT'), findsNothing);
    // Son média n'a pas été effacé par la fusion non plus.
    expect(
      find.descendant(of: liveBubble('mms:99'), matching: imageSlot),
      findsOneWidget,
    );

    // Épuise les relectures 10/30/90 s pour ne laisser aucun timer pendant.
    await tester.pump(const Duration(seconds: 91));
    await tester.pump();
    await disposeSmsPage(tester);
  });
}
