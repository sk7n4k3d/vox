// Test d'intégration du fil live MMS/SMS (audit VOX 2026-11-05) : page pompée
// pour de vrai, canaux natifs mockés. Scénario unique et continu — le
// singleton `SmsBridge` mémoïse son flux d'événements pour tout l'isolate,
// donc TOUT ce qui consomme le stream live vit dans ce seul testWidgets (les
// tests sans événements sont dans sms_chat_page_history_test.dart).
//
// Il prouve que la collision structurelle Sms._ID == Mms._ID (deux compteurs
// AUTOINCREMENT indépendants de mmssms.db) ne peut plus : attacher le média
// d'un MMS à la bulle d'un SMS, doubler une bulle sur re-rediffusion, ni
// supprimer la bulle voisine — et que la suppression cible la bonne table.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sms_chat_live_harness.dart';

void main() {
  testWidgets(
    'fil live : collision id SMS/MMS, média, rediffusion, audio, suppression',
    (tester) async {
      final fx = await installSmsHarness(tester);
      // Fond de fil : sans contenu, les bulles live collent sous l'app bar
      // givrée (dont la zone de hit déborde sur le haut du corps) et les
      // gestes longue pression s'y perdent. Quelques SMS anciens ancrent la
      // conversation en bas d'écran, comme dans un vrai fil.
      fx.latestPage = [
        for (var i = 1; i <= 8; i++)
          smsRow(id: i, body: 'filler-$i', date: 1793890000000 + i * 1000),
      ];
      await openSmsPage(tester);
      fx.partsByMms[42] = [mmsPart(339, 'image/jpeg', 'img.jpg')];

      // 1) Collision : un SMS puis un MMS du même fil portant le MÊME _ID
      // provider (42). Le média du MMS ne doit jamais atterrir sur la bulle
      // du SMS (l'ancienne jointure indexWhere(m.id == ...) répondait le SMS
      // en premier et lui collait isMms:true + l'image).
      fx.emit(smsEvent(42, 'sms-42', 1793899550000));
      await tester.pump();
      fx.emit(mmsEvent(42, 'mms-42', 1793899553000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('sms-42'), findsOneWidget);
      expect(find.text('mms-42'), findsOneWidget);
      expect(
        find.descendant(of: liveBubble('mms:42'), matching: imageSlot),
        findsOneWidget,
      );
      expect(
        find.descendant(of: liveBubble('sms:42'), matching: imageSlot),
        findsNothing,
      );
      expect(
        find.descendant(of: liveBubble('sms:42'), matching: find.text('sms-42')),
        findsOneWidget,
      );

      // 2) Re-rediffusion du même événement MMS (relay framework) : pas de
      // doublon de bulle, pas de double attach.
      final repeated = mmsEvent(42, 'mms-42', 1793899553000);
      fx.emit(repeated);
      await tester.pump();
      fx.emit(repeated);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('mms-42'), findsOneWidget);
      expect(
        find.descendant(of: liveBubble('mms:42'), matching: imageSlot),
        findsOneWidget,
      );

      // 3) Audio dans une bulle live : pièce jointe non-visuelle, jamais
      // perdue, jamais rendue comme une image. Reçu EN PLUS des bulles 42,
      // il sert aussi de lest sous elles : les suppression suivantes peuvent
      // ainsi centrer leurs cibles hors de l'ombre de hit du composer.
      fx.partsByMms[50] = [mmsPart(401, 'audio/3gpp', 'audio.3gp')];
      fx.emit(mmsEvent(50, 'memo vocal', 1793899653000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: liveBubble('mms:50'),
          matching: find.text('Message audio'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: liveBubble('mms:50'),
          matching: find.byIcon(Icons.audiotrack_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: liveBubble('mms:50'), matching: imageSlot),
        findsNothing,
      );

      // 4) Suppression du MMS collisionnel : appel natif deleteMessage(42,
      // isMms: true) — la vraie table, pas la table SMS — et la bulle du SMS
      // survit (l'ancien removeWhere par id nu tuait les deux).
      await longPressBubble(tester, 'mms:42');
      await tapSheetAction(tester, 'Supprimer');
      expect(fx.lastArgs('deleteMessage'), {'id': 42, 'isMms': true});
      expect(find.text('mms-42'), findsNothing);
      expect(find.text('sms-42'), findsOneWidget);

      // 5) Puis suppression du SMS → deleteMessage(42, isMms: false).
      await longPressBubble(tester, 'sms:42');
      await tapSheetAction(tester, 'Supprimer');
      expect(fx.lastArgs('deleteMessage'), {'id': 42, 'isMms': false});
      expect(find.text('sms-42'), findsNothing);
      // La bulle audio vue plus haut n'a rien eu de la suppression voisine.
      expect(find.text('memo vocal'), findsOneWidget);

      await disposeSmsPage(tester);
    },
  );
}
