import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/screen_effects/screen_effect.dart';
import 'package:fluffychat/widgets/cyber/screen_effect_overlay.dart';

void main() {
  testWidgets('throttle: 2e play immédiat est ignoré', (tester) async {
    final ctrl = ScreenEffectController(throttle: const Duration(seconds: 3));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    );
    expect(ctrl.play(ctx, ScreenEffect.confetti), isTrue);
    expect(ctrl.play(ctx, ScreenEffect.confetti), isFalse); // throttlé
    ctrl.dispose();
  });

  testWidgets('skip si animations désactivées', (tester) async {
    final ctrl = ScreenEffectController();
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ),
      ),
    );
    expect(ctrl.play(ctx, ScreenEffect.confetti), isFalse);
    ctrl.dispose();
  });
}
