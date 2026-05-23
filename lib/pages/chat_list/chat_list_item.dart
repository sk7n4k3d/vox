import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/room_status_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/avatar_with_status_ring.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/hover_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../../config/themes.dart';
import '../../utils/date_time_extension.dart';
import '../../widgets/avatar.dart';

class ChatListItem extends StatelessWidget {
  final Room room;
  final Room? space;
  final bool activeChat;
  final void Function(BuildContext context)? onLongPress;
  final void Function()? onForget;
  final void Function() onTap;
  final String? filter;

  const ChatListItem(
    this.room, {
    this.activeChat = false,
    required this.onTap,
    this.onLongPress,
    this.onForget,
    this.filter,
    this.space,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final isMuted = room.pushRuleState != PushRuleState.notify;
    final typingText = room.getLocalizedTypingText(context);
    final lastEvent = room.lastEvent;
    final ownMessage = lastEvent?.senderId == room.client.userID;
    final directChatMatrixId = room.directChatMatrixID;
    final isDirectChat = directChatMatrixId != null;
    final hasNotifications = room.notificationCount > 0;
    final backgroundColor = activeChat
        ? theme.colorScheme.secondaryContainer
        : null;
    final displayname = room.getLocalizedDisplayname(
      MatrixLocals(L10n.of(context)),
    );
    final filter = this.filter;
    if (filter != null && !displayname.toLowerCase().contains(filter)) {
      return const SizedBox.shrink();
    }

    final needLastEventSender =
        lastEvent != null &&
        room.getState(EventTypes.RoomMember, lastEvent.senderId) == null;
    final space = this.space;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        clipBehavior: Clip.hardEdge,
        color: backgroundColor,
        child: FutureBuilder(
          future: room.name.isEmpty ? room.loadHeroUsers() : null,
          builder: (context, _) => HoverBuilder(
            builder: (context, listTileHovered) => ListTile(
              visualDensity: const VisualDensity(vertical: -0.5),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              onLongPress: () => onLongPress?.call(context),
              leading: HoverBuilder(
                builder: (context, hovered) => AnimatedScale(
                  duration: FluffyThemes.animationDuration,
                  curve: FluffyThemes.animationCurve,
                  scale: hovered ? 1.1 : 1.0,
                  // Shared element transition: matches the Hero with the
                  // same tag in `chat_liquid_glass_app_bar.dart` so opening
                  // this room animates the avatar from its row position to
                  // the AppBar (M3 shared element motion).
                  child: Hero(
                    tag: 'avatar_${room.id}',
                    flightShuttleBuilder: (
                      flightContext,
                      animation,
                      direction,
                      fromContext,
                      toContext,
                    ) {
                      // Render the destination Hero's child during flight so
                      // the avatar lands cleanly at the AppBar size (40)
                      // from the list size (48). Flutter scales the rect
                      // automatically; we only need to pick which subtree
                      // wins the visual style for the in-flight frame.
                      final toHero = toContext.widget as Hero;
                      return toHero.child;
                    },
                    child: SizedBox(
                      width: Avatar.defaultSize,
                      height: Avatar.defaultSize,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (space != null)
                            Positioned(
                              top: 0,
                              left: 0,
                              child: Avatar(
                                shapeBorder: RoundedSuperellipseBorder(
                                  side: BorderSide(
                                    width: 2,
                                    color:
                                        backgroundColor ??
                                        theme.colorScheme.surface,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppConfig.spaceBorderRadius * 0.75,
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppConfig.spaceBorderRadius * 0.75,
                                ),
                                mxContent: space.avatar,
                                size: Avatar.defaultSize * 0.75,
                                name: space.getLocalizedDisplayname(),
                                onTap: () => onLongPress?.call(context),
                              ),
                            ),
                          // When this is the avatar of the room inside a
                          // space (space != null) we keep the legacy
                          // square-stacked Avatar to preserve the
                          // parent-space hint visual. Otherwise we wrap
                          // with the status ring.
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: space != null
                                ? Avatar(
                                    shapeBorder: RoundedRectangleBorder(
                                      side: BorderSide(
                                        width: 2,
                                        color:
                                            backgroundColor ??
                                            theme.colorScheme.surface,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        Avatar.defaultSize,
                                      ),
                                    ),
                                    mxContent: room.avatar,
                                    size: Avatar.defaultSize * 0.75,
                                    name: displayname,
                                    presenceUserId: directChatMatrixId,
                                    presenceBackgroundColor: backgroundColor,
                                    onTap: () => onLongPress?.call(context),
                                  )
                                : AvatarWithStatusRing(
                                    mxContent: room.avatar,
                                    name: displayname,
                                    // Inner avatar shrunk by 10px so the
                                    // ring (2px stroke + 3px gap on each
                                    // side) fits inside the parent SizedBox
                                    // without being clipped.
                                    size: Avatar.defaultSize - 10,
                                    presenceUserId: isDirectChat
                                        ? directChatMatrixId
                                        : null,
                                    encrypted: room.encrypted,
                                    isSpace: room.isSpace,
                                    // Sprint 2 V2 — pulse cyan sur unread,
                                    // glow magenta sur mention.
                                    unread: room.notificationCount > 0 ||
                                        room.markedUnread,
                                    mentioned: room.highlightCount > 0,
                                    shapeBorder: room.isSpace
                                        ? RoundedSuperellipseBorder(
                                            side: BorderSide(
                                              width: 1,
                                              color: theme.dividerColor,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(
                                              AppConfig.spaceBorderRadius,
                                            ),
                                          )
                                        : null,
                                    borderRadius: room.isSpace
                                        ? BorderRadius.circular(
                                            AppConfig.spaceBorderRadius,
                                          )
                                        : null,
                                    onTap: () => onLongPress?.call(context),
                                  ),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: GestureDetector(
                              onTap: () => onLongPress?.call(context),
                              child: AnimatedScale(
                                duration: FluffyThemes.animationDuration,
                                curve: FluffyThemes.animationCurve,
                                scale: listTileHovered ? 1.0 : 0.0,
                                child: Material(
                                  color: backgroundColor,
                                  borderRadius: BorderRadius.circular(16),
                                  child: const Icon(
                                    Icons.arrow_drop_down_circle_outlined,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              title: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      displayname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  if (isMuted)
                    const Padding(
                      padding: EdgeInsets.only(left: 4.0),
                      child: Icon(Icons.notifications_off_outlined, size: 16),
                    ),
                  if (room.isLowPriority)
                    Padding(
                      padding: EdgeInsets.only(
                        right: hasNotifications ? 4.0 : 0.0,
                      ),
                      child: Icon(
                        Icons.low_priority,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  if (room.isFavourite)
                    Padding(
                      padding: EdgeInsets.only(
                        right: hasNotifications ? 4.0 : 0.0,
                      ),
                      child: Icon(
                        Icons.push_pin,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  if (!room.isSpace && room.membership != Membership.invite)
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0),
                      child: Text(
                        room.latestEventReceivedTime.localizedTimeShort(
                          context,
                        ),
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
              subtitle: Row(
                crossAxisAlignment: .start,
                mainAxisAlignment: .center,
                children: <Widget>[
                  if (typingText.isEmpty &&
                      ownMessage &&
                      room.lastEvent?.status.isSending == true) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    ),
                    const SizedBox(width: 4),
                  ],
                  AnimatedSize(
                    clipBehavior: Clip.hardEdge,
                    duration: FluffyThemes.animationDuration,
                    curve: FluffyThemes.animationCurve,
                    child: typingText.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(right: 4.0),
                            child: Icon(
                              Icons.edit_outlined,
                              color: theme.colorScheme.secondary,
                              size: 16,
                            ),
                          )
                        : room.lastEvent?.relationshipType ==
                              RelationshipTypes.thread
                        ? Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outline,
                              ),
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            margin: const EdgeInsets.only(right: 4.0),
                            child: Row(
                              mainAxisSize: .min,
                              children: [
                                Icon(
                                  Icons.message_outlined,
                                  size: 12,
                                  color: theme.colorScheme.outline,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  L10n.of(context).thread,
                                  style: TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: room.isSpace && room.membership == Membership.join
                        ? Text(
                            L10n.of(
                              context,
                            ).countChats(room.spaceChildren.length),
                          )
                        : typingText.isNotEmpty
                        ? Text(
                            typingText,
                            style: TextStyle(color: theme.colorScheme.primary),
                            maxLines: 1,
                            softWrap: false,
                          )
                        : _buildPreview(
                            context: context,
                            theme: theme,
                            lastEvent: lastEvent,
                            ownMessage: ownMessage,
                            isDirectChat: isDirectChat,
                            directChatMatrixId: directChatMatrixId,
                            needLastEventSender: needLastEventSender,
                          ),
                  ),
                  const SizedBox(width: 8),
                  _HybridUnreadBadge(room: room),
                ],
              ),
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              trailing: onForget == null
                  ? room.membership == Membership.invite
                        ? IconButton(
                            tooltip: L10n.of(context).declineInvitation,
                            icon: const Icon(Icons.delete_forever_outlined),
                            color: theme.colorScheme.error,
                            onPressed: () async {
                              final consent = await showOkCancelAlertDialog(
                                context: context,
                                title: L10n.of(context).declineInvitation,
                                message: L10n.of(context).areYouSure,
                                okLabel: L10n.of(context).yes,
                                isDestructive: true,
                              );
                              if (consent != OkCancelResult.ok) return;
                              if (!context.mounted) return;
                              await showFutureLoadingDialog(
                                context: context,
                                future: room.leave,
                              );
                            },
                          )
                        : null
                  : IconButton(
                      icon: const Icon(Icons.delete_outlined),
                      onPressed: onForget,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview({
    required BuildContext context,
    required ThemeData theme,
    required Event? lastEvent,
    required bool ownMessage,
    required bool isDirectChat,
    required String? directChatMatrixId,
    required bool needLastEventSender,
  }) {
    // Invitations bypass the normal preview text entirely.
    if (room.membership == Membership.invite) {
      final reason = room
          .getState(EventTypes.RoomMember, room.client.userID!)
          ?.content
          .tryGet<String>('reason');
      final fallback = isDirectChat
          ? L10n.of(context).newChatRequest
          : L10n.of(context).inviteGroupChat;
      return Text(
        reason ?? fallback,
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    // Voice message preview — short-circuits body text, shows mic + duration.
    if (lastEvent != null &&
        !lastEvent.redacted &&
        lastEvent.type == EventTypes.Message &&
        lastEvent.messageType == MessageTypes.Audio) {
      return _voicePreview(context, theme, lastEvent, ownMessage);
    }

    // Image preview — minimal icon-prefixed marker.
    if (lastEvent != null &&
        !lastEvent.redacted &&
        lastEvent.type == EventTypes.Message &&
        lastEvent.messageType == MessageTypes.Image) {
      return _imagePreview(context, theme, lastEvent, ownMessage);
    }

    // Default text path with optional Tu:/reply prefix.
    final prefix = _previewPrefix(
      context: context,
      lastEvent: lastEvent,
      ownMessage: ownMessage,
      isDirectChat: isDirectChat,
      directChatMatrixId: directChatMatrixId,
    );
    // When we render our own prefix we don't want calcLocalizedBody to also
    // prepend a sender name — avoid double-tagging.
    final withSenderName = prefix == null &&
        (!isDirectChat || directChatMatrixId != lastEvent?.senderId);

    return FutureBuilder(
      key: ValueKey(
        '${lastEvent?.eventId}_${lastEvent?.type}_${lastEvent?.redacted}',
      ),
      future: needLastEventSender && lastEvent != null
          ? lastEvent.calcLocalizedBody(
              MatrixLocals(L10n.of(context)),
              hideReply: true,
              hideEdit: true,
              plaintextBody: true,
              removeMarkdown: true,
              withSenderNamePrefix: withSenderName,
            )
          : null,
      initialData: lastEvent?.calcLocalizedBodyFallback(
        MatrixLocals(L10n.of(context)),
        hideReply: true,
        hideEdit: true,
        plaintextBody: true,
        removeMarkdown: true,
        withSenderNamePrefix: withSenderName,
      ),
      builder: (context, snapshot) {
        final body = snapshot.data ?? L10n.of(context).noMessagesYet;
        final redacted = lastEvent?.redacted == true;
        final maxLines = room.notificationCount >= 1 ? 2 : 1;
        if (prefix == null || redacted) {
          return Text(
            body,
            softWrap: false,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              decoration: redacted ? TextDecoration.lineThrough : null,
            ),
          );
        }
        return RichText(
          softWrap: false,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(
                text: prefix,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              TextSpan(text: body),
            ],
          ),
        );
      },
    );
  }

  /// Returns the italic prefix string for the preview, or null if no prefix
  /// should be applied. Priority: reply > self.
  String? _previewPrefix({
    required BuildContext context,
    required Event? lastEvent,
    required bool ownMessage,
    required bool isDirectChat,
    required String? directChatMatrixId,
  }) {
    if (lastEvent == null) return null;
    // Detect reply via m.relates_to.m.in_reply_to (non-thread replies only).
    final inReplyTo = lastEvent.content
        .tryGetMap<String, Object?>('m.relates_to')
        ?.tryGetMap<String, Object?>('m.in_reply_to')
        ?.tryGet<String>('event_id');
    if (inReplyTo != null &&
        lastEvent.relationshipType != RelationshipTypes.thread) {
      // Sender name is not always cheaply resolvable here without async I/O,
      // so we render a compact arrow prefix. The body itself already gets
      // calcLocalizedBody with hideReply:true so we won't double-render the
      // quoted block.
      return '↳ ';
    }
    if (ownMessage && isDirectChat) {
      // "Tu:" only makes sense in 1:1 — in group chats sender prefix already
      // handles disambiguation via calcLocalizedBody.
      return 'Tu : ';
    }
    return null;
  }

  Widget _voicePreview(
    BuildContext context,
    ThemeData theme,
    Event lastEvent,
    bool ownMessage,
  ) {
    final durationMs = lastEvent.content
        .tryGetMap<String, Object?>('info')
        ?.tryGet<int>('duration');
    var durationLabel = '';
    if (durationMs != null && durationMs > 0) {
      final d = Duration(milliseconds: durationMs);
      final mm = d.inMinutes;
      final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      durationLabel = ' $mm:$ss';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.graphic_eq,
          size: 14,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '🎤$durationLabel',
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _imagePreview(
    BuildContext context,
    ThemeData theme,
    Event lastEvent,
    bool ownMessage,
  ) {
    final body = lastEvent.content.tryGet<String>('body');
    final label = body != null && body.trim().isNotEmpty
        ? '📷 $body'
        : '📷 Photo';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Hybrid unread indicator for the chat list:
///  - magenta pill with count when there's a mention (highlightCount > 0)
///  - small cyan dot for plain unread (notificationCount > 0 or markedUnread)
///  - nothing when read.
class _HybridUnreadBadge extends StatelessWidget {
  final Room room;
  const _HybridUnreadBadge({required this.room});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    final isMention = room.highlightCount > 0;
    // Only show the dot when the room is actually waiting for attention.
    // `room.hasNewMessages` is too noisy (it stays true on muted/read rooms
    // until the next sync delta) and was causing a permanent cyan dot on
    // every row.
    final hasUnread = room.notificationCount > 0 || room.markedUnread;

    if (isMention) {
      final magenta = cyber?.magenta ?? theme.colorScheme.error;
      final count = room.notificationCount > 0
          ? room.notificationCount
          : room.highlightCount;
      return AnimatedContainer(
        duration: FluffyThemes.animationDuration,
        curve: FluffyThemes.animationCurve,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: magenta,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: magenta.withValues(alpha: 0.45),
              blurRadius: 8,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          '$count',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
      );
    }

    if (hasUnread) {
      final cyan = cyber?.cyan ?? theme.colorScheme.primary;
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: cyan,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: cyan.withValues(alpha: 0.6),
              blurRadius: 6,
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
