import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/pages/chat/recording_view_model.dart';

void main() {
  Future<RecordingViewModelState> pumpModel(WidgetTester tester) async {
    RecordingViewModelState? capturedState;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordingViewModel(
          builder: (context, state) {
            capturedState = state;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return capturedState!;
  }

  group('RecordingViewModelState lock/cancel flags', () {
    testWidgets('defaults to unlocked and not cancelling', (tester) async {
      final state = await pumpModel(tester);
      expect(state.isLocked, isFalse);
      expect(state.isCancelling, isFalse);
      expect(state.isRecording, isFalse);
    });

    testWidgets('lock() flips isLocked to true', (tester) async {
      final state = await pumpModel(tester);
      state.lock();
      await tester.pump();
      expect(state.isLocked, isTrue);
    });

    testWidgets('lock() then unlock() restores isLocked to false',
        (tester) async {
      final state = await pumpModel(tester);
      state.lock();
      await tester.pump();
      state.unlock();
      await tester.pump();
      expect(state.isLocked, isFalse);
    });

    testWidgets('markCancelling toggles isCancelling', (tester) async {
      final state = await pumpModel(tester);
      state.markCancelling(true);
      await tester.pump();
      expect(state.isCancelling, isTrue);
      state.markCancelling(false);
      await tester.pump();
      expect(state.isCancelling, isFalse);
    });

    testWidgets('cancel() resets isLocked and isCancelling flags',
        (tester) async {
      final state = await pumpModel(tester);
      state.lock();
      state.markCancelling(true);
      await tester.pump();
      expect(state.isLocked, isTrue);
      expect(state.isCancelling, isTrue);
      state.cancel();
      await tester.pump();
      expect(state.isLocked, isFalse);
      expect(state.isCancelling, isFalse);
    });
  });
}
