import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/chat_input_row.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/pages/chat/voice_record_gesture_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VoiceRecordButton extends StatefulWidget {
  final ChatController controller;
  final RecordingViewModelState recordingState;
  final ValueNotifier<VoiceRecordGestureState> gestureNotifier;
  final Color backgroundColor;
  final Color foregroundColor;

  const VoiceRecordButton({
    required this.controller,
    required this.recordingState,
    required this.gestureNotifier,
    required this.backgroundColor,
    required this.foregroundColor,
    super.key,
  });

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends State<VoiceRecordButton> {
  Offset _origin = Offset.zero;
  bool _pressActive = false;

  void _showTooltipSnackBar() {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        margin: EdgeInsets.only(
          bottom: ChatInputRow.height + 16 + bottomInset,
          left: 16,
          right: 16,
          top: 16,
        ),
        showCloseIcon: true,
        content: Text(L10n.of(context).longPressToRecordVoiceMessage),
      ),
    );
  }

  void _handleLongPressDown(LongPressDownDetails details) {
    _origin = details.globalPosition;
  }

  Future<void> _handleLongPressStart(LongPressStartDetails details) async {
    _pressActive = true;
    widget.gestureNotifier.value = VoiceRecordGestureState.zero;
    HapticFeedback.lightImpact();
    await widget.recordingState.startRecording(widget.controller.room);
    if (!_pressActive && widget.recordingState.isRecording) {
      widget.recordingState.cancel();
    }
  }

  void _handleLongPressMove(LongPressMoveUpdateDetails details) {
    final state = widget.recordingState;
    if (!state.isRecording || state.isLocked || state.isCancelling) return;
    final offset = details.globalPosition - _origin;
    final screenWidth = MediaQuery.of(context).size.width;
    final gestureState = computeGestureState(offset, screenWidth);
    widget.gestureNotifier.value = gestureState;

    if (gestureState.reachedLockThreshold) {
      HapticFeedback.mediumImpact();
      state.lock();
      widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      return;
    }

    if (gestureState.reachedCancelThreshold(screenWidth)) {
      HapticFeedback.mediumImpact();
      state.markCancelling(true);
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted || !state.mounted) return;
        if (state.isRecording) state.cancel();
        widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      });
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    _pressActive = false;
    final state = widget.recordingState;
    if (!state.isRecording) {
      widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      return;
    }
    if (state.isLocked || state.isCancelling) {
      widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      return;
    }

    final offset = details.globalPosition - _origin;
    final screenWidth = MediaQuery.of(context).size.width;

    if (offset.dy <= kLockThresholdDy) {
      state.lock();
      widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      return;
    }

    if (offset.dx <= -screenWidth * kCancelThresholdRatio) {
      state.markCancelling(true);
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted || !state.mounted) return;
        if (state.isRecording) state.cancel();
        widget.gestureNotifier.value = VoiceRecordGestureState.zero;
      });
      return;
    }

    widget.gestureNotifier.value = VoiceRecordGestureState.zero;
    state.stopAndSend(widget.controller.onVoiceMessageSend);
  }

  void _handleLongPressCancel() {
    if (!_pressActive) return;
    _pressActive = false;
    widget.gestureNotifier.value = VoiceRecordGestureState.zero;
  }

  Future<void> _handleTapAccessible() async {
    final state = widget.recordingState;
    if (state.isRecording) {
      await state.stopAndSend(widget.controller.onVoiceMessageSend);
    } else {
      HapticFeedback.lightImpact();
      await state.startRecording(widget.controller.room);
      if (state.isRecording) state.lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accessibleNavigation = MediaQuery.of(context).accessibleNavigation;
    final isRecording = widget.recordingState.isRecording;
    final isLocked = widget.recordingState.isLocked;
    final shouldEnlarge = isRecording && !isLocked;

    if (accessibleNavigation) {
      return IconButton(
        tooltip: L10n.of(context).voiceMessage,
        onPressed: _handleTapAccessible,
        style: IconButton.styleFrom(
          backgroundColor: widget.backgroundColor,
          foregroundColor: widget.foregroundColor,
        ),
        icon: Icon(isRecording ? Icons.stop : Icons.mic_none_outlined),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showTooltipSnackBar,
      onLongPressDown: _handleLongPressDown,
      onLongPressStart: _handleLongPressStart,
      onLongPressMoveUpdate: _handleLongPressMove,
      onLongPressEnd: _handleLongPressEnd,
      onLongPressCancel: _handleLongPressCancel,
      child: AnimatedScale(
        scale: shouldEnlarge ? 1.4 : 1.0,
        duration: FluffyDurations.fast,
        curve: FluffyCurves.decelerated,
        child: Semantics(
          button: true,
          label: L10n.of(context).voiceMessage,
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.backgroundColor,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isRecording ? Icons.mic : Icons.mic_none_outlined,
              color: widget.foregroundColor,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
