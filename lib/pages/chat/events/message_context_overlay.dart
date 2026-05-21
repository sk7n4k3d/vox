import 'dart:async';
import 'dart:ui';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

/// iMessage-style context menu overlay for a single message.
///
/// On long-press the chat behind is blurred (sigma 24), the pressed bubble is
/// "lifted off" (translated up + scaled + drop shadow), a quick-react row
/// floats above the bubble and an actions card slides up below. Tap-outside,
/// swipe-down or tapping any action dismisses the overlay.
class MessageContextOverlay extends StatefulWidget {
  final Event event;
  final ChatController controller;
  final Rect bubbleRect;
  final Widget bubbleContent;
  final bool ownMessage;
  final VoidCallback onDismiss;

  const MessageContextOverlay({
    required this.event,
    required this.controller,
    required this.bubbleRect,
    required this.bubbleContent,
    required this.ownMessage,
    required this.onDismiss,
    super.key,
  });

  /// Show the overlay above [bubbleKey]. Returns a future that completes once
  /// the overlay has been removed.
  static Future<void> show({
    required BuildContext context,
    required Event event,
    required ChatController controller,
    required GlobalKey bubbleKey,
    required Widget bubbleContent,
    required bool ownMessage,
  }) async {
    final renderBox =
        bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final rect = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);

    HapticFeedback.mediumImpact();

    final completer = Completer<void>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => MessageContextOverlay(
        event: event,
        controller: controller,
        bubbleRect: rect,
        bubbleContent: bubbleContent,
        ownMessage: ownMessage,
        onDismiss: () {
          if (entry.mounted) entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return completer.future;
  }

  @override
  State<MessageContextOverlay> createState() => _MessageContextOverlayState();
}

class _MessageContextOverlayState extends State<MessageContextOverlay>
    with TickerProviderStateMixin {
  static const _bubbleLift = 64.0;
  static const _bubbleScale = 1.04;
  static const _quickReactHeight = 56.0;
  static const _gap = 8.0;

  late final AnimationController _entryController;
  late final AnimationController _reactionsController;
  late final AnimationController _actionsController;

  late final Animation<double> _bubbleProgress;
  late final Animation<double> _reactionsScale;
  late final Animation<double> _reactionsOpacity;
  late final Animation<double> _actionsSlide;
  late final Animation<double> _actionsOpacity;
  late final Animation<double> _backdropOpacity;

  bool _dismissing = false;

  static const _quickEmojis = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

  @override
  void initState() {
    super.initState();

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _reactionsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _actionsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 200),
    );

