import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/pages/chat/voice_record_gesture_state.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// CYBERCORE premium recording overlay — a floating glass panel that sits above
/// the input bar while you hold-to-record. Live waveform driven by the
/// recorder amplitude, a magenta slide-to-cancel hint that intensifies as you
/// drag left, and a cyan lock badge that rises as you drag up.
///
/// Shown whenever recording is starting/active and not yet locked. Reduce-motion
/// pauses the pulse/scroll animations.
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
          final cyber = CyberColors.of(context);
          final l10n = L10n.of(context);
          final reduce = CyberMotion.reduced(context);
          final cancelProgress = gestureState.cancelProgress.clamp(0.0, 1.0);
          final lockProgress = gestureState.lockProgress.clamp(0.0, 1.0);
          final cancelling = state.isCancelling || cancelProgress > 0.6;

          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.md,
            ),
            child: Row(
              children: [
                _PulseRecDot(
                  color: cancelling ? cyber.magenta : cyber.cyan,
                  reduce: reduce,
                ),
                const SizedBox(width: FluffySpacing.md),
                _LiveTimer(state: state, color: cyber.cyan),
                const SizedBox(width: FluffySpacing.md),
                Expanded(
                  child: cancelling
                      ? _CancelHint(color: cyber.magenta, label: l10n.cancel)
                      : _LiveWaveform(
                          state: state,
                          color: cyber.cyan,
                          fade: 1.0 - cancelProgress,
                        ),
                ),
                const SizedBox(width: FluffySpacing.md),
                _SlideToCancelChevrons(
                  color: cyber.magenta,
                  label: l10n.voiceMessageSlideToCancel,
                  progress: cancelProgress,
                  reduce: reduce,
                ),
                const SizedBox(width: FluffySpacing.md),
                _LockBadge(
                  progress: lockProgress,
                  cyber: cyber,
                  reduce: reduce,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Floating glass shell with smooth height+opacity entrance, hairline + faint
/// cyan glow. Collapses to a zero-height box when hidden.
class _OverlayShell extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _OverlayShell({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: visible ? 1.0 : 0.0),
      duration: visible ? FluffyDurations.medium : FluffyDurations.fast,
      curve: visible ? Curves.easeOutBack : FluffyCurves.accelerated,
      builder: (context, t, animatedChild) {
        if (t <= 0.001) {
          return const SizedBox(width: double.infinity, height: 0);
        }
        final tc = t.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: tc,
            child: Opacity(
              opacity: tc,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  FluffySpacing.sm,
                  FluffySpacing.sm,
                  FluffySpacing.sm,
                  FluffySpacing.xs,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: FluffyRadius.brLg,
                    boxShadow: FluffyElevation.glowCyan(cyber.cyan, alpha: 0.18),
                  ),
                  child: ClipRRect(
                    borderRadius: FluffyRadius.brLg,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: cyber.blurSigmaSheet,
                        sigmaY: cyber.blurSigmaSheet,
                      ),
                      child: Container(
                        width: double.infinity,
                        height: 100,
                        decoration: BoxDecoration(
                          color: cyber.glassFillStrong,
                          borderRadius: FluffyRadius.brLg,
                          border: Border.all(color: cyber.glassBorder),
                        ),
                        child: animatedChild,
                      ),
                    ),
                  ),
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

/// Pulsing record dot with a soft expanding halo.
class _PulseRecDot extends StatefulWidget {
  final Color color;
  final bool reduce;

  const _PulseRecDot({required this.color, required this.reduce});

  @override
  State<_PulseRecDot> createState() => _PulseRecDotState();
}

class _PulseRecDotState extends State<_PulseRecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduce) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulseRecDot old) {
    super.didUpdateWidget(old);
    if (widget.reduce && _pulse.isAnimating) {
      _pulse.stop();
    } else if (!widget.reduce && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
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
          width: 16,
          height: 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.22 * (1 - t)),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.7 + 0.3 * t),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.5 * t),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Monospace live timer (mm:ss), tabular figures.
class _LiveTimer extends StatelessWidget {
  final RecordingViewModelState state;
  final Color color;

  const _LiveTimer({required this.state, required this.color});

