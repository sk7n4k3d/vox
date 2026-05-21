import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

/// Quick-react floating picker shown on double-tap above a message bubble.
///
/// 6 quick emojis, blur backdrop, scale + opacity spring entry.
class MessageQuickReactPicker extends StatefulWidget {
  final Event event;
  final List<String> emojis;
  final VoidCallback onDismiss;

  const MessageQuickReactPicker({
    required this.event,
    required this.onDismiss,
    this.emojis = const ['❤️', '👍', '😂', '😮', '😢', '🙏'],
    super.key,
  });

  /// Show the picker as an Overlay anchored above the given bubble RenderBox.
  ///
  /// Returns a [OverlayEntry] handle so the caller can remove it
  /// programmatically if needed. The picker auto-removes itself on dismiss.
  static OverlayEntry show({
    required BuildContext context,
    required Event event,
    required Rect bubbleRect,
    List<String> emojis = const ['❤️', '👍', '😂', '😮', '😢', '🙏'],
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;

    // Picker dimensions: 6 emojis x 40dp + 5 gaps x 12dp + 2 x 8dp padding
    // = 240 + 60 + 16 = 316 dp wide, height 56dp.
    const pickerWidth = 316.0;
    const pickerHeight = 56.0;
    const verticalGap = 8.0;

    final screen = MediaQuery.of(context).size;

    // Anchor above the bubble if there is room; otherwise below.
    var top = bubbleRect.top - pickerHeight - verticalGap;
    if (top < MediaQuery.of(context).padding.top + 8) {
      top = bubbleRect.bottom + verticalGap;
    }

    // Horizontal: center over the bubble but clamp to screen with 8dp margins.
    var left = bubbleRect.center.dx - pickerWidth / 2;
    left = left.clamp(8.0, screen.width - pickerWidth - 8.0);

    entry = OverlayEntry(
      builder: (overlayContext) {
        return Positioned.fill(
          child: Stack(
            children: [
              // Tap-outside dismiss layer.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (entry.mounted) entry.remove();
                  },
                ),
              ),
              Positioned(
                left: left,
                top: top,
                width: pickerWidth,
                height: pickerHeight,
                child: MessageQuickReactPicker(
                  event: event,
                  emojis: emojis,
                  onDismiss: () {
                    if (entry.mounted) entry.remove();
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    overlay.insert(entry);
    return entry;
  }

  @override
  State<MessageQuickReactPicker> createState() =>
      _MessageQuickReactPickerState();
}

class _MessageQuickReactPickerState extends State<MessageQuickReactPicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  int? _tappedIndex;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _scale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onEmojiTap(int index, String emoji) async {
    if (_tappedIndex != null) return;
    setState(() => _tappedIndex = index);

    HapticFeedback.mediumImpact();

    // Fire reaction (no await for the network round-trip; UX must stay snappy).
    // ignore: unawaited_futures
    widget.event.room.sendReaction(widget.event.eventId, emoji);

    // Brief tap animation, then dismiss.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.92,
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.40),
                  offset: const Offset(0, 8),
                  blurRadius: 24,
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < widget.emojis.length; i++)
                  _QuickEmojiButton(
                    emoji: widget.emojis[i],
                    tapped: _tappedIndex == i,
                    onTap: () => _onEmojiTap(i, widget.emojis[i]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickEmojiButton extends StatefulWidget {
  final String emoji;
  final bool tapped;
  final VoidCallback onTap;

  const _QuickEmojiButton({
    required this.emoji,
    required this.tapped,
    required this.onTap,
  });

  @override
  State<_QuickEmojiButton> createState() => _QuickEmojiButtonState();
}

class _QuickEmojiButtonState extends State<_QuickEmojiButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tapController;
  late final Animation<double> _tapScale;

  @override
  void initState() {
    super.initState();
    _tapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // Two-stage: 1.0 -> 0.7 (compress) -> 1.1 (overshoot via elasticOut).
    _tapScale = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.7).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.7, end: 1.1).chain(
          CurveTween(curve: Curves.elasticOut),
        ),
        weight: 75,
      ),
    ]).animate(_tapController);
  }

  @override
  void didUpdateWidget(covariant _QuickEmojiButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tapped && !oldWidget.tapped) {
      _tapController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _tapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: AnimatedBuilder(
            animation: _tapController,
            builder: (context, child) {
              return Transform.scale(
                scale: widget.tapped ? _tapScale.value : 1.0,
                child: child,
              );
            },
            child: Text(
              widget.emoji,
              style: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      ),
    );
  }
}
