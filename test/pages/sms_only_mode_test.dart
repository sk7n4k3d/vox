import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/sms_chat/new_sms_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _mockSmsChannel({required bool isDefault}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('eu.devlabz.vox/sms'),
        (call) async => switch (call.method) {
          'isDefaultSmsApp' => isDefault,
          'requestDefaultSmsRole' => true,
          _ => null,
        },
      );
}

/// Pump une app vide et retourne son contexte racine.
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext rootContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          rootContext = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
  return rootContext;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });

  group('NewSmsDialog — saisie du destinataire', () {
    testWidgets('un numéro national est normalisé en international', (
      tester,
    ) async {
      final context = await _pumpHost(tester);
      final shown = showAdaptiveDialog<String>(
        context: context,
        builder: (_) => const NewSmsDialog(),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '06 12 34 56 78');
      await tester.tap(find.text('Écrire'));
      await tester.pumpAndSettle();
      expect(await shown, '+33612345678');
    });

    testWidgets('un texte non numérique est refusé sans fermer la boîte', (
      tester,
    ) async {
      final context = await _pumpHost(tester);
      unawaited(
        showAdaptiveDialog<String>(
          context: context,
          builder: (_) => const NewSmsDialog(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'pas un numéro');
      await tester.tap(find.text('Écrire'));
      await tester.pumpAndSettle();
      expect(find.text('Numéro invalide'), findsOneWidget);
      expect(find.byType(NewSmsDialog), findsOneWidget);
    });
  });

  group('SmsOnlySetupBanner — onboarding sans compte', () {
    testWidgets('sans le rôle SMS : le CTA d\'activation est visible', (
      tester,
    ) async {
      _mockSmsChannel(isDefault: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: const [SmsOnlySetupBanner()]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('application SMS par défaut'), findsOneWidget);
      expect(find.text('Définir comme app SMS par défaut'), findsOneWidget);
    });

    testWidgets('avec le rôle SMS : consignes de démarrage, pas de CTA', (
      tester,
    ) async {
      _mockSmsChannel(isDefault: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: const [SmsOnlySetupBanner()]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('apparaîtront ici'), findsOneWidget);
      expect(find.text('Définir comme app SMS par défaut'), findsNothing);
    });
  });
}
