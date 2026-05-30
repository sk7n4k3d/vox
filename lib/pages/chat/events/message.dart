import 'dart:ui' as ui;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/author_color.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/member_actions_popup_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../../config/app_config.dart';
import 'message_content.dart';
import 'message_context_overlay.dart';
import 'message_quick_react_picker.dart';
import 'message_reactions.dart';
import 'reply_content.dart';
import 'state_message.dart';
import 'swipe_to_reply.dart';

class Message extends StatelessWidget {
  final Event event;
  final Event? nextEvent;
  final Event? previousEvent;
  final bool displayReadMarker;
  final void Function(Event) onSelect;
  final void Function(Event) onInfoTab;
  final void Function(String) scrollToEventId;
  final void Function() onSwipe;
  final void Function() onMention;
  final void Function() onEdit;
  final void Function(String eventId)? enterThread;
  final bool longPressSelect;
  final bool selected;
  final bool singleSelected;
  final Timeline timeline;
  final bool highlightMarker;
  final bool animateIn;
  final bool wallpaperMode;
  final ScrollController scrollController;
  final List<Color> colors;
  final void Function()? onExpand;
  final bool isCollapsed;
  final Set<String> bigEmojis;
  final ChatController? controller;

  const Message(
    this.event, {
    this.nextEvent,
    this.previousEvent,
    this.displayReadMarker = false,
    this.longPressSelect = false,
    required this.bigEmojis,
    required this.onSelect,
    required this.onInfoTab,
    required this.scrollToEventId,
    required this.onSwipe,
    this.selected = false,
    required this.onEdit,
    required this.singleSelected,
    required this.timeline,
    this.highlightMarker = false,
    this.animateIn = false,
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    required this.colors,
    this.onExpand,
    required this.enterThread,
    this.isCollapsed = false,
    this.controller,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();

    if (!{
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.Encrypted,
      EventTypes.CallInvite,
      PollEventContent.startType,
    }.contains(event.type)) {
      if (event.type.startsWith('m.call.')) {
        return const SizedBox.shrink();
      }
      return StateMessage(event, onExpand: onExpand, isCollapsed: isCollapsed);
    }

    if (event.type == EventTypes.Message &&
        event.messageType == EventTypes.KeyVerificationRequest) {
      return StateMessage(event);
    }

    final client = Matrix.of(context).client;
    final ownMessage = event.senderId == client.userID;
    final alignment = ownMessage ? Alignment.topRight : Alignment.topLeft;

    var color = theme.colorScheme.surfaceContainerHigh;
    final displayTime =
        event.type == EventTypes.RoomCreate ||
        nextEvent == null ||
        !event.originServerTs.sameEnvironment(nextEvent!.originServerTs);
    final nextEventSameSender =
        nextEvent != null &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
        }.contains(nextEvent!.type) &&
        nextEvent!.senderId == event.senderId &&
        !displayTime;

    final previousEventSameSender =
        previousEvent != null &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
        }.contains(previousEvent!.type) &&
        previousEvent!.senderId == event.senderId &&
        previousEvent!.originServerTs.sameEnvironment(event.originServerTs);

    final textColor = ownMessage
        ? theme.onBubbleColor
        : theme.colorScheme.onSurface;

    final linkColor = ownMessage
        ? theme.brightness == Brightness.light
              ? theme.colorScheme.primaryFixed
              : theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.primary;

    final rowMainAxisAlignment = ownMessage
        ? MainAxisAlignment.end
        : MainAxisAlignment.start;

