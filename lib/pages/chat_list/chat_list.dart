import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/chat_list_view.dart';
import 'package:fluffychat/pages/chat_list/liquid_glass_app_bar.dart';
import 'package:fluffychat/pages/sms_chat/sms_chat_page.dart';
import 'package:fluffychat/utils/conversation_lock.dart';
import 'package:fluffychat/utils/ephemeral/ephemeral_messages.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/utils/show_update_snackbar.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/utils/sms/spam_filter.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/cyber/ephemeral_picker.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:matrix/matrix.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../utils/account_bundles.dart';
import '../../config/setting_keys.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/matrix.dart';

enum ActiveFilter { allChats, messages, groups, unread, spaces }

extension LocalizedActiveFilter on ActiveFilter {
  String toLocalizedString(BuildContext context) {
    switch (this) {
      case ActiveFilter.allChats:
        return L10n.of(context).all;
      case ActiveFilter.messages:
        return L10n.of(context).messages;
      case ActiveFilter.unread:
        return L10n.of(context).unread;
      case ActiveFilter.groups:
        return L10n.of(context).groups;
      case ActiveFilter.spaces:
        return L10n.of(context).spaces;
    }
  }
}

class ChatList extends StatefulWidget {
  static BuildContext? contextForVoip;
  final String? activeChat;
  final String? activeSpace;
  final bool displayNavigationRail;

  const ChatList({
    super.key,
    required this.activeChat,
    this.activeSpace,
    this.displayNavigationRail = false,
  });

  @override
  ChatListController createState() => ChatListController();
}

