import 'dart:ui';

import 'package:fluffychat/config/design_tokens.dart';
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
    return _OverlayShell(
      visible: visible,
      child: ValueListenableBuilder<VoiceRecordGestureState>(
        valueListenable: gestureNotifier,
        builder: (context, gestureState, _) {
          final theme = Theme.of(context);
          final l10n = L10n.of(context);
          final hintOpacity =
              (1.0 - gestureState.cancelProgress).clamp(0.0, 1.0);
          final lockProgress = gestureState.lockProgress;
          final scheme = theme.colorScheme;

          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            child: Row(
              children: [
                _PulseRecDot(color: scheme.error),
                const SizedBox(width: 10),
                _LiveTimer(state: state, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Opacity(
                    opacity: hintOpacity,
                    child: _SlideToCancelHint(
                      color: scheme.onSurfaceVariant,
                      label: l10n.voiceMessageSlideToCancel,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _LockBadge(progress: lockProgress, scheme: scheme),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Smooth size+opacity+blur exit. Returns SizedBox(0) when fully closed so no
/// pixels remain in the layout tree.
class _OverlayShell extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _OverlayShell({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tinted = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.06),
      scheme.surfaceContainerHighest,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: visible ? 1.0 : 0.0),
      duration: visible ? FluffyDurations.medium : FluffyDurations.fast,
      curve: visible ? Curves.easeOutBack : FluffyCurves.accelerated,
      builder: (context, t, animatedChild) {
        if (t <= 0.001) {
          return const SizedBox(width: double.infinity, height: 0);
        }
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t.clamp(0.0, 1.0),
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  width: double.infinity,
                  height: 72,
                  decoration: BoxDecoration(
                    color: tinted,
                    border: Border(
                      top: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                        width: 0.5,
                      ),
                      bottom: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: animatedChild,
                ),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _PulseRecDot extends StatefulWidget {
  final Color color;

  const _PulseRecDot({required this.color});

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
      duration: const Duration(milliseconds: 800),
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
        final t = Curves.easeInOutSine.transform(_pulse.value);
        return SizedBox(
          width: 14,
          height: 14,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.25 * (1 - t)),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.65 + 0.35 * t),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveTimer extends StatefulWidget {
  final RecordingViewModelState state;
  final Color color;

  const _LiveTimer({required this.state, required this.color});

  @override
  State<_LiveTimer> createState() => _LiveTimerState();
}

class _LiveTimerState extends State<_LiveTimer> {
  @override
  Widget build(BuildContext context) {
    final d = widget.state.duration;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Text(
      '$mm:$ss',
      style: TextStyle(
        color: widget.color,
        fontFamily: 'monospace',
        fontSize: 13,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _SlideToCancelHint extends StatefulWidget {
  final Color color;
  final String label;

  const _SlideToCancelHint({required this.color, required this.label});

  @override
  State<_SlideToCancelHint> createState() => _SlideToCancelHintState();
}

class _SlideToCancelHintState extends State<_SlideToCancelHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, _) {
        final t = Curves.easeInOutSine.transform(_slide.value);
        final dx = -4.0 - t * 4.0;
        return Center(
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chevron_left, size: 18, color: widget.color),
                const SizedBox(width: 2),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LockBadge extends StatefulWidget {
  final double progress;
  final ColorScheme scheme;

  const _LockBadge({required this.progress, required this.scheme});

  @override
  State<_LockBadge> createState() => _LockBadgeState();
}

class _LockBadgeState extends State<_LockBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob;

  @override
  void initState() {
    super.initState();
    _bob = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reached = widget.progress >= 0.5;
    final accent = reached ? widget.scheme.primary : widget.scheme.tertiary;
    return AnimatedBuilder(
      animation: _bob,
      builder: (context, _) {
        final wobble = Curves.easeInOutSine.transform(_bob.value);
        final translateY = -wobble * 3 + (-widget.progress * 16);
        final scale = 1.0 + widget.progress * 0.15;
        return Transform.translate(
          offset: Offset(0, translateY),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 36,
              height: 48,
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.10),
                  widget.scheme.surfaceContainerHigh,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: reached
                      ? widget.scheme.primary
                      : widget.scheme.outlineVariant,
                  width: reached ? 1.5 : 0.5,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    reached ? Icons.lock : Icons.lock_outline,
                    size: 18,
                    color: reached
                        ? widget.scheme.primary
                        : widget.scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 2),
                  Icon(
                    Icons.keyboard_arrow_up,
                    size: 12,
                    color: widget.scheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