    final displayEvent = event.getDisplayEvent(timeline);
    const hardCorner = Radius.circular(4);
    const roundedCorner = Radius.circular(AppConfig.borderRadius);
    final borderRadius = BorderRadius.only(
      topLeft: !ownMessage && nextEventSameSender ? hardCorner : roundedCorner,
      topRight: ownMessage && nextEventSameSender ? hardCorner : roundedCorner,
      bottomLeft: !ownMessage && previousEventSameSender
          ? hardCorner
          : roundedCorner,
      bottomRight: ownMessage && previousEventSameSender
          ? hardCorner
          : roundedCorner,
    );
    final noBubble =
        ({
          MessageTypes.Video,
          MessageTypes.Image,
          MessageTypes.Sticker,
        }.contains(event.messageType) &&
        event.fileDescription == null &&
        !event.redacted);

    if (ownMessage) {
      color = displayEvent.status.isError
          ? Colors.redAccent
          : theme.bubbleColor;
    }

    final sentReactions = <String>{};
    if (singleSelected) {
      sentReactions.addAll(
        event
            .aggregatedEvents(timeline, RelationshipTypes.reaction)
            .where(
              (event) =>
                  event.senderId == event.room.client.userID &&
                  event.type == 'm.reaction',
            )
            .map(
              (event) => event.content
                  .tryGetMap<String, Object?>('m.relates_to')
                  ?.tryGet<String>('key'),
            )
            .whereType<String>(),
      );
    }

