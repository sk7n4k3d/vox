import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/widgets/cyber/neon_waveform.dart';

void main() {
  testWidgets('renders one bar per amplitude', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NeonWaveform(
            amplitudes: [10, 50, 90, 30],
            maxBarHeight: 36,
            barWidth: 4,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('wave_bar_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wave_bar_3')), findsOneWidget);
    expect(find.byKey(const ValueKey('wave_bar_4')), findsNothing);
  });
}
