import 'dart:ui';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/animated_emoji_text.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

/// Maximum number of distinct reaction pills displayed before they are
/// collapsed under a "+N" overflow chip.
const int _kMaxVisibleReactions = 3;

/// Backdrop blur sigma for reaction pills (matches [CyberpunkTheme.blurSigmaChip]).
const double _kBlurChip = 8;

class MessageReactions extends StatelessWidget {
  final Event event;
  final Timeline timeline;

  const MessageReactions(this.event, this.timeline, {super.key});

  @override
  Widget build(BuildContext context) {
    final allReactionEvents = event.aggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    );
    final reactionMap = <String, _ReactionEntry>{};
    final client = Matrix.of(context).client;

    for (final e in allReactionEvents) {
      final key = e.content
          .tryGetMap<String, Object?>('m.relates_to')
          ?.tryGet<String>('key');
      if (key != null) {
        if (!reactionMap.containsKey(key)) {
          reactionMap[key] = _ReactionEntry(
            key: key,
            count: 0,
            reacted: false,
            reactors: [],
          );
        }
        reactionMap[key]!.count++;
        reactionMap[key]!.reactors!.add(e.senderFromMemoryOrFallback);
        reactionMap[key]!.reacted |= e.senderId == e.room.client.userID;
      }
    }

    final reactionList = reactionMap.values.toList();
    reactionList.sort((a, b) => b.count - a.count > 0 ? 1 : -1);
    final ownMessage = event.senderId == event.room.client.userID;

    final visible = reactionList.take(_kMaxVisibleReactions).toList();
    final hiddenCount = reactionList.length - visible.length;
    final isSending = allReactionEvents.any((e) => e.status.isSending);

    return Wrap(
      spacing: 4.0,
      runSpacing: 4.0,
      alignment: ownMessage ? WrapAlignment.end : WrapAlignment.start,
      children: [
        ...visible.map(
          (r) => _Reaction(
            reactionKey: r.key,
            count: r.count,
            reacted: r.reacted,
            onTap: () {
              HapticFeedback.lightImpact();
              if (r.reacted) {
                final evt = allReactionEvents.firstWhereOrNull(
                  (e) =>
                      e.senderId == e.room.client.userID &&
                      e.content.tryGetMap('m.relates_to')?['key'] == r.key,
                );
                if (evt != null) {
                  showFutureLoadingDialog(
                    context: context,
                    future: evt.redactEvent,
                  );
                }
              } else {
                event.room.sendReaction(event.eventId, r.key);
              }
            },
            onLongPress: () async => await _AdaptableReactorsDialog(
              client: client,
              reactionEntry: r,
            ).show(context),
          ),
        ),
        if (hiddenCount > 0)
          _OverflowChip(
            count: hiddenCount,
            onTap: () => _showAllReactionsSheet(
              context,
              reactionList,
              allReactionEvents,
            ),
          ),
        if (isSending)
          const SizedBox(
            width: 24,
            height: 24,
            child: Padding(
              padding: EdgeInsets.all(4.0),
              child: CircularProgressIndicator.adaptive(strokeWidth: 1),
            ),
          ),
      ],
    );
  }

  void _showAllReactionsSheet(
    BuildContext context,
    List<_ReactionEntry> all,
    Set<Event> allReactionEvents,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in all)
                  _Reaction(
                    reactionKey: r.key,
                    count: r.count,
                    reacted: r.reacted,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.of(sheetContext).pop();
                      if (r.reacted) {
                        final evt = allReactionEvents.firstWhereOrNull(
                          (e) =>
                              e.senderId == e.room.client.userID &&
                              e.content.tryGetMap('m.relates_to')?['key'] ==
                                  r.key,
                        );
                        if (evt != null) {
                          showFutureLoadingDialog(
                            context: context,
                            future: evt.redactEvent,
                          );
                        }
                      } else {
                        event.room.sendReaction(event.eventId, r.key);
                      }
                    },
                    onLongPress: null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Reaction extends StatefulWidget {
  final String reactionKey;
  final int count;
  final bool? reacted;
  final void Function()? onTap;
  final void Function()? onLongPress;

  const _Reaction({
    required this.reactionKey,
    required this.count,
    required this.reacted,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_Reaction> createState() => _ReactionState();
}

class _ReactionState extends State<_Reaction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _lastCount = widget.count;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _scale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    // Entry animation when the pill first appears.
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _Reaction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.count > _lastCount) {
      _controller.forward(from: 0);
    }
    _lastCount = widget.count;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reacted = widget.reacted == true;

    final bgColor = reacted
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final borderColor = reacted
        ? theme.colorScheme.primary.withValues(alpha: 0.5)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.3);
    final borderWidth = reacted ? 1.0 : 0.5;

    Widget content;
    if (widget.reactionKey.startsWith('mxc://')) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MxcImage(
            uri: Uri.parse(widget.reactionKey),
            width: 16,
            height: 16,
            animated: false,
            isThumbnail: false,
          ),
          if (widget.count > 1) ...[
            const SizedBox(width: 4),
            Text(
              widget.count.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      );
    } else {
      var renderKey = Characters(widget.reactionKey);
      if (renderKey.length > 10) {
        renderKey = renderKey.getRange(0, 9) + Characters('…');
      }
      // Réaction = un seul emoji animable → version animée Noto (taille 16,
      // repli texte intégré). Sinon rendu texte habituel (séquences, multi-char).
      final reactionText = renderKey.toString();
      final animated = AnimatedEmojiText.hasAnimatable(reactionText, maxEmojis: 1)
          ? AnimatedEmojiText(text: reactionText, size: 18)
          : Text(
              reactionText,
              style: const TextStyle(fontSize: 16),
            );
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          animated,
          if (widget.count > 1) ...[
            const SizedBox(width: 4),
            Text(
              widget.count.toString(),
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      );
    }

    return ScaleTransition(
      scale: _scale,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: _kBlurChip, sigmaY: _kBlurChip),
              child: Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border.all(
                    color: borderColor,
                    width: borderWidth,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OverflowChip extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _OverflowChip({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: _kBlurChip, sigmaY: _kBlurChip),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.3,
                  ),
                  width: 0.5,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              child: Text(
                '+$count',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionEntry {
  String key;
  int count;
  bool reacted;
  List<User>? reactors;

  _ReactionEntry({
    required this.key,
    required this.count,
    required this.reacted,
    this.reactors,
  });
}

class _AdaptableReactorsDialog extends StatelessWidget {
  final Client? client;
  final _ReactionEntry? reactionEntry;

  const _AdaptableReactorsDialog({this.client, this.reactionEntry});

  Future<bool?> show(BuildContext context) => showAdaptiveDialog(
    context: context,
    builder: (context) => this,
    barrierDismissible: true,
    useRootNavigator: false,
  );

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      child: Wrap(
        spacing: 8.0,
        runSpacing: 4.0,
        alignment: WrapAlignment.center,
        children: <Widget>[
          for (final reactor in reactionEntry!.reactors!)
            Chip(
              avatar: Avatar(
                mxContent: reactor.avatarUrl,
                name: reactor.displayName,
                client: client,
                presenceUserId: reactor.stateKey,
              ),
              label: Text(reactor.displayName!),
            ),
        ],
      ),
    );

    final title = Center(child: Text(reactionEntry!.key));

    return AlertDialog.adaptive(title: title, content: body);
  }
}
