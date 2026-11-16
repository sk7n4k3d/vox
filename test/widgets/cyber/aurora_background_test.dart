import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/aurora_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [CyberpunkTheme.dark()]),
        home: Scaffold(body: child),
      ),
    );

Offset? _translateOf(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(Transform),
        )
        .first,
  );
  final matrix = transform.transform;
  return Offset(matrix.storage[12], matrix.storage[13]);
}

void main() {
  group('AuroraBackground', () {
    testWidgets('pré-rasterise le calque dans une image (pas de CustomPaint '
        'vivant dans l\'arbre)', (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(), reduceMotion: true),
      );
      // Le calque est peint UNE fois dans un ui.Image puis affiché par un
      // RawImage : aucun CustomPaint ne survit dans l'arbre (sinon les
      // dégradés plein écran seraient re-joués à chaque image produite).
      expect(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(RawImage),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('sous reduce-motion : pas de timer, dérive figée',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const AuroraBackground(period: Duration(seconds: 1)),
          reduceMotion: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // Sans timer, rien ne programme d'image : l'offset ne bouge jamais.
      final start = _translateOf(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(_translateOf(tester), start);
    });

    testWidgets('mouvement autorisé : la dérive avance par pas (8 img/s)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const AuroraBackground(period: Duration(seconds: 1))),
      );
      final start = _translateOf(tester);
      // Un pas = 1/8 s (125 ms) : après un pas, l'offset a bougé.
      await tester.pump(const Duration(milliseconds: 125));
      final moved = _translateOf(tester)!;
      expect(moved, isNot(start));
      // Et l'offset reste borné (dérive ≤ 22 px).
      expect(moved.dx.abs() <= 22.0, isTrue);
      expect(moved.dy.abs() <= 18.0, isTrue);
      // Démonter pour annuler le Timer.periodic (pas de timer pendant).
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('l\'opacité demandée est cuite dans l\'image rendue',
        (tester) async {
      // L'opacité n'est plus un widget Opacity (qui forçait un calque
      // offscreen plein écran) : elle est multipliée dans les couleurs du
      // painter. On vérifie au moins que le rendu avec opacité custom
      // fonctionne et produit une image non vide.
      await tester.pumpWidget(
        _wrap(const AuroraBackground(opacity: 0.4), reduceMotion: true),
      );
      final image = tester.widget<RawImage>(
        find.descendant(
          of: find.byType(AuroraBackground),
          matching: find.byType(RawImage),
        ),
      ).image;
      expect(image, isNotNull);
      expect(image!.width, greaterThan(0));
      expect(image.height, greaterThan(0));
    });
  });
}