class ChatListController extends State<ChatList>
    with TickerProviderStateMixin, RouteAware {
  StreamSubscription? _intentDataStreamSubscription;

  StreamSubscription? _intentFileStreamSubscription;

  late ActiveFilter activeFilter;

  String? _activeSpaceId;
  String? get activeSpaceId => _activeSpaceId;

  Future<void> setActiveSpace(String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();

    setState(() {
      _activeSpaceId = spaceId;
    });
  }

  void clearActiveSpace() => setState(() {
    _activeSpaceId = null;
  });

  /// Asks the user to accept, decline or block a room invitation.
  ///
  /// Tapping an invited room used to join it silently, with no explicit
  /// "join / decline" affordance (only a small trailing trash icon). This
  /// restores the confirmation dialog upstream FluffyChat showed here.
  /// Returns true when the caller should proceed with the join.
  Future<bool> _confirmRoomInvitation(Room room) async {
    final theme = Theme.of(context);
    final inviteEvent = room.getState(
      EventTypes.RoomMember,
      room.client.userID!,
    );
    final matrixLocals = MatrixLocals(L10n.of(context));
    final reason = inviteEvent?.content.tryGet<String>('reason');
    final inviterId = inviteEvent?.senderId;
    final inviterName = inviterId == null
        ? null
        : room
              .unsafeGetUserFromMemoryOrFallback(inviterId)
              .calcDisplayname(i18n: matrixLocals);
    final action = await showAdaptiveDialog<_InviteAction>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 256),
          child: Center(
            child: Text(
              room.getLocalizedDisplayname(matrixLocals),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 256, maxHeight: 256),
          child: Text(
            reason ??
                (inviterName == null
                    ? L10n.of(context).inviteGroupChat
                    : L10n.of(context).youInvitedBy(inviterName)),
            textAlign: TextAlign.center,
          ),
        ),
        actions: [
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(_InviteAction.accept),
            bigButtons: true,
            child: Text(L10n.of(context).accept),
          ),
          AdaptiveDialogAction(
            onPressed: () => Navigator.of(context).pop(_InviteAction.decline),
            bigButtons: true,
            child: Text(
              L10n.of(context).declineInvitation,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          if (inviterId != null)
            AdaptiveDialogAction(
              onPressed: () => Navigator.of(context).pop(_InviteAction.block),
              bigButtons: true,
              child: Text(
                L10n.of(context).block,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
    if (!mounted) return false;
    switch (action) {
      case null:
        return false;
      case _InviteAction.accept:
        return true;
      case _InviteAction.decline:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.leave(),
        );
        return false;
      case _InviteAction.block:
        context.go('/rooms/settings/security/ignorelist', extra: inviterId);
        return false;
    }
  }

  Future<void> onChatTap(Room room) async {
    if (room.membership == Membership.invite) {
      if (!await _confirmRoomInvitation(room)) return;
      final joinResult = await showFutureLoadingDialog(
        context: context,
        future: () async {
          final waitForRoom = room.client.waitForRoomInSync(
            room.id,
            join: true,
          );
          await room.join();
          await waitForRoom;
        },
        exceptionContext: ExceptionContext.joinRoom,
      );
      if (joinResult.error != null) return;
    }

    if (room.membership == Membership.ban) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).youHaveBeenBannedFromThisChat)),
      );
      return;
    }

    if (room.membership == Membership.leave) {
      context.go('/rooms/archive/${room.id}');
      return;
    }

    if (room.isSpace) {
      setActiveSpace(room.id);
      return;
    }

    // Per-conversation lock gate: a hidden (locked + not yet unlocked this
    // session) room must pass biometric/PIN auth before it opens.
    if (!await _gateConversation(room.id)) return;

    context.go('/rooms/${room.id}');
  }

  /// Prompts for biometric/PIN if [id] is a hidden locked conversation.
  /// Returns true when the conversation may be opened (not locked, already
  /// unlocked this session, or the user just authenticated).
  Future<bool> _gateConversation(String id) async {
    if (!ConversationLock.instance.isHidden(id)) return true;
    return ConversationLock.instance.authenticate(id, L10n.of(context).appLock);
  }

  /// Toggles the per-conversation lock for [id]. Locking is immediate;
  /// unlocking permanently requires passing biometric/PIN first.
  Future<void> _toggleConversationLock(String id) async {
    final lock = ConversationLock.instance;
    if (lock.isLocked(id)) {
      // Must authenticate before removing the lock so a found-unlocked phone
      // can't silently strip protection.
      final ok = await lock.authenticate(id, L10n.of(context).appLock);
      if (!ok) return;
      await lock.unlockPermanently(id);
    } else {
      await lock.lock(id);
    }
    if (mounted) setState(() {});
  }

  bool Function(Room) getRoomFilterByActiveFilter(ActiveFilter activeFilter) {
    switch (activeFilter) {
      case ActiveFilter.allChats:
        return (room) => true;
      case ActiveFilter.messages:
        return (room) => !room.isSpace && room.isDirectChat;
      case ActiveFilter.groups:
        return (room) => !room.isSpace && !room.isDirectChat;
      case ActiveFilter.unread:
        return (room) => room.isUnreadOrInvited;
      case ActiveFilter.spaces:
        return (room) => room.isSpace;
    }
  }

  List<Room> get filteredRooms => Matrix.of(
    context,
  ).client.rooms.where(getRoomFilterByActiveFilter(activeFilter)).toList();

  /// SMS conversations merged into the chat list (only when VOX is the default
  /// SMS app). Loaded natively via [SmsBridge]; refreshed on each incoming SMS.
  List<SmsConversation> smsConversations = const [];

  /// Threads hidden by the local spam filter, surfaced behind a single
  /// "Spam (N)" counter at the bottom of the list.
  List<SmsConversation> smsSpamConversations = const [];
  StreamSubscription<SmsIncoming>? _smsSub;
  StreamSubscription<SmsOpenRequest>? _smsOpenSub;
  StreamSubscription<void>? _spamSub;
  Timer? _smsReloadDebounce;

  /// Garde-fou : la proposition d'exemption batterie n'est tentée qu'une fois par
  /// session (sinon elle se redéclencherait à chaque rechargement SMS).
  bool _batteryPromptChecked = false;

  Future<void> _loadSmsConversations() async {
    if (!await SmsBridge.instance.isDefaultSmsApp()) {
      // Lost (or never had) the default-SMS role: clear any stale SMS rows so
      // the list doesn't keep showing dead conversations.
      if (mounted && smsConversations.isNotEmpty) {
        setState(() => smsConversations = const []);
      }
      return;
    }
    // VOX est l'app SMS par défaut : s'assurer qu'elle peut recevoir les SMS
    // même fermée + tel en veille (exemption Doze).
    unawaited(_maybePromptBatteryExemption());
    final convs = await SmsBridge.instance.listConversations();
    final archived = await SmsBridge.instance.archivedThreadIds();
    if (!mounted) return;
    // Hide archived threads, and scrub the snippet/name of locked conversations
    // *in the model* so sensitive content never reaches the widget tree (a blur
    // alone is reversible and leaks via screenshots/inspector).
    final visible = <SmsConversation>[];
    final spam = <SmsConversation>[];
    final spamEnabled = SpamFilterService.instance.isEnabled;
    for (final c in convs) {
      if (archived.contains(c.threadId)) continue;
      if (spamEnabled && SpamFilterService.instance.isSpam(c.threadId)) {
        spam.add(c);
        continue;
      }
      if (ConversationLock.instance.isHidden(
        ConversationLock.smsId(c.threadId),
      )) {
        visible.add(
          SmsConversation(
            threadId: c.threadId,
            address: c.address,
            displayName: null,
            snippet: '',
            date: c.date,
            unreadCount: c.unreadCount,
          ),
        );
      } else {
        visible.add(c);
      }
    }
    setState(() {
      smsConversations = visible;
      smsSpamConversations = spam;
    });
  }

  /// Classifies an incoming SMS against the local spam heuristic. Best-effort:
  /// the contact book decides "not spam"; when enough criteria match the thread
  /// is flagged (hidden from the list + silenced natively), the notification of
  /// the already-shown message is cancelled, and the list reloads.
  Future<void> _maybeFlagSpam(SmsIncoming sms) async {
    if (!SpamFilterService.instance.isEnabled || sms.threadId.isEmpty) return;
    if (SpamFilterService.instance.isSpam(sms.threadId)) return;
    var hasContact = false;
    try {
      final contacts = await SmsBridge.instance.listContacts();
      final target = sms.address.replaceAll(RegExp(r'[^0-9]'), '');
      hasContact = contacts.any(
        (c) => c.numbers.any(
          (n) => n.number.replaceAll(RegExp(r'[^0-9]'), '') == target,
        ),
      );
    } catch (_) {
      hasContact = false;
    }
    final spam = SpamFilterService.looksLikeSpam(
      address: sms.address,
      body: sms.body,
      hasContact: hasContact,
    );
    if (!spam) return;
    await SpamFilterService.instance.flag(sms.threadId);
    await SmsBridge.instance.cancelNotification(sms.threadId);
    if (mounted) await _loadSmsConversations();
  }

  /// Pull-to-refresh de la liste de conversations : force un one-shot sync
  /// Matrix (ou attend le sync en cours) puis recharge les conversations SMS.
  /// Best-effort : offline/timeout ne doit jamais faire crasher le geste —
  /// l'indicateur se contente de s'arrêter. Le `.timeout` borne l'attente car
  /// `oneShotSync` peut rejoindre un long-poll /sync déjà en vol (jusqu'à 30s).
  Future<void> onPullToRefresh() async {
    try {
      await Matrix.of(context).client
          .oneShotSync(timeout: const Duration(seconds: 5))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Réseau down / timeout : on laisse le sync de fond reprendre la main.
    }
    if (!mounted) return;
    try {
      await _loadSmsConversations();
    } catch (_) {
      // Bridge SMS indisponible (non-Android, rôle perdu…) : non bloquant.
    }
  }

  /// Une fois par session : si VOX est l'app SMS par défaut mais n'est pas
  /// exemptée d'optimisation batterie, propose à l'utilisateur de l'exempter.
  /// Sans cette exemption, en Doze profond / standby bas, Android diffère le
  /// réveil du process pour SMS_DELIVER → SMS reçus en retard ou ratés quand
  /// l'app est fermée (Matrix y échappe via son push FCM).
  Future<void> _maybePromptBatteryExemption() async {
    if (_batteryPromptChecked) return;
    _batteryPromptChecked = true;
    if (await SmsBridge.instance.isIgnoringBatteryOptimizations()) return;
    if (!mounted) return;
    final accept = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Réception des SMS en arrière-plan'),
        content: const Text(
          'Pour recevoir tes SMS/MMS même quand VOX est fermée, autorise '
          "l'application à ignorer l'optimisation de batterie. Sans ça, Android "
          'peut retarder ou bloquer les messages pendant la veille du téléphone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Activer'),
          ),
        ],
      ),
    );
    if (accept == true) {
      await SmsBridge.instance.requestIgnoreBatteryOptimizations();
    }
  }

  /// Opens an SMS conversation in the dedicated [SmsChatPage], then refreshes
  /// the list on return (a deleted conversation must disappear).
  Future<void> onSmsTap(SmsConversation conv) async {
    if (!await _gateConversation(ConversationLock.smsId(conv.threadId))) {
      return;
    }
    SmsBridge.instance.markRead(conv.threadId);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SmsChatPage(
          threadId: conv.threadId,
          address: conv.address,
          displayName: conv.displayName,
          photoPath: conv.photoPath,
        ),
      ),
    );
    await _loadSmsConversations();
  }

  /// Opens an SMS conversation from a notification tap / Voice action. Resolves
  /// the thread for the address when the threadId is unknown, passes the lock
  /// gate, then pushes [SmsChatPage] (optionally starting voice dictation).
  Future<void> openSmsFromIntent(SmsOpenRequest req) async {
    if (!req.isValid || !mounted) return;
    // Resolve a display name + canonical thread from the conversation list when
    // possible (so the header shows the contact, not the raw number).
    SmsConversation? match;
    final reqThread = int.tryParse(req.threadId) ?? -1;
    for (final c in smsConversations) {
      if ((reqThread > 0 && c.threadId == req.threadId) ||
          (req.address.isNotEmpty && c.address == req.address)) {
        match = c;
        break;
      }
    }
    final threadId = match?.threadId ?? req.threadId;
    final address = match?.address ?? req.address;
    if ((int.tryParse(threadId) ?? -1) <= 0 && address.isEmpty) return;
    if (!await _gateConversation(ConversationLock.smsId(threadId))) return;
    SmsBridge.instance.markRead(threadId);
    SmsBridge.instance.cancelNotification(threadId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SmsChatPage(
          threadId: threadId,
          address: address,
          displayName: match?.displayName,
          photoPath: match?.photoPath,
          startVoiceReply: req.voiceReply,
        ),
      ),
    );
    await _loadSmsConversations();
  }

  /// Archives (or unarchives) an SMS conversation and refreshes the list.
  Future<void> archiveSms(SmsConversation conv) async {
    await SmsBridge.instance.setArchived(conv.threadId, true);
    await _loadSmsConversations();
  }

  /// Deletes an SMS conversation (all messages) and refreshes the list.
  Future<void> deleteSms(SmsConversation conv) async {
    await SmsBridge.instance.deleteConversation(conv.threadId);
    await _loadSmsConversations();
  }

  /// Opens the spam sheet (long-press on the "Spam (N)" counter): lists hidden
  /// spam threads with a "Débloquer / Restaurer" button each. Restoring unhides
  /// the thread and re-enables its notifications.
  Future<void> showSpamSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StreamBuilder<void>(
        stream: SpamFilterService.instance.changes,
        builder: (sheetContext, _) {
          final spam = smsSpamConversations;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.shield_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Spam (${spam.length})',
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                if (spam.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: Text('Aucun message indésirable'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: spam.length,
                      itemBuilder: (context, i) {
                        final conv = spam[i];
                        return ListTile(
                          title: Text(conv.title),
                          subtitle: Text(
                            conv.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () async {
                              await SpamFilterService.instance.restore(
                                conv.threadId,
                              );
                              if (sheetContext.mounted) {
                                Navigator.of(sheetContext).pop();
                              }
                              if (mounted) await _loadSmsConversations();
                            },
                            child: const Text('Débloquer'),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Long-press menu for an SMS conversation: lock / archive / delete.
  Future<void> smsContextAction(SmsConversation conv) async {
    final id = ConversationLock.smsId(conv.threadId);
    final locked = ConversationLock.instance.isLocked(id);
    final action = await showModalActionPopup<String>(
      context: context,
      title: conv.title,
      actions: [
        AdaptiveModalAction(
          value: 'lock',
          label: locked
              ? L10n.of(context).unlockConversation
              : L10n.of(context).lockConversation,
          icon: Icon(locked ? Icons.lock_open_outlined : Icons.lock_outline),
        ),
        AdaptiveModalAction(
          value: 'ephemeral',
          label: L10n.of(context).ephemeralMessages,
          icon: const Icon(Icons.timer_outlined),
        ),
        AdaptiveModalAction(
          value: 'archive',
          label: L10n.of(context).archive,
          icon: const Icon(Icons.archive_outlined),
        ),
        AdaptiveModalAction(
          value: 'delete',
          label: L10n.of(context).delete,
          isDestructive: true,
          icon: const Icon(Icons.delete_outlined),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'lock':
        await _toggleConversationLock(id);
        return;
      case 'ephemeral':
        final convId = EphemeralMessages.smsConvId(conv.threadId);
        final current = EphemeralMessages.instance.policyFor(convId);
        final chosen = await EphemeralPicker.show(context, current: current);
        if (chosen == null || !mounted) return;
        await EphemeralMessages.instance.setPolicy(convId, chosen);
        return;
      case 'archive':
        await archiveSms(conv);
        return;
      case 'delete':
        final ok = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).delete,
          message: L10n.of(context).areYouSure,
          okLabel: L10n.of(context).delete,
          cancelLabel: L10n.of(context).cancel,
          isDestructive: true,
        );
        if (ok == OkCancelResult.ok) await deleteSms(conv);
        return;
    }
  }

  bool isSearchMode = false;
  Future<QueryPublicRoomsResponse>? publicRoomsResponse;
  String? searchServer;
  Timer? _coolDown;
  SearchUserDirectoryResponse? userSearchResult;
  QueryPublicRoomsResponse? roomSearchResult;

  bool isSearching = false;
  static const String _serverStoreNamespace = 'im.fluffychat.search.server';

  Future<void> setServer() async {
    final newServer = await showTextInputDialog(
      useRootNavigator: false,
      title: L10n.of(context).changeTheHomeserver,
      context: context,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      prefixText: 'https://',
      hintText: Matrix.of(context).client.homeserver?.host,
      initialText: searchServer,
      keyboardType: TextInputType.url,
      autocorrect: false,
      validator: (server) => server.contains('.') == true
          ? null
          : L10n.of(context).invalidServerName,
    );
    if (newServer == null) return;
    Matrix.of(context).store.setString(_serverStoreNamespace, newServer);
    setState(() {
      searchServer = newServer;
    });
    _coolDown?.cancel();
    _coolDown = Timer(const Duration(milliseconds: 500), _search);
  }

  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  Future<void> _search() async {
    if (!mounted) return;
    final client = Matrix.of(context).client;
    if (!isSearching) {
      setState(() {
        isSearching = true;
      });
    }
    SearchUserDirectoryResponse? userSearchResult;
    QueryPublicRoomsResponse? roomSearchResult;
    final searchQuery = searchController.text.trim();
    try {
      roomSearchResult = await client.queryPublicRooms(
        server: searchServer,
        filter: PublicRoomQueryFilter(genericSearchTerm: searchQuery),
        limit: 20,
      );

      if (searchQuery.isValidMatrixId &&
          searchQuery.sigil == '#' &&
          roomSearchResult.chunk.any(
                (room) => room.canonicalAlias == searchQuery,
              ) ==
              false) {
        final response = await client.getRoomIdByAlias(searchQuery);
        final roomId = response.roomId;
        if (roomId != null) {
          roomSearchResult.chunk.add(
            PublishedRoomsChunk(
              name: searchQuery,
              guestCanJoin: false,
              numJoinedMembers: 0,
              roomId: roomId,
              worldReadable: false,
              canonicalAlias: searchQuery,
            ),
          );
        }
      }
      userSearchResult = await client.searchUserDirectory(
        searchController.text,
        limit: 20,
      );
    } catch (e, s) {
      Logs().w('Searching has crashed', e, s);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    }
    if (!isSearchMode) return;
    setState(() {
      isSearching = false;
      this.roomSearchResult = roomSearchResult;
      this.userSearchResult = userSearchResult;
    });
  }

  void onSearchEnter(String text, {bool globalSearch = true}) {
    if (text.isEmpty) {
      cancelSearch(unfocus: false);
      return;
    }

    setState(() {
      isSearchMode = true;
    });
    _coolDown?.cancel();
    if (globalSearch) {
      _coolDown = Timer(const Duration(milliseconds: 500), _search);
    }
  }

  void startSearch() {
    setState(() {
      isSearchMode = true;
    });
    searchFocusNode.requestFocus();
    _coolDown?.cancel();
    _coolDown = Timer(const Duration(milliseconds: 500), _search);
  }

  void cancelSearch({bool unfocus = true}) {
    setState(() {
      searchController.clear();
      isSearchMode = false;
      roomSearchResult = userSearchResult = null;
      isSearching = false;
    });
    if (unfocus) searchFocusNode.unfocus();
  }

  BoxConstraints? snappingSheetContainerSize;

  final ScrollController scrollController = ScrollController();
  final ValueNotifier<bool> scrolledToTop = ValueNotifier(true);

  final StreamController<Client> _clientStream = StreamController.broadcast();

  Stream<Client> get clientStream => _clientStream.stream;

  void addAccountAction() => context.go('/rooms/settings/account');

  void _onScroll() {
    final newScrolledToTop = scrollController.position.pixels <= 0;
    if (newScrolledToTop != scrolledToTop.value) {
      scrolledToTop.value = newScrolledToTop;
    }
  }

  Future<void> editSpace(BuildContext context, String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();
    if (mounted) {
      context.push('/rooms/$spaceId/details');
    }
  }

  // Needs to match GroupsSpacesEntry for 'separate group' checking.
  List<Room> get spaces =>
      Matrix.of(context).client.rooms.where((r) => r.isSpace).toList();

  String? get activeChat => widget.activeChat;

  void _processIncomingSharedMedia(List<SharedMediaFile> files) {
    files.removeWhere(
      (file) => file.path.startsWith(AppConfig.deepLinkPrefix) == true,
    );
    if (files.isEmpty) return;

    showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: files.map((file) {
          if ({SharedMediaType.text, SharedMediaType.url}.contains(file.type)) {
            return TextShareItem(file.path);
          }
          return FileShareItem(
            XFile(
              file.path.replaceFirst('file://', ''),
              mimeType: file.mimeType,
            ),
          );
        }).toList(),
      ),
    );
  }

  void _initReceiveSharingIntent() {
    if (!PlatformInfos.isMobile) return;

    // For sharing images coming from outside the app while the app is in the memory
    _intentFileStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_processIncomingSharedMedia, onError: print);

    // For sharing images coming from outside the app while the app is closed
    ReceiveSharingIntent.instance.getInitialMedia().then(
      _processIncomingSharedMedia,
    );

    if (PlatformInfos.isAndroid) {
      final shortcuts = FlutterShortcuts();
      shortcuts.initialize().then(
        (_) => shortcuts.listenAction((action) {
          if (!mounted) return;
          UrlLauncher(context, action).launchUrl();
        }),
      );
    }
  }

  @override
  void initState() {
    activeFilter = ActiveFilter.allChats;
    _initReceiveSharingIntent();
    _activeSpaceId = widget.activeSpace;

    scrollController.addListener(_onScroll);
    _waitForFirstSync();
    // Load the local spam filter state (enabled flag + flagged threads) and
    // mirror the native persisted set before the first list paint, so hidden
    // spam threads never flash in the list.
    SpamFilterService.instance.load().then((_) async {
      await SpamFilterService.instance.syncFromNative();
      if (mounted) _loadSmsConversations();
    });
    _spamSub = SpamFilterService.instance.changes.listen((_) {
      if (mounted) {
        setState(() {});
        _loadSmsConversations();
      }
    });
    _loadSmsConversations();
    // Coalesce incoming-SMS bursts (a multipart SMS arrives as N events) into a
    // single reload so we don't re-query the whole provider N times in a row.
    _smsSub = SmsBridge.instance.incoming.listen((sms) {
      _smsReloadDebounce?.cancel();
      _smsReloadDebounce = Timer(
        const Duration(milliseconds: 800),
        _loadSmsConversations,
      );
      _maybeFlagSpam(sms);
    });
    // Open-conversation requests from notification taps (app already running).
    _smsOpenSub = SmsBridge.instance.openRequests.listen(openSmsFromIntent);
    // And consume a request captured before we were listening (cold start from
    // a notification tap), once the list has loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await SmsBridge.instance.takePendingOpenRequest();
      if (pending != null && mounted) {
        // Let the SMS list load first so we can resolve the contact name.
        await _loadSmsConversations();
        if (mounted) await openSmsFromIntent(pending);
      }
    });
    // Arm the local scheduled-message queue (schedule send) once we have a
    // logged-in client. Idempotent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final client = Matrix.of(context).client;
        ScheduledMessages.instance.start(client);
        // Arm the disappearing-message expiry queue (redact Matrix / delete SMS
        // at expiry). Idempotent.
        EphemeralMessages.instance.start(client);
      }
    });
    // Load the persisted set of per-conversation locks so the list can mask
    // sensitive previews from the first paint, and rebuild whenever a lock
    // toggles or the session re-locks so the mask updates instantly.
    ConversationLock.instance.load();
    ConversationLock.instance.addListener(_onConversationLockChanged);
    _hackyWebRTCFixForWeb();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showLastSeenSupportBanner();
        searchServer = Matrix.of(
          context,
        ).store.getString(_serverStoreNamespace);
        Matrix.of(context).backgroundPush?.setupPush();
        UpdateNotifier.showUpdateSnackBar(context);
      }

      // Workaround for system UI overlay style not applied on app start
      SystemChrome.setSystemUIOverlayStyle(
        Theme.of(context).appBarTheme.systemOverlayStyle!,
      );
    });

    super.initState();
  }

  void _onConversationLockChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _intentFileStreamSubscription?.cancel();
    _smsSub?.cancel();
    _smsOpenSub?.cancel();
    _spamSub?.cancel();
    _smsReloadDebounce?.cancel();
    _coolDown?.cancel();
    ConversationLock.instance.removeListener(_onConversationLockChanged);
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    searchController.dispose();
    searchFocusNode.dispose();
    scrolledToTop.dispose();
    _clientStream.close();
    super.dispose();
  }

  Future<void> _showLastSeenSupportBanner() async {
    if (AppSettings.supportBannerOptOut.value) return;

    if (AppSettings.lastSeenSupportBanner.value == 0) {
      await AppSettings.lastSeenSupportBanner.setItem(
        DateTime.now().millisecondsSinceEpoch,
      );
      return;
    }

    final lastSeenSupportBanner = DateTime.fromMillisecondsSinceEpoch(
      AppSettings.lastSeenSupportBanner.value,
    );

    if (DateTime.now().difference(lastSeenSupportBanner) >=
        Duration(days: 6 * 7)) {
      final theme = Theme.of(context);
      final messenger = ScaffoldMessenger.of(context);
      messenger.showMaterialBanner(
        MaterialBanner(
          backgroundColor: theme.colorScheme.errorContainer,
          leading: CloseButton(
            color: theme.colorScheme.onErrorContainer,
            onPressed: () async {
              final okCancelResult = await showOkCancelAlertDialog(
                context: context,
                title: L10n.of(context).skipSupportingFluffyChat,
                message: L10n.of(context).fluffyChatSupportBannerMessage,
                okLabel: L10n.of(context).iDoNotWantToSupport,
                cancelLabel: L10n.of(context).iAlreadySupportFluffyChat,
                isDestructive: true,
              );
              switch (okCancelResult) {
                case null:
                  return;
                case OkCancelResult.ok:
                  messenger.clearMaterialBanners();
                  return;
                case OkCancelResult.cancel:
                  messenger.clearMaterialBanners();
                  await AppSettings.supportBannerOptOut.setItem(true);
                  return;
              }
            },
          ),
          content: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              L10n.of(context).fluffyChatSupportBannerMessage,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                messenger.clearMaterialBanners();
                launchUrlString(
                  'https://fluffychat.im/faq/#how_can_i_support_fluffychat',
                );
              },
              child: Text(
                L10n.of(context).support,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      );
      await AppSettings.lastSeenSupportBanner.setItem(
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    return;
  }

  Future<void> chatContextAction(
    Room room,
    BuildContext posContext, [
    Room? space,
  ]) async {
    final overlay =
        Overlay.of(posContext).context.findRenderObject() as RenderBox;

    final button = posContext.findRenderObject() as RenderBox;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(const Offset(0, -65), ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(-50, 0),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final displayname = room.getLocalizedDisplayname(
      MatrixLocals(L10n.of(context)),
    );

    final spacesWithPowerLevels = room.client.rooms
        .where(
          (space) =>
              space.isSpace &&
              space.canChangeStateEvent(EventTypes.SpaceChild) &&
              !space.spaceChildren.any((c) => c.roomId == room.id),
        )
        .toList();

    final action = await showMenu<ChatContextAction>(
      context: posContext,
      position: position,
      items: [
        PopupMenuItem(
          value: ChatContextAction.open,
          child: Row(
            spacing: 12.0,
            children: [
              Avatar(mxContent: room.avatar, name: displayname, size: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(displayname, maxLines: 1, overflow: .ellipsis),
              ),
            ],
          ),
        ),
        if (space != null)
          PopupMenuItem(
            value: ChatContextAction.goToSpace,
            child: Row(
              mainAxisSize: .min,
              children: [
                Avatar(
                  mxContent: space.avatar,
                  size: Avatar.defaultSize / 2,
                  name: space.getLocalizedDisplayname(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L10n.of(context).goToSpace(space.getLocalizedDisplayname()),
                  ),
                ),
              ],
            ),
          ),
        if (room.membership == Membership.join) ...[
          PopupMenuItem(
            value: ChatContextAction.mute,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.pushRuleState == PushRuleState.notify
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_off,
                ),
                const SizedBox(width: 12),
                Text(
                  room.pushRuleState == PushRuleState.notify
                      ? L10n.of(context).muteChat
                      : L10n.of(context).unmuteChat,
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: ChatContextAction.markUnread,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.markedUnread
                      ? Icons.mark_as_unread
                      : Icons.mark_as_unread_outlined,
                ),
                const SizedBox(width: 12),
                Text(
                  room.markedUnread
                      ? L10n.of(context).markAsRead
                      : L10n.of(context).markAsUnread,
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: ChatContextAction.lock,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  ConversationLock.instance.isLocked(room.id)
                      ? Icons.lock_open_outlined
                      : Icons.lock_outline,
                ),
                const SizedBox(width: 12),
                Text(
                  ConversationLock.instance.isLocked(room.id)
                      ? L10n.of(context).unlockConversation
                      : L10n.of(context).lockConversation,
                ),
              ],
            ),
          ),
          if (!room.isLowPriority)
            PopupMenuItem(
              value: ChatContextAction.favorite,
              child: Row(
                mainAxisSize: .min,
                children: [
                  Icon(
                    room.isFavourite ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    room.isFavourite
                        ? L10n.of(context).unpin
                        : L10n.of(context).pin,
                  ),
                ],
              ),
            ),
          if (!room.isFavourite)
            PopupMenuItem(
              value: ChatContextAction.lowPriority,
              child: Row(
                mainAxisSize: .min,
                children: [
                  Icon(
                    room.isLowPriority
                        ? Icons.low_priority
                        : Icons.low_priority_outlined,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    room.isLowPriority
                        ? L10n.of(context).unsetLowPriority
                        : L10n.of(context).setLowPriority,
                  ),
                ],
              ),
            ),
          if (spacesWithPowerLevels.isNotEmpty)
            PopupMenuItem(
              value: ChatContextAction.addToSpace,
              child: Row(
                mainAxisSize: .min,
                children: [
                  const Icon(Icons.group_work_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).addToSpace),
                ],
              ),
            ),
        ],
        PopupMenuItem(
          value: ChatContextAction.leave,
          child: Row(
            mainAxisSize: .min,
            children: [
              Icon(
                Icons.delete_outlined,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Text(
                room.membership == Membership.invite
                    ? L10n.of(context).delete
                    : L10n.of(context).leave,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
        if (room.membership == Membership.invite)
          PopupMenuItem(
            value: ChatContextAction.block,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  Icons.block_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Text(
                  L10n.of(context).block,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (action == null) return;
    if (!mounted) return;

    switch (action) {
      case ChatContextAction.open:
        onChatTap(room);
        return;
      case ChatContextAction.goToSpace:
        setActiveSpace(space!.id);
        return;
      case ChatContextAction.favorite:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.setFavourite(!room.isFavourite),
        );
        return;
      case ChatContextAction.markUnread:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.markUnread(!room.markedUnread),
        );
        return;
      case ChatContextAction.mute:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.setPushRuleState(
            room.pushRuleState == PushRuleState.notify
                ? PushRuleState.mentionsOnly
                : PushRuleState.notify,
          ),
        );
        return;
      case ChatContextAction.lock:
        await _toggleConversationLock(room.id);
        return;
      case ChatContextAction.block:
        final inviteEvent = room.getState(
          EventTypes.RoomMember,
          room.client.userID!,
        );
        context.go(
          '/rooms/settings/security/ignorelist',
          extra: inviteEvent?.senderId,
        );
      case ChatContextAction.leave:
        final confirmed = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).archiveRoomDescription,
          okLabel: L10n.of(context).leave,
          cancelLabel: L10n.of(context).cancel,
          isDestructive: true,
        );
        if (confirmed == OkCancelResult.cancel) return;
        if (!mounted) return;

        await showFutureLoadingDialog(context: context, future: room.leave);

        return;
      case ChatContextAction.addToSpace:
        final space = await showModalActionPopup(
          context: context,
          title: L10n.of(context).space,
          actions: spacesWithPowerLevels
              .map(
                (space) => AdaptiveModalAction(
                  value: space,
                  label: space.getLocalizedDisplayname(
                    MatrixLocals(L10n.of(context)),
                  ),
                ),
              )
              .toList(),
        );
        if (space == null) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => space.setSpaceChild(room.id),
        );
      case ChatContextAction.lowPriority:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.setLowPriority(!room.isLowPriority),
        );
        return;
    }
  }

  Future<void> dismissStatusList() async {
    final result = await showOkCancelAlertDialog(
      title: L10n.of(context).hidePresences,
      context: context,
    );
    if (result == OkCancelResult.ok) {
      AppSettings.showPresences.setItem(false);
      setState(() {});
    }
  }

  Future<void> setStatus() async {
    final client = Matrix.of(context).client;
    final currentPresence = await client.fetchCurrentPresence(client.userID!);
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: L10n.of(context).setStatus,
      message: L10n.of(context).leaveEmptyToClearStatus,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).statusExampleMessage,
      maxLines: 6,
      minLines: 1,
      maxLength: 255,
      initialText: currentPresence.statusMsg,
    );
    if (input == null) return;
    if (!mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: () => client.setPresence(
        client.userID!,
        PresenceType.online,
        statusMsg: input,
      ),
    );
  }

  bool waitForFirstSync = false;

  Future<void> _waitForFirstSync() async {
    final router = GoRouter.of(context);
    final client = Matrix.of(context).client;
    await client.roomsLoading;
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    if (client.prevBatch == null) {
      await client.onSyncStatus.stream.firstWhere(
        (status) => status.status == SyncStatus.finished,
      );

      if (!mounted) return;
      setState(() {
        waitForFirstSync = true;
      });
    }
    if (!mounted) return;
    setState(() {
      waitForFirstSync = true;
    });

    if (client.userDeviceKeys[client.userID!]?.deviceKeys.values.any(
          (device) => !device.verified && !device.blocked,
        ) ??
        false) {
      late final ScaffoldFeatureController controller;
      final theme = Theme.of(context);
      controller = ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 15),
          showCloseIcon: true,
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            L10n.of(context).oneOfYourDevicesIsNotVerified,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          action: SnackBarAction(
            onPressed: () {
              controller.close();
              router.go('/rooms/settings/devices');
            },
            textColor: theme.colorScheme.onErrorContainer,
            label: L10n.of(context).settings,
          ),
        ),
      );
    }
  }

  void setActiveFilter(ActiveFilter filter) {
    setState(() {
      activeFilter = filter;
    });
  }

  void setActiveClient(Client client) {
    context.go('/rooms');
    // Le profil mémorisé par l'AppBar appartient au compte précédent.
    resetOwnProfileCache();
    setState(() {
      activeFilter = ActiveFilter.allChats;
      _activeSpaceId = null;
      Matrix.of(context).setActiveClient(client);
    });
    _clientStream.add(client);
  }

  void setActiveBundle(String bundle) {
    context.go('/rooms');
    // Le bundle peut changer le client actif : même invalidation de profil.
    resetOwnProfileCache();
    setState(() {
      _activeSpaceId = null;
      Matrix.of(context).activeBundle = bundle;
      if (!Matrix.of(
        context,
      ).currentBundle!.any((client) => client == Matrix.of(context).client)) {
        Matrix.of(
          context,
        ).setActiveClient(Matrix.of(context).currentBundle!.first);
      }
    });
  }

  Future<void> editBundlesForAccount(
    String? userId,
    String? activeBundle,
  ) async {
    final l10n = L10n.of(context);
    final client = Matrix.of(
      context,
    ).widget.clients[Matrix.of(context).getClientIndexByMatrixId(userId!)];
    final action = await showModalActionPopup<EditBundleAction>(
      context: context,
      title: L10n.of(context).editBundlesForAccount,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: EditBundleAction.addToBundle,
          label: L10n.of(context).addToBundle,
        ),
        if (activeBundle != client.userID)
          AdaptiveModalAction(
            value: EditBundleAction.removeFromBundle,
            label: L10n.of(context).removeFromBundle,
          ),
      ],
    );
    if (action == null) return;
    switch (action) {
      case EditBundleAction.addToBundle:
        final bundle = await showTextInputDialog(
          context: context,
          title: l10n.bundleName,
          hintText: l10n.bundleName,
        );
        if (bundle == null || bundle.isEmpty || bundle.isEmpty) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => client.setAccountBundle(bundle),
        );
        break;
      case EditBundleAction.removeFromBundle:
        await showFutureLoadingDialog(
          context: context,
          future: () => client.removeFromAccountBundle(activeBundle!),
        );
    }
  }

  bool get displayBundles =>
      Matrix.of(context).hasComplexBundles &&
      Matrix.of(context).accountBundles.keys.length > 1;

  String? get secureActiveBundle {
    if (Matrix.of(context).activeBundle == null ||
        !Matrix.of(
          context,
        ).accountBundles.keys.contains(Matrix.of(context).activeBundle)) {
      return Matrix.of(context).accountBundles.keys.first;
    }
    return Matrix.of(context).activeBundle;
  }

  void resetActiveBundle() {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        Matrix.of(context).activeBundle = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) => ChatListView(this);

  void _hackyWebRTCFixForWeb() {
    ChatList.contextForVoip = context;
  }

  Future<void> dehydrate() => Matrix.of(context).dehydrateAction(context);
}

enum EditBundleAction { addToBundle, removeFromBundle }

enum ChatContextAction {
  open,
  goToSpace,
  favorite,
  lowPriority,
  markUnread,
  mute,
  lock,
  leave,
  addToSpace,
  block,
}

enum _InviteAction { accept, decline, block }
