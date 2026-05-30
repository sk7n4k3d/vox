import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/pages/chat_list/dummy_chat_list_item.dart';
import 'package:fluffychat/pages/chat_list/liquid_glass_app_bar.dart';
import 'package:fluffychat/pages/chat_list/search_title.dart';
import 'package:fluffychat/pages/chat_list/space_view.dart';
import 'package:fluffychat/pages/chat_list/status_msg_list.dart';
import 'package:fluffychat/utils/stream_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/public_room_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../config/themes.dart';
import '../../widgets/adaptive_dialogs/user_dialog.dart';
import '../../widgets/matrix.dart';
import 'chat_list_filter_pills.dart';
import 'chat_list_header.dart';

class ChatListViewBody extends StatelessWidget {
  final ChatListController controller;

  const ChatListViewBody(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final client = Matrix.of(context).client;
    final activeSpace = controller.activeSpaceId;
    if (activeSpace != null) {
      return SpaceView(
        key: ValueKey(activeSpace),
        spaceId: activeSpace,
        onBack: controller.clearActiveSpace,
        onChatTab: controller.onChatTap,
        activeChat: controller.activeChat,
      );
    }
    final spaces = client.rooms.where((r) => r.isSpace);
    final spaceDelegateCandidates = <String, Room>{};
    for (final space in spaces) {
      for (final spaceChild in space.spaceChildren) {
        final roomId = spaceChild.roomId;
        if (roomId == null) continue;
        spaceDelegateCandidates[roomId] = space;
      }
    }

    final publicRooms = controller.roomSearchResult?.chunk
        .where((room) => room.roomType != 'm.space')
        .toList();
    final publicSpaces = controller.roomSearchResult?.chunk
        .where((room) => room.roomType == 'm.space')
        .toList();
    final userSearchResult = controller.userSearchResult;
    const dummyChatCount = 4;
    final filter = controller.searchController.text.toLowerCase();
    return StreamBuilder(
      key: ValueKey(client.userID.toString()),
      stream: client.onSync.stream
          .where((s) => s.hasRoomUpdate)
          .rateLimit(const Duration(seconds: 1)),
      builder: (context, _) {
        final rooms = controller.filteredRooms;

        // The LiquidGlassAppBar is shown by the parent Scaffold only when
        // not in search mode and no active space. In that case the body is
        // rendered *behind* the AppBar (extendBodyBehindAppBar: true), so we
        // need to reserve room at the top of the scroll view to avoid the
        // first item being hidden under the blur. The Scaffold already pads
        // the status bar above the AppBar, so we only reserve the AppBar's
        // own preferredSize (bar + greeting), NOT the status bar height —
        // that was doubled up before and produced a phantom gap.
        final showLiquidAppBar =
            !controller.isSearchMode && controller.activeSpaceId == null;
        // Reserve exactly the AppBar's own preferredSize (title + greeting +
        // glass search bar). Single source of truth so the reserve stays in
        // sync with the bar layout.
        final topInset = showLiquidAppBar
            ? const LiquidGlassAppBar(showGreeting: true).preferredSize.height
            : 0.0;

        return SafeArea(
          top: !showLiquidAppBar,
          child: CustomScrollView(
            controller: controller.scrollController,
            slivers: [
              if (showLiquidAppBar)
                SliverToBoxAdapter(child: SizedBox(height: topInset)),
              if (controller.isSearchMode)
                ChatListHeader(controller: controller),
              if (showLiquidAppBar)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: ChatListFilterPillsDelegate(
                    controller: controller,
                  ),
                ),
              SliverList(
                delegate: SliverChildListDelegate([
                  if (controller.isSearchMode) ...[
                    SearchTitle(
                      title: L10n.of(context).publicRooms,
                      icon: const Icon(Icons.explore_outlined),
                    ),
                    PublicRoomsHorizontalList(publicRooms: publicRooms),
                    SearchTitle(
                      title: L10n.of(context).publicSpaces,
                      icon: const Icon(Icons.workspaces_outlined),
                    ),
                    PublicRoomsHorizontalList(publicRooms: publicSpaces),
                    SearchTitle(
                      title: L10n.of(context).users,
                      icon: const Icon(Icons.group_outlined),
                    ),
                    AnimatedContainer(
                      clipBehavior: Clip.hardEdge,
                      decoration: const BoxDecoration(),
                      height:
                          userSearchResult == null ||
                              userSearchResult.results.isEmpty
                          ? 0
                          : 106,
                      duration: FluffyThemes.animationDuration,
                      curve: FluffyThemes.animationCurve,
                      child: userSearchResult == null
                          ? null
                          : ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: userSearchResult.results.length,
                              itemBuilder: (context, i) => _SearchItem(
                                title:
                                    userSearchResult.results[i].displayName ??
                                    userSearchResult
                                        .results[i]
                                        .userId
                                        .localpart ??
                                    L10n.of(context).unknownDevice,
                                avatar: userSearchResult.results[i].avatarUrl,
                                onPressed: () => UserDialog.show(
                                  context: context,
                                  profile: userSearchResult.results[i],
                                ),
                              ),
                            ),
                    ),
                  ],
                  if (!controller.isSearchMode &&
                      AppSettings.showPresences.value)
                    GestureDetector(
                      onLongPress: controller.dismissStatusList,
                      child: StatusMessageList(
                        onStatusEdit: controller.setStatus,
                      ),
                    ),
                  // Filter pills moved to a dedicated SliverPersistentHeader
                  // above; see ChatListFilterPills.
                  if (controller.isSearchMode)
                    SearchTitle(
                      title: L10n.of(context).chats,
                      icon: const Icon(Icons.forum_outlined),
                    ),
                  if (client.prevBatch != null &&
                      rooms.isEmpty &&
                      !controller.isSearchMode) ...[
                    Column(
                      mainAxisAlignment: .center,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            const Column(
                              mainAxisSize: .min,
                              children: [
                                DummyChatListItem(opacity: 0.5, animate: false),
                                DummyChatListItem(opacity: 0.3, animate: false),
                              ],
                            ),
                            Icon(
                              CupertinoIcons.chat_bubble_text_fill,
                              size: 128,
                              color: theme.colorScheme.secondary,
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(
                            client.rooms.isEmpty
                                ? L10n.of(context).noChatsFoundHere
                                : L10n.of(context).noMoreChatsFound,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ]),
              ),
              if (client.prevBatch == null)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => DummyChatListItem(
                      opacity: (dummyChatCount - i) / dummyChatCount,
                      animate: true,
                    ),
                    childCount: dummyChatCount,
                  ),
                ),
              if (client.prevBatch != null)
                SliverList.builder(
                  // Sprint 2 V3 — chatlist items + section headers injected
                  // inline. Each transition between time buckets (Today /
                  // Yesterday / This Week / Earlier) inserts a header row.
                  itemCount: _ChatListSections.totalCount(rooms),
                  itemBuilder: (BuildContext context, int i) {
                    final entry = _ChatListSections.entryAt(rooms, i);
                    if (entry.isHeader) {
                      return _ChatListSectionHeader(label: entry.headerLabel!);
                    }
                    final room = entry.room!;
                    final space = spaceDelegateCandidates[room.id];
                    return _StaggeredFadeIn(
                      // Stagger only the visible top of the list; beyond
                      // 12 items we play the entry at the same delay (avoid
                      // multi-second cascade on big lists).
                      delayMs: (i.clamp(0, 12)) * 35,
                      child: ChatListItem(
                        room,
                        space: space,
                        key: Key('chat_list_item_${room.id}'),
                        filter: filter,
                        onTap: () => controller.onChatTap(room),
                        onLongPress: (context) =>
                            controller.chatContextAction(room, context, space),
                        activeChat: controller.activeChat == room.id,
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class PublicRoomsHorizontalList extends StatelessWidget {
  const PublicRoomsHorizontalList({super.key, required this.publicRooms});

  final List<PublishedRoomsChunk>? publicRooms;

  @override
  Widget build(BuildContext context) {
    final publicRooms = this.publicRooms;
    return AnimatedContainer(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: publicRooms == null || publicRooms.isEmpty ? 0 : 106,
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
      child: publicRooms == null
          ? null
          : ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: publicRooms.length,
              itemBuilder: (context, i) => _SearchItem(
                title:
                    publicRooms[i].name ??
                    publicRooms[i].canonicalAlias?.localpart ??
                    L10n.of(context).group,
                avatar: publicRooms[i].avatarUrl,
                onPressed: () => showAdaptiveDialog(
                  context: context,
                  builder: (c) => PublicRoomDialog(
                    roomAlias:
                        publicRooms[i].canonicalAlias ?? publicRooms[i].roomId,
                    chunk: publicRooms[i],
                  ),
                ),
              ),
            ),
    );
  }
}

class _SearchItem extends StatelessWidget {
  final String title;
  final Uri? avatar;
  final void Function() onPressed;

  const _SearchItem({
    required this.title,
    this.avatar,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    child: SizedBox(
      width: 84,
      child: Column(
        mainAxisSize: .min,
        children: [
          const SizedBox(height: 8),
          Avatar(mxContent: avatar, name: title),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Sprint 2 V3 — chatlist section helper.
///
/// Splits the list into time buckets (Today / Yesterday / This Week / Earlier)
/// based on each room's latest event timestamp, and computes the synthetic
/// indices that include both header rows and room rows.
class _ChatListSections {
  static const String today = 'today';
  static const String yesterday = 'yesterday';
  static const String thisWeek = 'thisWeek';
  static const String earlier = 'earlier';

  static String _bucketFor(Room room) {
    final ts = room.lastEvent?.originServerTs ?? DateTime.now();
    final now = DateTime.now();
    final dThat = DateTime(ts.year, ts.month, ts.day);
    final dNow = DateTime(now.year, now.month, now.day);
    final diff = dNow.difference(dThat).inDays;
    if (diff <= 0) return today;
    if (diff == 1) return yesterday;
    if (diff < 7) return thisWeek;
    return earlier;
  }

  /// Returns the list of (bucket, indexInRooms) pairs flattened with header
  /// markers. Used by `entryAt` / `totalCount`.
  static List<_ChatListEntry> _layout(List<Room> rooms) {
    final entries = <_ChatListEntry>[];
    String? lastBucket;
    for (var i = 0; i < rooms.length; i++) {
      final bucket = _bucketFor(rooms[i]);
      if (bucket != lastBucket) {
        entries.add(_ChatListEntry.header(bucket));
        lastBucket = bucket;
      }
      entries.add(_ChatListEntry.room(rooms[i]));
    }
    return entries;
  }

  static int totalCount(List<Room> rooms) => _layout(rooms).length;

  static _ChatListEntry entryAt(List<Room> rooms, int i) =>
      _layout(rooms)[i];
}

class _ChatListEntry {
  final Room? room;
  final String? headerLabel;

  _ChatListEntry.header(this.headerLabel) : room = null;
  _ChatListEntry.room(this.room) : headerLabel = null;

  bool get isHeader => room == null;
}

/// Sprint 2 V3 — section header row, scroll-along (pas sticky en Sprint 2 mais
/// déjà très visible). Uppercase Rajdhani + accent ligne cyan.
class _ChatListSectionHeader extends StatelessWidget {
  const _ChatListSectionHeader({required this.label});

  final String label;

  String _labelFor(BuildContext context) {
    final l10n = L10n.of(context);
    switch (label) {
      case _ChatListSections.today:
        return l10n.sectionToday.toUpperCase();
      case _ChatListSections.yesterday:
        return l10n.sectionYesterday.toUpperCase();
      case _ChatListSections.thisWeek:
        return l10n.sectionThisWeek.toUpperCase();
      case _ChatListSections.earlier:
      default:
        return l10n.sectionEarlier.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    final accent = cyber?.cyan ?? theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 2,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: const BorderRadius.all(Radius.circular(1)),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _labelFor(context),
            style: FluffyTypography.labelM.copyWith(
              color: accent,
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 0.5,
              color: theme.colorScheme.outlineVariant
                  .withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sprint 2 V3 — slide-up + fade staggered item, played once on first frame
/// after a per-item delay. Used by the chatlist to give an immediate
/// "premium app launch" feel. Subsequent rebuilds (scroll, sync) don't
/// replay the animation thanks to the local _shown flag.
class _StaggeredFadeIn extends StatefulWidget {
  const _StaggeredFadeIn({
    required this.child,
    required this.delayMs,
  });

  final Widget child;
  final int delayMs;

  @override
  State<_StaggeredFadeIn> createState() => _StaggeredFadeInState();
}

class _StaggeredFadeInState extends State<_StaggeredFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: FluffyDurations.medium,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