    final hasReactions = event.hasAggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    );

    final threadChildren = event.aggregatedEvents(
      timeline,
      RelationshipTypes.thread,
    );

    final showReactionPicker =
        singleSelected && event.room.canSendDefaultMessages;

    final enterThread = this.enterThread;
    final sender = event.senderFromMemoryOrFallback;
    final bubbleKey = GlobalKey();

    void showQuickReactPicker() {
      if (!event.room.canSendDefaultMessages) return;
      final ctx = bubbleKey.currentContext;
      if (ctx == null) return;
      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.attached) return;
      final offset = renderBox.localToGlobal(Offset.zero);
      final rect = offset & renderBox.size;
      HapticFeedback.mediumImpact();
      MessageQuickReactPicker.show(
        context: ctx,
        event: event,
        bubbleRect: rect,
      );
    }

    /// Build the bubble visual once so we can reuse it inline (with the
    /// GlobalKey, for hit-testing + position resolution) and pass a clone
    /// (without the key) to [MessageContextOverlay] as the lifted hero.
    ///
    /// Sprint 2 V3 — own bubbles wear a saturated cyan→magenta diagonal
    /// gradient with a soft cyan glow ; inbound bubbles get a subtle violet
    /// 0.5px border. Media bubbles ([noBubble]) keep their original empty
    /// container — only the wrapper changes.
    Widget buildBubbleVisual({Key? key}) {
      // Gradient + glow only when there's an actual surface to color.
      final useOwnGradient =
          ownMessage && !noBubble && !displayEvent.status.isError &&
              cyber != null && !MediaQuery.highContrastOf(context);

      final BoxDecoration decoration;
      if (noBubble) {
        decoration = BoxDecoration(
          color: Colors.transparent,
          borderRadius: borderRadius,
        );
      } else if (useOwnGradient) {
        final c = cyber;
        decoration = BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              c.cyan.withValues(alpha: 0.35),
              c.magenta.withValues(alpha: 0.30),
            ],
          ),
          borderRadius: borderRadius,
          border: Border.all(
            color: c.cyan.withValues(alpha: 0.45),
            width: 0.75,
          ),
          boxShadow: [
            BoxShadow(
              color: c.cyan.withValues(alpha: 0.18),
              blurRadius: 14,
              spreadRadius: -2,
            ),
          ],
        );
      } else {
        decoration = BoxDecoration(
          color: color,
          borderRadius: borderRadius,
          border: !ownMessage && cyber != null
              ? Border.all(
                  color: cyber.violet.withValues(alpha: 0.45),
                  width: 0.5,
                )
              : null,
        );
      }

      return Container(
        key: key,
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: BubbleBackground(
          colors: colors,
          // Skip the legacy parallax gradient when our V3 gradient already
          // covers the surface.
          ignore: noBubble || useOwnGradient || !ownMessage ||
              MediaQuery.highContrastOf(context),
          scrollController: scrollController,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
            ),
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.columnWidth * 1.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (event.inReplyToEventId(includingFallback: false) != null)
                  FutureBuilder<Event?>(
                    future: event.getReplyEvent(timeline),
                    builder: (BuildContext context, snapshot) {
                      final replyEvent = snapshot.hasData
                          ? snapshot.data!
                          : Event(
                              eventId: event.inReplyToEventId() ??
                                  '\$fake_event_id',
                              content: const {
                                'msgtype': 'm.text',
                                'body': '...',
                              },
                              senderId: event.senderId,
                              type: 'm.room.message',
                              room: event.room,
                              status: EventStatus.sent,
                              originServerTs: DateTime.now(),
                            );
                      return Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top: 8,
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: ReplyContent.borderRadius,
                          child: InkWell(
                            borderRadius: ReplyContent.borderRadius,
                            onTap: () => scrollToEventId(replyEvent.eventId),
                            child: AbsorbPointer(
                              child: ReplyContent(
                                replyEvent,
                                ownMessage: ownMessage,
                                timeline: timeline,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                MessageContent(
                  displayEvent,
                  textColor: textColor,
                  linkColor: linkColor,
                  onInfoTab: onInfoTab,
                  borderRadius: borderRadius,
                  timeline: timeline,
                  selected: selected,
                  bigEmojis: bigEmojis,
                ),
                if (event.hasAggregatedEvents(timeline, RelationshipTypes.edit))
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: 8.0,
                      left: 16.0,
                      right: 16.0,
                    ),
                    child: _EditedPill(
                      time: displayEvent.originServerTs
                          .localizedTimeShort(context),
                      accent: cyber?.violet ?? textColor.withAlpha(164),
                      textColor: textColor.withAlpha(164),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    void showContextOverlay() {
      final ctrl = controller;
      if (ctrl == null) {
        // Fallback: legacy selection mode if controller wasn't wired in.
        HapticFeedback.heavyImpact();
        onSelect(event);
        return;
      }
      if (event.redacted) return;
      // ignore: unawaited_futures
      MessageContextOverlay.show(
        context: context,
        event: event,
        controller: ctrl,
        bubbleKey: bubbleKey,
        bubbleContent: buildBubbleVisual(),
        ownMessage: ownMessage,
      );
    }

    return _AnimateIn(
      animateIn: animateIn,
      child: Center(
        child: SwipeToReply(
          key: ValueKey(event.eventId),
          reverse: AppSettings.swipeRightToLeftToReply.value,
          onReply: onSwipe,
          child: Container(
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.maxTimelineWidth,
            ),
            padding: EdgeInsets.only(
              left: 8.0,
              right: 8.0,
              top: nextEventSameSender ? 1.0 : 4.0,
              bottom: previousEventSameSender ? 1.0 : 4.0,
            ),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: ownMessage ? .end : .start,
              children: <Widget>[
                if (displayTime || selected)
                  Padding(
                    padding: displayTime
                        ? const EdgeInsets.symmetric(vertical: 8.0)
                        : EdgeInsets.zero,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Material(
                          borderRadius: BorderRadius.circular(
                            AppConfig.borderRadius * 2,
                          ),
                          color: theme.colorScheme.surface.withAlpha(128),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                              vertical: 2.0,
                            ),
                            child: Text(
                              event.originServerTs.localizedTime(context),
                              style: TextStyle(
                                fontSize: 12 * AppSettings.fontSizeFactor.value,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: InkWell(
                        hoverColor: longPressSelect ? Colors.transparent : null,
                        enableFeedback: !selected,
                        onTap: longPressSelect ? null : () => onSelect(event),
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius / 2,
                        ),
                        child: Material(
                          borderRadius: BorderRadius.circular(
                            AppConfig.borderRadius / 2,
                          ),
                          color: selected || highlightMarker
                              ? theme.colorScheme.secondaryContainer.withAlpha(
                                  128,
                                )
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: .start,
                      mainAxisAlignment: rowMainAxisAlignment,
                      children: [
                        if (longPressSelect && !event.redacted)
                          SizedBox(
                            height: 32,
                            width: Avatar.defaultSize,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              tooltip: L10n.of(context).select,
                              icon: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                              ),
                              onPressed: () => onSelect(event),
                            ),
                          ),
                        // Inbound messages: drop the legacy left-aligned big
                        // avatar — the avatar now lives inline with the sender
                        // name (see "Header" below in the Column). The bubble
                        // takes the full row width for better readability.
                        Expanded(
                          child: Column(
                            crossAxisAlignment: .start,
                            mainAxisSize: .min,
                            children: [
                              if (!nextEventSameSender)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 0.0,
                                    bottom: 6,
                                  ),
                                  child: ownMessage
                                      ? const SizedBox(height: 12)
                                      // Sprint 2 audit finding-008: single
                                      // FutureBuilder feeds both avatar +
                                      // sender-name children. Previously
                                      // fetchSenderUser() was called twice
                                      // per row → -50% network hits on dense
                                      // rooms.
                                      : FutureBuilder<User?>(
                                          future: event.fetchSenderUser(),
                                          builder: (context, senderSnapshot) {
                                            final user =
                                                senderSnapshot.data ?? sender;
                                            return Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                // Avatar inline with the
                                                // sender name. Tap opens the
                                                // legacy member sheet.
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    right: 10.0,
                                                  ),
                                                  child: Avatar(
                                                    mxContent: user.avatarUrl,
                                                    name: user
                                                        .calcDisplayname(),
                                                    size: 36,
                                                    onTap: () =>
                                                        showMemberActionsPopupMenu(
                                                      context: context,
                                                      user: user,
                                                      onMention: onMention,
                                                    ),
                                                    presenceUserId:
                                                        user.stateKey,
                                                    presenceBackgroundColor:
                                                        wallpaperMode
                                                            ? Colors
                                                                .transparent
                                                            : null,
                                                  ),
                                                ),
                                            if (sender.powerLevel >= 50)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 2.0,
                                                ),
                                                child: Icon(
                                                  sender.powerLevel >= 100
                                                      ? Icons
                                                            .admin_panel_settings
                                                      : Icons
                                                            .add_moderator_outlined,
                                                  size: 14,
                                                  color: theme
                                                      .colorScheme
                                                      .onPrimaryContainer,
                                                ),
                                              ),
                                            Expanded(
                                              child: Builder(
                                                builder: (context) {
                                                  final displayname =
                                                      user.calcDisplayname();
                                                  final highContrast =
                                                      MediaQuery.highContrastOf(
                                                        context,
                                                      );
                                                  final Color nameColor;
                                                  if (highContrast) {
                                                    nameColor = theme
                                                        .colorScheme
                                                        .onSurface;
                                                  } else if (!AppSettings
                                                      .colorfulSenderNames
                                                      .value) {
                                                    nameColor = theme
                                                        .colorScheme
                                                        .primary;
                                                  } else {
                                                    nameColor =
                                                        AuthorColors.forUserId(
                                                          event.senderId,
                                                          theme.brightness,
                                                        );
                                                  }
                                                  return Text(
                                                    displayname,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: nameColor,
                                                      shadows: !wallpaperMode
                                                          ? null
                                                          : [
                                                              const Shadow(
                                                                offset: Offset(
                                                                  0.0,
                                                                  0.0,
                                                                ),
                                                                blurRadius: 3,
                                                                color: Colors
                                                                    .black,
                                                              ),
                                                            ],
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                            );
                                          },
                                        ),
                                ),
                              Container(
                                alignment: alignment,
                                padding: EdgeInsets.only(
                                  // Bubble extends to the row start for
                                  // incoming messages (avatar is in the
                                  // header above) so it has more room to
                                  // breathe and reads on its own line.
                                  left: ownMessage ? 8.0 : 0.0,
                                ),
                                child: GestureDetector(
                                  onLongPress: longPressSelect
                                      ? null
                                      : showContextOverlay,
                                  onDoubleTap: longPressSelect
                                      ? null
                                      : showQuickReactPicker,
                                  child: buildBubbleVisual(key: bubbleKey),
                                ),
                              ),
                              Align(
                                alignment: ownMessage
                                    ? Alignment.bottomRight
                                    : Alignment.bottomLeft,
                                child: AnimatedSize(
                                  duration: FluffyThemes.animationDuration,
                                  curve: FluffyThemes.animationCurve,
                                  child: showReactionPicker
                                      ? Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Material(
                                            elevation: 4,
                                            borderRadius: BorderRadius.circular(
                                              AppConfig.borderRadius,
                                            ),
                                            shadowColor: theme
                                                .colorScheme
                                                .surface
                                                .withAlpha(128),
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Row(
                                                mainAxisSize: .min,
                                                children: [
                                                  ...AppConfig.defaultReactions.map(
                                                    (emoji) => IconButton(
                                                      padding: EdgeInsets.zero,
                                                      icon: Center(
                                                        child: Opacity(
                                                          opacity:
                                                              sentReactions
                                                                  .contains(
                                                                    emoji,
                                                                  )
                                                              ? 0.33
                                                              : 1,
                                                          child: Text(
                                                            emoji,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 20,
                                                                ),
                                                            textAlign: TextAlign
                                                                .center,
                                                          ),
                                                        ),
                                                      ),
                                                      onPressed:
                                                          sentReactions
                                                              .contains(emoji)
                                                          ? null
                                                          : () {
                                                              onSelect(event);
                                                              event.room
                                                                  .sendReaction(
                                                                    event
                                                                        .eventId,
                                                                    emoji,
                                                                  );
                                                            },
                                                    ),
                                                  ),
                                                  IconButton(
                                                    icon: const Icon(
                                                      Icons
                                                          .add_reaction_outlined,
                                                    ),
                                                    tooltip: L10n.of(
                                                      context,
                                                    ).customReaction,
                                                    onPressed: () async {
                                                      final emoji = await showAdaptiveBottomSheet<String>(
                                                        context: context,
                                                        builder: (context) => Scaffold(
                                                          appBar: AppBar(
                                                            title: Text(
                                                              L10n.of(
                                                                context,
                                                              ).customReaction,
                                                            ),
                                                            leading: CloseButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(null),
                                                            ),
                                                          ),
                                                          body: SizedBox(
                                                            height:
                                                                double.infinity,
                                                            child: EmojiPicker(
                                                              onEmojiSelected:
                                                                  (_, emoji) =>
                                                                      Navigator.of(
                                                                        context,
                                                                      ).pop(
                                                                        emoji
                                                                            .emoji,
                                                                      ),
                                                              config: Config(
                                                                locale:
                                                                    Localizations.localeOf(
                                                                      context,
                                                                    ),
                                                                emojiViewConfig:
                                                                    const EmojiViewConfig(
                                                                      backgroundColor:
                                                                          Colors
                                                                              .transparent,
                                                                    ),
                                                                bottomActionBarConfig:
                                                                    const BottomActionBarConfig(
                                                                      enabled:
                                                                          false,
                                                                    ),
                                                                categoryViewConfig: CategoryViewConfig(
                                                                  initCategory:
                                                                      Category
                                                                          .SMILEYS,
                                                                  backspaceColor: theme
                                                                      .colorScheme
                                                                      .primary,
                                                                  iconColor: theme
                                                                      .colorScheme
                                                                      .primary
                                                                      .withAlpha(
                                                                        128,
                                                                      ),
                                                                  iconColorSelected: theme
                                                                      .colorScheme
                                                                      .primary,
                                                                  indicatorColor: theme
                                                                      .colorScheme
                                                                      .primary,
                                                                  backgroundColor: theme
                                                                      .colorScheme
                                                                      .surface,
                                                                ),
                                                                skinToneConfig: SkinToneConfig(
                                                                  dialogBackgroundColor: Color.lerp(
                                                                    theme
                                                                        .colorScheme
                                                                        .surface,
                                                                    theme
                                                                        .colorScheme
                                                                        .primaryContainer,
                                                                    0.75,
                                                                  )!,
                                                                  indicatorColor: theme
                                                                      .colorScheme
                                                                      .onSurface,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                      if (emoji == null) {
                                                        return;
                                                      }
                                                      if (sentReactions
                                                          .contains(emoji)) {
                                                        return;
                                                      }
                                                      onSelect(event);

                                                      await event.room
                                                          .sendReaction(
                                                            event.eventId,
                                                            emoji,
                                                          );
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Own messages: send-status indicator (spinner / error
                        // badge) sits at the END of the message — to the right
                        // of the bubble — instead of being stranded on the far
                        // left of the full-width row.
                        if (ownMessage && !longPressSelect)
                          Padding(
                            padding: const EdgeInsets.only(left: 4.0, top: 14.0),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: event.status == EventStatus.error
                                  ? _MessageErrorBadge(
                                      magenta: cyber?.magenta ??
                                          theme.colorScheme.error,
                                    )
                                  : event.fileSendingStatus != null
                                  ? CircularProgressIndicator.adaptive(
                                      strokeWidth: 1.5,
                                      valueColor: AlwaysStoppedAnimation(
                                        cyber?.cyan ??
                                            theme.colorScheme.primary,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),

                AnimatedSize(
                  duration: FluffyThemes.animationDuration,
                  curve: FluffyThemes.animationCurve,
                  alignment: Alignment.bottomCenter,
                  child: !hasReactions
                      ? const SizedBox.shrink()
                      : Padding(
                          // La refonte full-width a déplacé l'avatar inbound
                          // dans le header au-dessus de la bulle (bulle à
                          // left:0). On retire donc l'ancien offset
                          // Avatar.defaultSize : les réactions s'alignent
                          // désormais sous la bulle, pas décalées de ~56px.
                          padding: const EdgeInsets.only(
                            top: 1.0,
                            left: 12.0,
                            right: 12.0,
                          ),
                          child: MessageReactions(event, timeline),
                        ),
                ),
                if (enterThread != null)
                  AnimatedSize(
                    duration: FluffyThemes.animationDuration,
                    curve: FluffyThemes.animationCurve,
                    alignment: Alignment.bottomCenter,
                    child: threadChildren.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(
                              top: 2.0,
                              bottom: 8.0,
                              left: 12.0,
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: FluffyThemes.columnWidth * 1.5,
                              ),
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  foregroundColor:
                                      theme.colorScheme.onSecondaryContainer,
                                  backgroundColor:
                                      theme.colorScheme.secondaryContainer,
                                ),
                                onPressed: () => enterThread(event.eventId),
                                icon: const Icon(Icons.message),
                                label: Text(
                                  '${L10n.of(context).countReplies(threadChildren.length)} | ${threadChildren.first.calcLocalizedBodyFallback(MatrixLocals(L10n.of(context)), withSenderNamePrefix: true)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                  ),
                if (displayReadMarker)
                  Row(
                    children: [
                      Expanded(
                        child: Divider(
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 16.0,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            AppConfig.borderRadius / 3,
                          ),
                          color: theme.colorScheme.surface.withAlpha(128),
                        ),
                        child: Text(
                          L10n.of(context).readUpToHere,
                          style: TextStyle(
                            fontSize: 12 * AppSettings.fontSizeFactor.value,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Divider(
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BubbleBackground extends StatelessWidget {
  const BubbleBackground({
    super.key,
    required this.scrollController,
    required this.colors,
    required this.ignore,
    required this.child,
  });

  final ScrollController scrollController;
  final List<Color> colors;
  final bool ignore;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ignore) return child;
    return CustomPaint(
      painter: BubblePainter(
        repaint: scrollController,
        colors: colors,
        context: context,
      ),
      child: child,
    );
  }
}

class BubblePainter extends CustomPainter {
  BubblePainter({
    required this.context,
    required this.colors,
    required super.repaint,
  });

  final BuildContext context;
  final List<Color> colors;
  ScrollableState? _scrollable;

  @override
  void paint(Canvas canvas, Size size) {
    final scrollable = _scrollable ??= Scrollable.of(context);
    final scrollableBox = scrollable.context.findRenderObject() as RenderBox;
    final scrollableRect = Offset.zero & scrollableBox.size;
    final bubbleBox = context.findRenderObject() as RenderBox;

    final origin = bubbleBox.localToGlobal(
      Offset.zero,
      ancestor: scrollableBox,
    );
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        scrollableRect.topCenter,
        scrollableRect.bottomCenter,
        colors,
        [0.0, 1.0],
        TileMode.clamp,
        Matrix4.translationValues(-origin.dx, -origin.dy, 0.0).storage,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(BubblePainter oldDelegate) {
    final scrollable = Scrollable.of(context);
    final oldScrollable = _scrollable;
    _scrollable = scrollable;
    return scrollable.position != oldScrollable?.position;
  }
}

class _AnimateIn extends StatefulWidget {
  final bool animateIn;
  final Widget child;
  const _AnimateIn({required this.animateIn, required this.child});

  @override
  State<_AnimateIn> createState() => __AnimateInState();
}

class __AnimateInState extends State<_AnimateIn> {
  // Sprint 2 V3 — slide-up + fade animation, spring physics-like via
  // emphasized curve. 16dp depart en bas, monte en se révélant. Sensation
  // beaucoup plus premium que le simple fade.
  bool _animationFinished = false;
  @override
  Widget build(BuildContext context) {
    if (!widget.animateIn) return widget.child;
    if (!_animationFinished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _animationFinished = true);
        }
      });
    }
    return AnimatedSlide(
      duration: FluffyDurations.medium,
      curve: FluffyCurves.emphasized,
      offset: _animationFinished ? Offset.zero : const Offset(0, 0.25),
      child: AnimatedOpacity(
        duration: FluffyDurations.medium,
        curve: FluffyCurves.decelerated,
        opacity: _animationFinished ? 1 : 0,
        child: AnimatedSize(
          duration: FluffyDurations.medium,
          curve: FluffyCurves.emphasized,
          child: _animationFinished ? widget.child : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Sprint 2 V2 — edited pill : icon violet + texte mono, micro-pill
/// avec accent cyber. Remplace l'edit row inline historique.
class _EditedPill extends StatelessWidget {
  const _EditedPill({
    required this.time,
    required this.accent,
    required this.textColor,
  });

  final String time;
  final Color accent;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(
          color: accent.withValues(alpha: 0.30),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_outlined, color: accent, size: 11),
          const SizedBox(width: 4),
          Text(
            time,
            style: FluffyTypography.code.copyWith(
              color: textColor,
              fontSize: 10,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sprint 2 V2 — error badge cyber : ring magenta + glow + cross.
///
/// Remplace l'`Icon(Icons.error, color: Colors.red)` historique. Le glow est
/// statique (pas d'AnimationController) pour rester cheap dans une room
/// peuplée. Si on veut un pulse dans une future itération, wrap dans un
/// `RepaintBoundary` + `AnimationController` borné par `VisibilityDetector`.
class _MessageErrorBadge extends StatelessWidget {
  const _MessageErrorBadge({required this.magenta});

  final Color magenta;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: magenta, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: magenta.withValues(alpha: 0.45),
            blurRadius: 8,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Icon(Icons.close_rounded, color: magenta, size: 12),
    );
  }
}
