import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// Telegram-style swipe-to-reply wrapper for message bubbles.
///
/// Drags the [child] horizontally, reveals a reply icon behind it, and calls
/// [onReply] when the drag passes [thresholdPx]. Releases before the threshold
/// spring back to zero with an elastic [SpringSimulation]; haptic medium fires
/// exactly once per drag the first time the threshold is crossed.
///
/// Coexists with `GestureDetector(onLongPress / onDoubleTap)` further down the
/// tree because we use a `HorizontalDragGestureRecognizer` via `RawGestureDetector`
/// (the gesture arena resolves vertical/long-press conflicts naturally).
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    required this.child,
    required this.onReply,
    this.reverse = false,
    this.maxOffsetPx = 80.0,
    this.thresholdPx = 60.0,
    super.key,
  });

  /// The widget to wrap (typically the message bubble row).
  final Widget child;

  /// Callback fired once when the drag is released past [thresholdPx].
  final VoidCallback onReply;

  /// `true` = swipe right-to-left (end -> start), `false` = left-to-right.
  /// Matches `AppSettings.swipeRightToLeftToReply` semantics from the caller.
  final bool reverse;

  /// Maximum drag distance (in logical px) the bubble can be pulled.
  final double maxOffsetPx;

  /// Distance (in logical px) at which the reply intent is committed.
  final double thresholdPx;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  /// Current horizontal translation of the bubble. Sign follows the swipe
  /// direction: negative for right-to-left, positive for left-to-right.
  double _offset = 0.0;

  /// Whether the threshold was crossed during the current drag, so that we
  /// emit the medium haptic exactly once (and not on every frame past it).
  bool _thresholdCrossedThisDrag = false;

  /// Whether a drag is currently underway (vs. a spring-back animation).
  bool _dragUnderway = false;

  late final AnimationController _springController;

  // Spring simulation tuning (M3 Expressive feel).
  static const double _springStiffness = 380.0;
  static const double _springDamping = 28.0;
  static const double _springMass = 1.0;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController.unbounded(vsync: this)
      ..addListener(_onSpringTick);
  }

  @override
  void dispose() {
    _springController
      ..removeListener(_onSpringTick)
      ..dispose();
    super.dispose();
  }

  void _onSpringTick() {
    if (!mounted) return;
    setState(() => _offset = _springController.value);
  }

  /// Sign that the user must drag toward to be valid (negative = RTL swipe).
  double get _validSign => widget.reverse ? -1.0 : 1.0;

  void _handleDragStart(DragStartDetails details) {
    _springController.stop();
    _dragUnderway = true;
    _thresholdCrossedThisDrag = false;
    // Keep the current offset (in case a spring-back was mid-flight) so the
    // drag feels continuous.
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_dragUnderway) return;
    var next = _offset + details.delta.dx;

    // Only allow drag in the configured direction; clamp to the valid sign so
    // dragging the wrong way does nothing.
    if (_validSign > 0) {
      if (next < 0) next = 0;
      if (next > widget.maxOffsetPx) {
        // Rubber-band past max: 25% follow-through for tactile feedback.
        next = widget.maxOffsetPx + (next - widget.maxOffsetPx) * 0.25;
      }
    } else {
      if (next > 0) next = 0;
      if (next < -widget.maxOffsetPx) {
        next = -widget.maxOffsetPx + (next + widget.maxOffsetPx) * 0.25;
      }
    }

    setState(() => _offset = next);

    // Fire haptic exactly once per drag, when crossing the threshold.
    if (!_thresholdCrossedThisDrag &&
        next.abs() >= widget.thresholdPx) {
      _thresholdCrossedThisDrag = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    _dragUnderway = false;
    final shouldReply = _offset.abs() >= widget.thresholdPx;

    // Spring back to 0 in every case (no permanent dismiss), so the bubble
    // stays in place after the reply intent is registered.
    final simulation = SpringSimulation(
      const SpringDescription(
        mass: _springMass,
        stiffness: _springStiffness,
        damping: _springDamping,
      ),
      _offset,
      0.0,
      details.velocity.pixelsPerSecond.dx,
    );
    _springController.animateWith(simulation);

    if (shouldReply) {
      // Defer to next frame so the visual snap-back starts immediately while
      // the parent opens the reply composer.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onReply();
      });
    }
  }

  void _handleDragCancel() {
    _dragUnderway = false;
    final simulation = SpringSimulation(
      const SpringDescription(
        mass: _springMass,
        stiffness: _springStiffness,
        damping: _springDamping,
      ),
      _offset,
      0.0,
      0.0,
    );
    _springController.animateWith(simulation);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();

    final progress = (_offset.abs() / widget.thresholdPx).clamp(0.0, 1.0);
    final past = _offset.abs() >= widget.thresholdPx;
    // Icon scale ramps 0.7 -> 1.0 across the drag, then a tiny pop at threshold.
    final iconScale = 0.7 + 0.3 * progress + (past ? 0.06 : 0.0);
    final iconOpacity = progress;

    final accent = theme.colorScheme.primary;
    final pillColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.7);

    // The icon sits on the opposite side of the drag direction so it is
    // revealed as the bubble slides away (Telegram behaviour).
    final iconOnRight = widget.reverse;

    return GestureDetector(
      // Listen on drag *down* so we still let onLongPress / onDoubleTap on the
      // child win when there's no horizontal movement (gesture arena does the
      // rest).
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.start,
      onHorizontalDragStart: _handleDragStart,
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      onHorizontalDragCancel: _handleDragCancel,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Reveal icon behind the bubble. Positioned on the side opposite to
          // the swipe direction.
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: iconOnRight
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Opacity(
                    opacity: iconOpacity,
                    child: Transform.scale(
                      scale: iconScale,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pillColor,
                          border: Border.all(
                            color: accent.withValues(alpha: 0.6),
                            width: 1,
                          ),
                          boxShadow: past && cyber != null
                              ? [
                                  BoxShadow(
                                    color:
                                        cyber.cyan.withValues(alpha: 0.45),
                                    blurRadius: 14,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          Icons.reply_rounded,
                          size: 26,
                          color: accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_offset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
