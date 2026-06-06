import 'package:collection/collection.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/chat_date_separator.dart';
import 'package:fluffychat/pages/chat/events/message.dart';
import 'package:fluffychat/pages/chat/seen_by_row.dart';
import 'package:fluffychat/pages/chat/typing_indicators.dart';
import 'package:fluffychat/utils/account_config.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/widgets/cyber/scheduled_send.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class ChatEventList extends StatelessWidget {
  final ChatController controller;

  const ChatEventList({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final timeline = controller.timeline;

    if (timeline == null) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final theme = Theme.of(context);

    final colors = [theme.secondaryBubbleColor, theme.bubbleColor];

    final horizontalPadding = FluffyThemes.isColumnMode(context) ? 8.0 : 0.0;

    final events = timeline.events.filterByVisibleInGui(
      threadId: controller.activeThreadId,
    );

    // create a map of eventId --> index to greatly improve performance of
    // ListView's findChildIndexCallback
    final thisEventsKeyMap = <String, int>{};
    for (var i = 0; i < events.length; i++) {
      thisEventsKeyMap[events[i].eventId] = i;
    }

    final hasWallpaper =
        controller.room.client.applicationAccountConfig.wallpaperUrl != null;

    return SelectionArea(
      child: ListView.custom(
        padding: EdgeInsets.only(
          top: 16,
          bottom: 8,
          left: horizontalPadding,
          right: horizontalPadding,
        ),
        reverse: true,
        controller: controller.scrollController,
        keyboardDismissBehavior: PlatformInfos.isIOS
            ? ScrollViewKeyboardDismissBehavior.onDrag
            : ScrollViewKeyboardDismissBehavior.manual,
        childrenDelegate: SliverChildBuilderDelegate(
          (BuildContext context, int i) {
            // Footer to display typing indicator and read receipts:
            if (i == 0) {
              if (timeline.canRequestFuture) {
                return Center(
                  child: TextButton.icon(
                    onPressed: timeline.isRequestingFuture
                        ? null
                        : controller.requestFuture,
                    icon: timeline.isRequestingFuture
                        ? CircularProgressIndicator.adaptive(strokeWidth: 2)
                        : const Icon(Icons.arrow_downward_outlined),
                    label: Text(L10n.of(context).loadMore),
                  ),
                );
              }
              return Column(
                mainAxisSize: .min,
                children: [
                  ScheduledInlineMarker(
                    selector: () => ScheduledMessages.instance
                        .forRoom(controller.room.id),
                  ),
                  SeenByRow(event: events.first),
                  TypingIndicators(controller),
                ],
              );
            }

            // Request history button or progress indicator:
            if (i == events.length + 1) {
              if (controller.activeThreadId != null ||
                  !timeline.canRequestHistory) {
                return const SizedBox.shrink();
              }
              return Builder(
                builder: (context) {
                  final visibleIndex = timeline.events.lastIndexWhere(
                    (event) => !event.isCollapsedState && event.isVisibleInGui,
                  );
                  // lastIndexWhere renvoie -1 si aucun event visible : sur une
                  // timeline courte (<50), `-1 > length-50` serait vrai et
                  // déclencherait un requestHistory parasite. On exige >= 0.
                  if (visibleIndex >= 0 &&
                      visibleIndex > timeline.events.length - 50) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      controller.requestHistory,
                    );
                  }
                  return Center(
                    child: TextButton.icon(
                      onPressed: timeline.isRequestingHistory
                          ? null
                          : controller.requestHistory,
                      icon: timeline.isRequestingHistory
                          ? CircularProgressIndicator.adaptive(strokeWidth: 2)
                          : const Icon(Icons.arrow_upward_outlined),
                      label: Text(L10n.of(context).loadMore),
                    ),
                  );
                },
              );
            }
            i--;

            // The message at this index:
            final event = events[i];
            final animateIn =
                event.eventId == timeline.events.first.eventId &&
                controller.firstUpdateReceived;

            final nextEvent = i + 1 < events.length ? events[i + 1] : null;
            final previousEvent = i > 0 ? events[i - 1] : null;

            // Collapsed state event
            final canExpand =
                event.isCollapsedState &&
                nextEvent?.isCollapsedState == true &&
                previousEvent?.isCollapsedState != true;
            final isCollapsed =
                event.isCollapsedState &&
                previousEvent?.isCollapsedState == true &&
                !controller.expandedEventIds.contains(event.eventId);

            // Floating date separator: rendered above the first message of a
            // new calendar day. The list is reverse=true so events[i+1] is the
            // older neighbour — we compare it to event to detect a day flip.
            // For the oldest visible event (no older neighbour available) we
            // still show the separator so the top of the timeline is labelled.
            final eventDate = event.originServerTs.toLocal();
            final olderNeighbour = nextEvent?.originServerTs.toLocal();
            final showDateSeparator = olderNeighbour == null
                ? i == events.length - 1
                : !ChatDateSeparator.sameCalendarDay(
                    eventDate,
                    olderNeighbour,
                  );

            final messageWidget = Message(
              event,
              bigEmojis: controller.bigEmojis,
              animateIn: animateIn,
              onSwipe: () => controller.replyAction(replyTo: event),
              onInfoTab: controller.showEventInfo,
              onMention: () => controller.sendController.text +=
                  '${event.senderFromMemoryOrFallback.mention} ',
              highlightMarker:
                  controller.scrollToEventIdMarker == event.eventId,
              onSelect: controller.onSelectMessage,
              scrollToEventId: controller.scrollToEventId,
              longPressSelect: controller.selectedEvents.isNotEmpty,
              selected: controller.selectedEvents.any(
                (e) => e.eventId == event.eventId,
              ),
              singleSelected:
                  controller.selectedEvents.singleOrNull?.eventId ==
                  event.eventId,
              onEdit: controller.editSelectedEventAction,
              controller: controller,
              timeline: timeline,
              displayReadMarker:
                  i > 0 && controller.readMarkerEventId == event.eventId,
              nextEvent: nextEvent,
              previousEvent: previousEvent,
              wallpaperMode: hasWallpaper,
              scrollController: controller.scrollController,
              colors: colors,
              isCollapsed: isCollapsed,
              enterThread: controller.activeThreadId == null
                  ? controller.enterThread
                  : null,
              onExpand: canExpand
                  ? () => controller.expandEventsFrom(
                      event,
                      !controller.expandedEventIds.contains(event.eventId),
                    )
                  : null,
            );

            return AutoScrollTag(
              key: ValueKey(event.transactionId ?? event.eventId),
              index: i,
              controller: controller.scrollController,
              child: showDateSeparator
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ChatDateSeparator(date: eventDate),
                        messageWidget,
                      ],
                    )
                  : messageWidget,
            );
          },
          childCount: events.length + 2,
          findChildIndexCallback: (key) =>
              controller.findChildIndexCallback(key, thisEventsKeyMap),
        ),
      ),
    );
  }
}
