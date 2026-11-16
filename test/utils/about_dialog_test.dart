import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _mockPackageInfo() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/package_info'),
        (call) async => <String, String>{
          'packageName': 'eu.devlabz.vox',
          'appName': 'VOX',
          'version': '2.5.1',
          'buildNumber': '3552',
        },
      );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    _mockPackageInfo();
  });

  Future<void> pumpAndOpen(WidgetTester tester) async {
    late BuildContext rootContext;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('fr'),
        home: Builder(
          builder: (context) {
            rootContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    // Les delegates L10n se résolvent en async : laisser la première frame
    // passer avant d'utiliser le contexte.
    await tester.pumpAndSettle();
    // Le dialog navigue (/logs, /configs) via go_router : hors routeur les
    // boutons restent rendus, seuls les taps activeraient le contexte
    // manquant — ce test ne les tappe pas.
    // ignore: unawaited_futures
    PlatformInfos.showDialog(rootContext);
    await tester.pumpAndSettle();
  }

  testWidgets('À propos : nom, version, icône et actions rendus', (
    tester,
  ) async {
    await pumpAndOpen(tester);
    expect(
      find.text(AppSettings.applicationName.value),
      findsOneWidget,
      reason: "le nom de l'app doit être affiché",
    );
    expect(find.textContaining('Version:'), findsOneWidget);
    expect(find.text('Code source'), findsOneWidget);
    expect(find.text('Fermer'), findsOneWidget);
    final logo = tester.widget<Image>(find.byType(Image).first);
    expect(logo.image, isA<AssetImage>());
    expect((logo.image as AssetImage).assetName, 'assets/logo.png');
    // Le contenu doit tenir dans le dialog sans overflow (signalé « mal
    // centré » sur mobile) : tout est dans le viewport.
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fermer ferme le dialog', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Code source'), findsNothing);
  });
}
