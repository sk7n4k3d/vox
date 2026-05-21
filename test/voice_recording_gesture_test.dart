import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/pages/chat/voice_record_gesture_state.dart';

void main() {
  group('computeGestureState', () {
    const double screenWidth = 400.0;

    test('zero offset yields zero progress', () {
      final state = computeGestureState(Offset.zero, screenWidth);
      expect(state.lockProgress, 0.0);
      expect(state.cancelProgress, 0.0);
      expect(state.offset, Offset.zero);
      expect(state.reachedLockThreshold, isFalse);
      expect(state.reachedCancelThreshold(screenWidth), isFalse);
    });

    test('slide up below lock threshold yields partial lock progress', () {
      final state = computeGestureState(const Offset(0, -40), screenWidth);
      expect(state.lockProgress, closeTo(40 / 120, 1e-9));
      expect(state.cancelProgress, 0.0);
      expect(state.reachedLockThreshold, isFalse);
    });

    test('slide up beyond lock threshold yields progress 1 and triggers lock', () {
      final state =
          computeGestureState(const Offset(0, kLockProgressMaxDy - 50), screenWidth);
      expect(state.lockProgress, 1.0);
      expect(state.reachedLockThreshold, isTrue);
    });

    test('slide left reaches cancel threshold at 40% of screen width', () {
      final state = computeGestureState(
        const Offset(-screenWidth * kCancelThresholdRatio, 0),
        screenWidth,
      );
      expect(state.cancelProgress, 1.0);
      expect(state.reachedCancelThreshold(screenWidth), isTrue);
      expect(state.lockProgress, 0.0);
    });

    test('mixed diagonal offset computes both progresses independently', () {
      final state = computeGestureState(const Offset(-80, -60), screenWidth);
      expect(state.lockProgress, closeTo(60 / 120, 1e-9));
      expect(state.cancelProgress, closeTo(80 / (screenWidth * kCancelThresholdRatio), 1e-9));
      expect(state.reachedLockThreshold, isFalse);
      expect(state.reachedCancelThreshold(screenWidth), isFalse);
    });
  });
}