    _bubbleProgress = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _backdropOpacity = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _reactionsScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(
        parent: _reactionsController,
        curve: Curves.elasticOut,
        reverseCurve: Curves.easeIn,
      ),
    );
    _reactionsOpacity = CurvedAnimation(
      parent: _reactionsController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _actionsSlide = Tween<double>(begin: 24.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _actionsController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    _actionsOpacity = CurvedAnimation(
      parent: _actionsController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _entryController.forward();
    Future.delayed(const Duration(milliseconds: 60), () {
      if (mounted) _reactionsController.forward();
    });
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) _actionsController.forward();
    });
  }

  @override
  void dispose() {
    _entryController.dispose();
    _reactionsController.dispose();
    _actionsController.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _reactionsController.reverse();
    _actionsController.reverse();
    await _entryController.reverse();
    if (!mounted) return;
    widget.onDismiss();
  }

  /// Helper: temporarily put the event in [ChatController.selectedEvents], run
  /// the action, then dismiss. Many ChatController action methods read from
  /// `selectedEvents` rather than taking the event as parameter — we adapt.
  void _withSelectedEvent(void Function() action) {
    widget.controller.selectedEvents
      ..clear()
      ..add(widget.event);
    action();
  }

  Future<void> _withSelectedEventAsync(Future<void> Function() action) async {
    widget.controller.selectedEvents
      ..clear()
      ..add(widget.event);
    await action();
  }

  void _onReply() {
    HapticFeedback.lightImpact();
    widget.controller.replyAction(replyTo: widget.event);
    _dismiss();
  }

  void _onEdit() {
    HapticFeedback.lightImpact();
    _withSelectedEvent(widget.controller.editSelectedEventAction);
    _dismiss();
  }

  void _onCopy() {
    HapticFeedback.lightImpact();
    _withSelectedEvent(widget.controller.copyEventsAction);
    final ctx = widget.controller.context;
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(L10n.of(ctx).copiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    _dismiss();
  }

  void _onForward() {
    HapticFeedback.lightImpact();
    _withSelectedEventAsync(widget.controller.forwardEventsAction);
    _dismiss();
  }

  void _onPin() {
    HapticFeedback.lightImpact();
    _withSelectedEvent(widget.controller.pinEvent);
    _dismiss();
  }

  void _onSave() {
    HapticFeedback.lightImpact();
    widget.controller.selectedEvents
      ..clear()
      ..add(widget.event);
    widget.controller.saveSelectedEvent(widget.controller.context);
    _dismiss();
  }

  void _onInfo() {
    HapticFeedback.lightImpact();
    widget.controller.showEventInfo(widget.event);
    _dismiss();
  }

  void _onDelete() {
    HapticFeedback.lightImpact();
    _withSelectedEventAsync(widget.controller.redactEventsAction);
    _dismiss();
  }

  void _onReport() {
    HapticFeedback.lightImpact();
    _withSelectedEventAsync(widget.controller.reportEventAction);
    _dismiss();
  }

  Future<void> _onPickEmoji() async {
    HapticFeedback.lightImpact();
    final outerContext = widget.controller.context;
    final theme = Theme.of(outerContext);
    if (!outerContext.mounted) return;
    final emoji = await showModalBottomSheet<String>(
      context: outerContext,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: EmojiPicker(
          onEmojiSelected: (_, e) => Navigator.of(ctx).pop(e.emoji),
          config: Config(
            locale: Localizations.localeOf(ctx),
            emojiViewConfig: const EmojiViewConfig(
              backgroundColor: Colors.transparent,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            categoryViewConfig: CategoryViewConfig(
              initCategory: Category.SMILEYS,
              backspaceColor: theme.colorScheme.primary,
              iconColor: theme.colorScheme.primary.withAlpha(128),
              iconColorSelected: theme.colorScheme.primary,
              indicatorColor: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surface,
            ),
          ),
        ),
      ),
    );
    if (emoji != null) {
      // ignore: unawaited_futures
      widget.event.room.sendReaction(widget.event.eventId, emoji);
    }
    _dismiss();
  }

  void _onQuickReact(String emoji) {
    HapticFeedback.lightImpact();
    // ignore: unawaited_futures
    widget.event.room.sendReaction(widget.event.eventId, emoji);
    _dismiss();
  }

  bool get _canEdit {
    final client = widget.event.room.client;
    return widget.event.senderId == client.userID &&
        widget.event.messageType == MessageTypes.Text &&
        widget.event.status.isSent;
  }

  bool get _canSave => {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(widget.event.messageType);

  bool get _canDelete => widget.event.canRedact ||
      widget.event.senderId == widget.event.room.client.userID;

  bool get _canPin =>
      widget.event.room.canChangeStateEvent(EventTypes.RoomPinnedEvents) &&
      widget.event.status.isSent;

  bool get _canReact => widget.event.room.canSendDefaultMessages;

  bool get _isOwn =>
      widget.event.senderId == widget.event.room.client.userID;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;

    // Resolve target position for the lifted bubble.
    // We anchor it relative to the available space so reactions row + actions
    // card fit on screen. If the bubble + reactions can't fit at the top,
    // we slide the bubble downward instead of upward.
    final actionsCardEstimatedHeight = _estimateActionsHeight();
    final topSafe = media.padding.top + 8;
    final bottomSafe = media.padding.bottom + 8;

    // Desired final bubble top after lift (above its origin).
    var finalBubbleTop = widget.bubbleRect.top - _bubbleLift;

    // Must keep room above the bubble for reactions row + gap.
    final minBubbleTop = topSafe + _quickReactHeight + _gap;
    if (finalBubbleTop < minBubbleTop) {
      finalBubbleTop = minBubbleTop;
    }

    // Must keep room below the bubble for actions card + gap.
    final maxBubbleTop = screen.height -
        bottomSafe -
        actionsCardEstimatedHeight -
        _gap -
        widget.bubbleRect.height;
    if (finalBubbleTop > maxBubbleTop) {
      finalBubbleTop = maxBubbleTop;
    }
    // If both constraints conflict (very short screen), respect the top.
    if (finalBubbleTop < minBubbleTop) finalBubbleTop = minBubbleTop;

    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation:
            Listenable.merge([_entryController, _reactionsController, _actionsController]),
        builder: (context, _) {
          final t = _bubbleProgress.value;
          final bubbleTop =
              lerpDouble(widget.bubbleRect.top, finalBubbleTop, t)!;
          final bubbleScale = lerpDouble(1.0, _bubbleScale, t)!;
          final shadowOpacity = t * 0.30;

          final reactionsTop =
              bubbleTop - _quickReactHeight - _gap;
          const reactionsHeight = _quickReactHeight;

          final actionsTop = bubbleTop + widget.bubbleRect.height + _gap;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Backdrop blur + dim. Tap-outside + swipe-down dismiss.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _dismiss,
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 200) {
                      _dismiss();
                    }
                  },
                  child: Opacity(
                    opacity: _backdropOpacity.value,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.18),
                      ),
                    ),
                  ),
                ),
              ),

              // Lifted bubble (clone of the pressed bubble).
              Positioned(
                left: widget.bubbleRect.left,
                top: bubbleTop,
                width: widget.bubbleRect.width,
                height: widget.bubbleRect.height,
                child: IgnorePointer(
                  child: Transform.scale(
                    scale: bubbleScale,
                    alignment: widget.ownMessage
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: shadowOpacity),
                            blurRadius: 32,
                            offset: const Offset(0, 12),
                            spreadRadius: -4,
                          ),
                        ],
                      ),
                      child: widget.bubbleContent,
                    ),
                  ),
                ),
              ),

              // Quick reactions row.
              if (_canReact)
                Positioned(
                  left: 8,
                  right: 8,
                  top: reactionsTop,
                  height: reactionsHeight,
                  child: Align(
                    alignment: widget.ownMessage
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Opacity(
                      opacity: _reactionsOpacity.value,
                      child: Transform.scale(
                        scale: _reactionsScale.value,
                        alignment: widget.ownMessage
                            ? Alignment.bottomRight
                            : Alignment.bottomLeft,
                        child: _QuickReactionsBar(
                          emojis: _quickEmojis,
                          onTap: _onQuickReact,
                          onPlus: _onPickEmoji,
                        ),
                      ),
                    ),
                  ),
                ),

              // Actions card.
              Positioned(
                left: 16,
                right: 16,
                top: actionsTop + _actionsSlide.value,
                child: Opacity(
                  opacity: _actionsOpacity.value,
                  child: Align(
                    alignment: widget.ownMessage
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: _ActionsCard(
                        theme: theme,
                        children: _buildActions(context),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _estimateActionsHeight() {
    var count = 0;
    if (_canReact) count++; // React
    count++; // Reply
    if (_canEdit) count++;
    count++; // Copy
    count++; // Forward
    if (_canPin) count++;
    if (_canSave) count++;
    count++; // Info
    if (_canDelete) count++;
    if (!_isOwn) count++; // Report
    // Each tile ~48dp + 8 top/bottom padding.
    return count * 48.0 + 16.0;
  }

  List<Widget> _buildActions(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final tiles = <Widget>[];

    tiles.add(_ActionTile(
      icon: Icons.reply_outlined,
      label: l10n.reply,
      onTap: _onReply,
      theme: theme,
    ));

    if (_canEdit) {
      tiles.add(_ActionTile(
        icon: Icons.edit_outlined,
        label: l10n.edit,
        onTap: _onEdit,
        theme: theme,
      ));
    }

    tiles.add(_ActionTile(
      icon: Icons.copy_outlined,
      label: l10n.copy,
      onTap: _onCopy,
      theme: theme,
    ));

    tiles.add(_ActionTile(
      icon: Icons.forward_outlined,
      label: l10n.forward,
      onTap: _onForward,
      theme: theme,
    ));

    if (_canPin) {
      tiles.add(_ActionTile(
        icon: Icons.push_pin_outlined,
        label: l10n.pin,
        onTap: _onPin,
        theme: theme,
      ));
    }

    if (_canSave) {
      tiles.add(_ActionTile(
        icon: Icons.download_outlined,
        label: l10n.saveFile,
        onTap: _onSave,
        theme: theme,
      ));
    }

    tiles.add(_ActionTile(
      icon: Icons.info_outline,
      label: l10n.messageInfo,
      onTap: _onInfo,
      theme: theme,
    ));

    if (_canDelete) {
      tiles.add(_ActionTile(
        icon: Icons.delete_outlined,
        label: l10n.delete,
        onTap: _onDelete,
        theme: theme,
        destructive: true,
      ));
    }

    if (!_isOwn) {
      tiles.add(_ActionTile(
        icon: Icons.flag_outlined,
        label: l10n.reportMessage,
        onTap: _onReport,
        theme: theme,
        destructive: true,
      ));
    }

    return tiles;
  }
}

class _QuickReactionsBar extends StatelessWidget {
  final List<String> emojis;
  final void Function(String) onTap;
  final VoidCallback onPlus;

  const _QuickReactionsBar({
    required this.emojis,
    required this.onTap,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                offset: const Offset(0, 8),
                blurRadius: 24,
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final emoji in emojis)
                _QuickEmojiTap(
                  emoji: emoji,
                  onTap: () => onTap(emoji),
                ),
              _QuickEmojiTap(
                emoji: null,
                icon: Icons.add,
                onTap: onPlus,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickEmojiTap extends StatelessWidget {
  final String? emoji;
  final IconData? icon;
  final VoidCallback onTap;

  const _QuickEmojiTap({
    required this.emoji,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: emoji != null
              ? Text(emoji!, style: const TextStyle(fontSize: 24))
              : Icon(
                  icon,
                  size: 22,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  final ThemeData theme;
  final List<Widget> children;

  const _ActionsCard({required this.theme, required this.children});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                offset: const Offset(0, 12),
                blurRadius: 32,
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final ThemeData theme;
  final bool destructive;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        destructive ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