  @override
  Widget build(BuildContext context) {
    final d = state.duration;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Text(
      '$mm:$ss',
      style: FluffyTypography.code.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Live waveform: scrolling cyan bars driven by the recorder amplitude
/// timeline. Most recent samples on the right.
class _LiveWaveform extends StatelessWidget {
  final RecordingViewModelState state;
  final Color color;
  final double fade;

  const _LiveWaveform({
    required this.state,
    required this.color,
    required this.fade,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const barWidth = 3.0;
        const gap = 2.0;
        final maxBars = (constraints.maxWidth / (barWidth + gap)).floor();
        final samples = state.amplitudeTimeline.reversed
            .take(maxBars)
            .toList()
            .reversed
            .toList();
        return Opacity(
          opacity: fade.clamp(0.2, 1.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < samples.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: gap),
                  child: Container(
                    width: barWidth,
                    height: (28.0 * (samples[i] / 100)).clamp(3.0, 28.0),
                    decoration: BoxDecoration(
                      color: color.withValues(
                        // newest bars brightest
                        alpha: 0.4 + 0.6 * (i / samples.length),
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Full-width "release to cancel" treatment shown once cancel is imminent.
class _CancelHint extends StatelessWidget {
  final Color color;
  final String label;

  const _CancelHint({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.delete_outline_rounded, size: 20, color: color),
        const SizedBox(width: FluffySpacing.sm),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: FluffyTypography.labelL.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// Animated "‹ ‹ slide to cancel" chevrons that drift left; tint ramps to
/// magenta as cancelProgress grows.
class _SlideToCancelChevrons extends StatefulWidget {
  final Color color;
  final String label;
  final double progress;
  final bool reduce;

  const _SlideToCancelChevrons({
    required this.color,
    required this.label,
    required this.progress,
    required this.reduce,
  });

  @override
  State<_SlideToCancelChevrons> createState() => _SlideToCancelChevronsState();
}

class _SlideToCancelChevronsState extends State<_SlideToCancelChevrons>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduce) _drift.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_SlideToCancelChevrons old) {
    super.didUpdateWidget(old);
    if (widget.reduce && _drift.isAnimating) {
      _drift.stop();
    } else if (!widget.reduce && !_drift.isAnimating) {
      _drift.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hidden when cancel is essentially triggered (the _CancelHint takes over).
    if (widget.progress > 0.6) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _drift,
      builder: (context, _) {
        final t = Curves.easeInOutSine.transform(_drift.value);
        final dx = -2.0 - t * 4.0;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Icon(
            Icons.keyboard_double_arrow_left_rounded,
            size: 18,
            color: widget.color.withValues(alpha: 0.55 + 0.45 * widget.progress),
          ),
        );
      },
    );
  }
}

/// Cyan lock badge that rises and lights up as lockProgress increases.
class _LockBadge extends StatefulWidget {
  final double progress;
  final CyberpunkTheme cyber;
  final bool reduce;

  const _LockBadge({
    required this.progress,
    required this.cyber,
    required this.reduce,
  });

  @override
  State<_LockBadge> createState() => _LockBadgeState();
}

class _LockBadgeState extends State<_LockBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduce) _bob.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_LockBadge old) {
    super.didUpdateWidget(old);
    if (widget.reduce && _bob.isAnimating) {
      _bob.stop();
    } else if (!widget.reduce && !_bob.isAnimating) {
      _bob.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reached = widget.progress >= 0.5;
    final accent = reached ? widget.cyber.cyan : widget.cyber.violet;
    return AnimatedBuilder(
      animation: _bob,
      builder: (context, _) {
        final wobble = Curves.easeInOutSine.transform(_bob.value);
        final translateY = -wobble * 3 + (-widget.progress * 16);
        final scale = 1.0 + widget.progress * 0.18;
        return Transform.translate(
          offset: Offset(0, translateY),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 38,
              height: 50,
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.12),
                  widget.cyber.glassFillStrong,
                ),
                borderRadius: FluffyRadius.brLg,
                border: Border.all(
                  color: reached
                      ? accent
                      : widget.cyber.glassBorder,
                  width: reached ? 1.5 : 0.5,
                ),
                boxShadow: reached
                    ? FluffyElevation.glowCyan(accent, alpha: 0.4)
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    reached ? Icons.lock_rounded : Icons.lock_outline_rounded,
                    size: 18,
                    color: reached ? accent : widget.cyber.violet,
                  ),
                  const SizedBox(height: 2),
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 12,
                    color: accent.withValues(alpha: 0.7),
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
