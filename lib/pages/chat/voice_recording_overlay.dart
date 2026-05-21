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
    final visible =
        (state.isRecording || state.isStarting) && !state.isLocked;
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      height: visible ? 96 : 0,
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        border: Border(
          top: BorderSide(color: theme.colorScheme.error, width: 1),
          bottom: BorderSide(color: theme.colorScheme.error, width: 1),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: !visible
          ? const SizedBox.shrink()
          : ValueListenableBuilder<VoiceRecordGestureState>(
              valueListenable: gestureNotifier,
              builder: (context, gestureState, _) {
                final hintOpacity = (1.0 - gestureState.cancelProgress).clamp(
                  0.0,
                  1.0,
                );
                final lockProgress = gestureState.lockProgress;

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      _PulseRecDot(theme: theme),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Opacity(
                          opacity: hintOpacity,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chevron_left,
                                size: 18,
                                color: theme.colorScheme.onErrorContainer,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  l10n.voiceMessageSlideToCancel,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _LockBadge(progress: lockProgress, theme: theme),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _PulseRecDot extends StatefulWidget {
  final ThemeData theme;

  const _PulseRecDot({required this.theme});

  @override
  State<_PulseRecDot> createState() => _PulseRecDotState();
}

class _PulseRecDotState extends State<_PulseRecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: widget.theme.colorScheme.error.withValues(
              alpha: 0.4 + _pulse.value * 0.6,
            ),
            shape: BoxShape.circle,
          ),
        );
      },
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
        final pulseScale = 1.0 + _pulse.value * 0.06;
        final lockScale = 1.0 + widget.progress * 0.2;
        return Transform.scale(
          scale: pulseScale * lockScale,
          child: Container(
            width: 44,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: widget.progress > 0.5
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onErrorContainer,
                width: widget.progress > 0.5 ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.progress > 0.5 ? Icons.lock : Icons.lock_outline,
                  size: 22,
                  color: widget.progress > 0.5
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
                const SizedBox(height: 4),
                Icon(
                  Icons.keyboard_arrow_up,
                  size: 16,
                  color: theme.colorScheme.onSurface,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
