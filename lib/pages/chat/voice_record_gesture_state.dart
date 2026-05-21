import 'package:flutter/material.dart';

const double kLockThresholdDy = -80.0;
const double kLockProgressMaxDy = -120.0;
const double kCancelThresholdRatio = 0.40;

@immutable
class VoiceRecordGestureState {
  final Offset offset;
  final double lockProgress;
  final double cancelProgress;

  const VoiceRecordGestureState({
    required this.offset,
    required this.lockProgress,
    required this.cancelProgress,
  });

  static const VoiceRecordGestureState zero = VoiceRecordGestureState(
    offset: Offset.zero,
    lockProgress: 0.0,
    cancelProgress: 0.0,
  );

  bool get reachedLockThreshold => offset.dy <= kLockThresholdDy;

  bool reachedCancelThreshold(double screenWidth) =>
      offset.dx <= -screenWidth * kCancelThresholdRatio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoiceRecordGestureState &&
          other.offset == offset &&
          other.lockProgress == lockProgress &&
          other.cancelProgress == cancelProgress;

  @override
  int get hashCode => Object.hash(offset, lockProgress, cancelProgress);
}

VoiceRecordGestureState computeGestureState(
  Offset offset,
  double screenWidth,
) {
  final lockProgress =
      (offset.dy.clamp(kLockProgressMaxDy, 0.0) / kLockProgressMaxDy).clamp(
        0.0,
        1.0,
      );
  final cancelDenominator = screenWidth * kCancelThresholdRatio;
  final cancelProgress = cancelDenominator <= 0
      ? 0.0
      : (-offset.dx / cancelDenominator).clamp(0.0, 1.0);
  return VoiceRecordGestureState(
    offset: offset,
    lockProgress: lockProgress,
    cancelProgress: cancelProgress,
  );
}
