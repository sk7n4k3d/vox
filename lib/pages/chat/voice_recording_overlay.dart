import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/pages/chat/voice_record_gesture_state.dart';
import 'package:flutter/material.dart';

class VoiceRecordingOverlay extends StatelessWidget {
  final RecordingViewModelState state;
  final ValueNotifier<VoiceRecordGestureState> gestureNotifier;

  const VoiceRecordingOverlay({
    required this.state,
    required this.gestureNotifier,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!state.isRecording || state.isLocked) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<VoiceRecordGestureState>(
          valueListenable: gestureNotifier,
          builder: (context, gestureState, _) {
            final hintOpacity = (1.0 - gestureState.cancelProgress).clamp(
              0.0,
              1.0,
            );
            final lockScale = 1.0 + gestureState.lockProgress * 0.2;
            final lockOffsetY = -gestureState.lockProgress * 24.0;

            return Stack(
              children: [
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 0,
                  top: 0,
                  child: Center(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Opacity(
                        opacity: hintOpacity,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.chevron_left,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              l10n.voiceMessageSlideToCancel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 64,
                  child: Transform.translate(
                    offset: Offset(0, lockOffsetY),
                    child: Transform.scale(
                      scale: lockScale,
                      child: _LockBadge(
                        progress: gestureState.lockProgress,
                        theme: theme,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LockBadge extends StatefulWidget {
  final double progress;
  final ThemeData theme;

  const _LockBadge({required this.progress, required this.theme});

  @override
  State<_LockBadge> createState() => _LockBadgeState();
}

class _LockBadgeState extends State<_LockBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final pulseScale = 1.0 + _pulse.value * 0.08;
        return Transform.scale(
          scale: pulseScale,
          child: Container(
            width: 44,
            height: 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: widget.progress > 0.5
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 2),
                Icon(
                  Icons.keyboard_arrow_up,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
