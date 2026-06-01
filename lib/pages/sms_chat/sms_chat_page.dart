import 'dart:async';
import 'dart:io';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/chat/chat_date_separator.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/cyber/scheduled_send.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:image_picker/image_picker.dart';
import 'package:linkify/linkify.dart' show PhoneNumberLinkifier;
import 'package:url_launcher/url_launcher_string.dart';

/// CYBERCORE SMS conversation screen.
///
/// Renders a single SMS thread end to end **without** the Matrix SDK — it talks
/// straight to [SmsBridge] (native Telephony provider). Bubbles mimic the chat
/// look (gradient cyan→magenta for own / glass for inbound) with a tail, a
/// hairline violet edge inbound, inline date separators, Google-Messages-style
/// timestamp grouping and clickable links — but are simple, self-contained
/// widgets — no Matrix [Timeline] coupling.
///
/// Defensive by design: empty lists are fine, native errors already return safe
/// defaults from [SmsBridge], and every animation is bounded + reduce-motion
/// aware.
class SmsChatPage extends StatefulWidget {
  final String threadId;
  final String address;
  final String? displayName;

  const SmsChatPage({
    required this.threadId,
    required this.address,
    this.displayName,
    super.key,
  });

  @override
  State<SmsChatPage> createState() => _SmsChatPageState();
}

class _SmsChatPageState extends State<SmsChatPage> {
  /// Telephony `Sms.Type` constants (android.provider.Telephony.TextBasedSmsColumns).
  static const int _typeSent = 2;
  static const int _typeOutbox = 4;
  static const int _typeFailed = 5;
  static const int _typeQueued = 6;

  /// Synthetic local id prefix for optimistic (not-yet-persisted) bubbles.
  static const String _optimisticPrefix = 'optimistic-';

  /// Prefix for synthetic ids built from the live incoming stream (never a real
  /// provider row, so deletion is local-only).
  static const String _incomingPrefix = 'incoming-';

  final List<SmsMessage> _messages = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ImagePicker _picker = ImagePicker();

  /// Cache of resolved MMS image part paths (partId → local path / null when the
  /// native extraction failed). Shared across bubbles so a rebuild never
  /// re-triggers [SmsBridge.loadMmsPart].
  final Map<int, String?> _mmsPartCache = {};

  /// Optimistic (locally-sent) image attachments keyed by their synthetic
  /// negative partId → on-disk path of the picked image.
  final Map<int, String> _localOptimisticPaths = {};

  StreamSubscription<SmsIncoming>? _incomingSub;
  bool _loading = true;
  bool _sending = false;
  bool _hasText = false;

  /// Path of the image queued in the composer (null = text-only send).
  String? _pendingImagePath;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _composerFocus.addListener(_onFocusChanged);
    _load();
    _listenIncoming();
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _composerFocus.removeListener(_onFocusChanged);
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onComposerChanged() {
    final hasText = _composer.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onFocusChanged() {
    // Focus changes recolor the composer border; rebuild to reflect it.
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final messages = await SmsBridge.instance.listMessages(widget.threadId);
    // Mark the thread read in the background; result is irrelevant to the UI.
    unawaited(SmsBridge.instance.markRead(widget.threadId));
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
      _sortMessages();
      _loading = false;
    });
    _scrollToBottom(animated: false);
  }

  void _listenIncoming() {
    _incomingSub = SmsBridge.instance.incoming.listen((sms) {
      if (!mounted) return;
      // Only react to SMS belonging to this thread (or, as a fallback when the
      // native side omits the threadId, the same address).
      final sameThread =
          sms.threadId.isNotEmpty && sms.threadId == widget.threadId;
      final sameAddress = _normalize(sms.address) == _normalize(widget.address);
      if (!sameThread && !sameAddress) return;

      setState(() {
        _messages.add(
          SmsMessage(
            id: '$_incomingPrefix${sms.date}-${_messages.length}',
            address: sms.address,
            body: sms.body,
            date: sms.date,
            isFromMe: false,
            type: 1, // TYPE_INBOX
            status: -1,
            read: true,
          ),
        );
        _sortMessages();
      });
      unawaited(SmsBridge.instance.markRead(widget.threadId));
      _scrollToBottom();
    });
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    final imagePath = _pendingImagePath;
    final hasImage = imagePath != null && imagePath.isNotEmpty;
    // Nothing to do when there's neither text nor an image, or a send is busy.
    if ((body.isEmpty && !hasImage) || _sending) return;

    final optimisticId =
        '$_optimisticPrefix${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = SmsMessage(
      id: optimisticId,
      address: widget.address,
      body: body,
      date: DateTime.now().millisecondsSinceEpoch,
      isFromMe: true,
      type: _typeQueued,
      status: -1,
      read: true,
      isMms: hasImage,
      attachments: hasImage
          ? [
              // Synthetic local attachment: negative partId so it never collides
              // with a real provider part and resolves straight to the local file
              // via [_localOptimisticPaths].
              SmsAttachment(
                partId: -DateTime.now().microsecondsSinceEpoch,
                mimeType: 'image/*',
                fileName: 'pending',
              ),
            ]
          : const [],
    );

    if (hasImage) {
      _localOptimisticPaths[optimistic.images.first.partId] = imagePath;
    }

    setState(() {
      _sending = true;
      _messages.add(optimistic);
      _sortMessages();
      _composer.clear();
      _hasText = false;
      _pendingImagePath = null;
    });
    _scrollToBottom();

    final int? rowId;
    if (hasImage) {
      rowId = await SmsBridge.instance.sendMms(
        widget.address,
        body.isEmpty ? null : body,
        imagePath,
      );
    } else {
      rowId = await SmsBridge.instance.sendSms(widget.address, body);
    }
    if (!mounted) return;

    setState(() {
      _sending = false;
      final index = _messages.indexWhere((m) => m.id == optimistic.id);
      if (index == -1) return;
      _messages[index] = SmsMessage(
        id: rowId != null ? '$rowId' : optimistic.id,
        address: optimistic.address,
        body: optimistic.body,
        date: optimistic.date,
        isFromMe: true,
        type: rowId != null ? _typeSent : _typeFailed,
        status: optimistic.status,
        read: true,
        isMms: optimistic.isMms,
        attachments: optimistic.attachments,
      );
    });
  }

  /// Long-press on the send button: queue the typed text as a scheduled SMS for
  /// later delivery instead of sending it now. Text-only (no MMS scheduling).
  Future<void> _schedule() async {
    final body = _composer.text.trim();
    if (body.isEmpty) return;
    final when = await ScheduledSend.pickDateTime(context);
    if (when == null || !mounted) return;
    final sendAt = when.millisecondsSinceEpoch;
    await ScheduledMessages.instance.schedule(
      ScheduledMessage(
        id: ScheduledSend.nextId(sendAt: sendAt, body: body),
        body: body,
        sendAt: sendAt,
        smsAddress: widget.address,
      ),
    );
    if (!mounted) return;
    setState(() {
      _composer.clear();
      _hasText = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Message programmé pour ${ScheduledSend.formatWhen(when)}'),
      ),
    );
  }

  /// Picks an image from the gallery and queues it in the composer. Defensive:
  /// a cancelled picker (null) leaves the composer untouched.
  Future<void> _pickImage() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (!mounted || file == null) return;
      setState(() => _pendingImagePath = file.path);
    } catch (_) {
      // Picker can throw on some OEMs (no gallery app, permission denied). Stay
      // silent — the user simply gets no image queued.
    }
  }

  void _clearPendingImage() {
    if (_pendingImagePath == null) return;
    setState(() => _pendingImagePath = null);
  }

  /// Resolves an MMS image part path, memoising the result so a rebuild never
  /// re-extracts. Local optimistic attachments short-circuit to their file path.
  Future<String?> _resolveMmsPart(int partId) async {
    final local = _localOptimisticPaths[partId];
    if (local != null) return local;
    if (_mmsPartCache.containsKey(partId)) return _mmsPartCache[partId];
    final path = await SmsBridge.instance.loadMmsPart(partId);
    if (mounted) _mmsPartCache[partId] = path;
    return path;
  }

  /// Opens an URL / phone link from a tapped message body. SMS bodies carry
  /// plain external links (shop URLs, `tel:` numbers) — no Matrix deep-link
  /// handling needed, so we launch straight through the OS.
  Future<void> _openLink(LinkableElement link) async {
    try {
      await launchUrlString(link.url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir ce lien')),
      );
    }
  }

  /// Long-press on a bubble → CYBERCORE action sheet (copy / delete).
  Future<void> _onMessageLongPress(SmsMessage message) async {
    HapticFeedback.selectionClick();
    final cyber = CyberColors.of(context);
    final action = await showModalBottomSheet<_MessageAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _MessageActionSheet(
        cyber: cyber,
        canCopy: message.body.isNotEmpty,
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.body));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Texte copié')),
        );
      case _MessageAction.delete:
        await _deleteMessage(message);
    }
  }

  /// Deletes a single message: removes it from the native provider (when it is a
  /// real provider row, i.e. not optimistic/incoming-synthetic) then drops it
  /// from the local list. Local-only bubbles are simply removed.
  Future<void> _deleteMessage(SmsMessage message) async {
    final realId = int.tryParse(message.id);
    final isSynthetic = message.id.startsWith(_optimisticPrefix) ||
        message.id.startsWith(_incomingPrefix);
    if (realId != null && !isSynthetic) {
      await SmsBridge.instance.deleteMessage(realId, isMms: message.isMms);
    }
    if (!mounted) return;
    setState(() => _messages.removeWhere((m) => m.id == message.id));
  }

  /// Header menu → "Supprimer la conversation". Confirms, deletes the whole
  /// thread natively, then pops back to the chat list.
  Future<void> _deleteConversation() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ConfirmDeleteSheet(
        cyber: CyberColors.of(context),
        title: 'Supprimer la conversation ?',
        message:
            'Tous les messages de ce fil seront définitivement supprimés.',
      ),
    );
    if (confirmed != true || !mounted) return;
    await SmsBridge.instance.deleteConversation(widget.threadId);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _sortMessages() {
    _messages.sort((a, b) => a.date.compareTo(b.date));
  }

  void _scrollToBottom({bool animated = true}) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (!animated || reduce) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: FluffyDurations.medium,
          curve: FluffyCurves.decelerated,
        );
      }
    });
  }

  /// Strips spaces/punctuation so `+33 6 12` and `0612` compare loosely. Cheap
  /// best-effort match for the incoming-stream fallback only.
  String _normalize(String address) =>
      address.replaceAll(RegExp(r'[\s\-().]'), '');

  String get _title {
    final name = widget.displayName;
    if (name != null && name.isNotEmpty) return name;
    return widget.address;
  }

  /// Subtitle below the header title: "MMS" when any message carries an image,
  /// otherwise "SMS".
  String get _subtitle =>
      _messages.any((m) => m.isMms && m.images.isNotEmpty) ? 'MMS' : 'SMS';

  String _initial() {
    final source = _title.trim();
    if (source.isEmpty) return '#';
    final first = source[0];
    return RegExp(r'[A-Za-z0-9]').hasMatch(first) ? first.toUpperCase() : '#';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: _buildAppBar(theme, cyber),
      body: Column(
        children: [
          Expanded(child: _buildBody(theme, cyber)),
          _buildComposer(theme, cyber),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ThemeData theme, CyberpunkTheme cyber) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [cyber.cyan, cyber.magenta],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: FluffyElevation.glowCyan(cyber.cyan, alpha: 0.3),
            ),
            child: Text(
              _initial(),
              style: FluffyTypography.title.copyWith(
                color: Colors.black,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: FluffySpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FluffyTypography.headlineM.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  _subtitle,
                  style: FluffyTypography.labelM.copyWith(
                    color: cyber.cyan,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        PopupMenuButton<String>(
          icon: Icon(
            Icons.more_vert_rounded,
            color: theme.colorScheme.onSurface,
          ),
          color: theme.colorScheme.surfaceContainerHigh,
          shape: const RoundedRectangleBorder(
            borderRadius: FluffyRadius.brMd,
          ),
          onSelected: (value) {
            if (value == 'delete') _deleteConversation();
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'delete',
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline_rounded,
                    color: cyber.magenta,
                    size: 20,
                  ),
                  const SizedBox(width: FluffySpacing.md),
                  Text(
                    'Supprimer la conversation',
                    style: FluffyTypography.bodyM.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(width: FluffySpacing.xs),
      ],
    );
  }

  Widget _buildBody(ThemeData theme, CyberpunkTheme cyber) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: cyber.cyan, strokeWidth: 2),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FluffySpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sms_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: FluffySpacing.lg),
              Text(
                'Aucun message pour l’instant',
                textAlign: TextAlign.center,
                style: FluffyTypography.bodyM.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.sm),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final previous = index > 0 ? _messages[index - 1] : null;
        final next =
            index < _messages.length - 1 ? _messages[index + 1] : null;
        // New calendar day → inline date separator above the bubble.
        final showDateSeparator =
            previous == null || !_sameDay(previous.date, message.date);
        // Google-Messages grouping: show the timestamp only on a sender change,
        // a >5 min gap, or right after a date separator.
        final showTimestamp = showDateSeparator ||
            (message.date - previous.date).abs() > 5 * 60 * 1000 ||
            previous.isFromMe != message.isFromMe;
        // Matrix-style grouping. The list is chronological (oldest at top), so
        // "previous" is the older neighbour and "next" the newer one. A group
        // breaks on a sender change, a >5 min gap, or a day change — the same
        // break that drives [showTimestamp], mirroring Matrix's `displayTime`
        // controlling `nextEventSameSender`.
        const groupGapMs = 5 * 60 * 1000;
        final previousSameSender = previous != null &&
            previous.isFromMe == message.isFromMe &&
            !showDateSeparator &&
            (message.date - previous.date).abs() <= groupGapMs;
        final nextSameSender = next != null &&
            next.isFromMe == message.isFromMe &&
            _sameDay(message.date, next.date) &&
            (next.date - message.date).abs() <= groupGapMs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showDateSeparator)
              ChatDateSeparator(
                date: DateTime.fromMillisecondsSinceEpoch(message.date),
              ),
            _SmsBubble(
              message: message,
              cyber: cyber,
              theme: theme,
              showTimestamp: showTimestamp,
              previousSameSender: previousSameSender,
              nextSameSender: nextSameSender,
              senderInitial: _initial(),
              senderName: _title,
              resolveImagePath: _resolveMmsPart,
              onOpenLink: _openLink,
              onLongPress: () => _onMessageLongPress(message),
            ),
          ],
        );
      },
    );
  }

  Widget _buildComposer(ThemeData theme, CyberpunkTheme cyber) {
    final hasImage = _pendingImagePath != null;
    final canSend = (_hasText || hasImage) && !_sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FluffySpacing.md,
          FluffySpacing.sm,
          FluffySpacing.md,
          FluffySpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ScheduledBanner(
              selector: () => ScheduledMessages.instance.forSms(widget.address),
            ),
            if (hasImage)
              _PendingImagePreview(
                path: _pendingImagePath!,
                cyber: cyber,
                onRemove: _clearPendingImage,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _AttachButton(
                  cyber: cyber,
                  enabled: !_sending,
                  onPressed: _sending ? null : _pickImage,
                ),
                const SizedBox(width: FluffySpacing.sm),
                Expanded(
                  child: CyberField(
                    focused: _composerFocus.hasFocus,
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      cursorColor: cyber.cyan,
                      style: FluffyTypography.bodyL.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: 'Écrivez un SMS…',
                        hintStyle: FluffyTypography.bodyL.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: FluffySpacing.sm),
                _SendButton(
                  cyber: cyber,
                  enabled: canSend,
                  loading: _sending,
                  onPressed: canSend ? _send : null,
                  onLongPress: _hasText && !_sending ? _schedule : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// True when two epoch-millis timestamps fall on the same calendar day.
  static bool _sameDay(int a, int b) {
    final da = DateTime.fromMillisecondsSinceEpoch(a);
    final db = DateTime.fromMillisecondsSinceEpoch(b);
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }
}

/// A single SMS bubble: gradient cyan→magenta + right-aligned for own messages
/// (tail bottom-right), glass + hairline-violet + left-aligned for inbound
/// (tail bottom-left). Body text is linkified (URLs + phone numbers), shows a
/// discreet timestamp and (for own messages) a small send/fail status line.
class _SmsBubble extends StatelessWidget {
  final SmsMessage message;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final bool showTimestamp;

  /// Matrix-style grouping flags: whether the older / newer neighbour shares
  /// the same sender (and day). Drive the hard-corner "tail" geometry and the
  /// inbound avatar+name header so consecutive bubbles read as one block —
  /// pixel-identical to [Message] in the Matrix timeline.
  final bool previousSameSender;
  final bool nextSameSender;

  /// Single-letter initial + display name/number for the inbound avatar header
  /// (shown only at the top of an inbound group, like Matrix).
  final String senderInitial;
  final String senderName;

  final Future<String?> Function(int partId) resolveImagePath;
  final Future<void> Function(LinkableElement link) onOpenLink;
  final VoidCallback onLongPress;

  const _SmsBubble({
    required this.message,
    required this.cyber,
    required this.theme,
    required this.showTimestamp,
    required this.previousSameSender,
    required this.nextSameSender,
    required this.senderInitial,
    required this.senderName,
    required this.resolveImagePath,
    required this.onOpenLink,
    required this.onLongPress,
  });

  /// URL + email (defaults) + phone number detection inside SMS bodies.
  static const List<Linkifier> _linkifiers = [
    UrlLinkifier(),
    EmailLinkifier(),
    PhoneNumberLinkifier(),
  ];

  bool get _failed => message.type == _SmsChatPageState._typeFailed;
  bool get _pending =>
      message.type == _SmsChatPageState._typeQueued ||
      message.type == _SmsChatPageState._typeOutbox;

  /// Matrix bubble geometry: [AppConfig.borderRadius] everywhere, hard 4px
  /// corner on the tail side for grouped neighbours. [Message] uses
  /// `nextEventSameSender` for the top corner and `previousEventSameSender` for
  /// the bottom. In our chronological list that maps to: top hardens when the
  /// older neighbour matches, bottom when the newer one does.
  BorderRadius _bubbleRadius(bool own) {
    const hard = Radius.circular(4);
    const round = Radius.circular(AppConfig.borderRadius);
    return BorderRadius.only(
      topLeft: !own && previousSameSender ? hard : round,
      topRight: own && previousSameSender ? hard : round,
      bottomLeft: !own && nextSameSender ? hard : round,
      bottomRight: own && nextSameSender ? hard : round,
    );
  }

  @override
  Widget build(BuildContext context) {
    final own = message.isFromMe;
    final align = own ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubble = own ? _ownBubble(context) : _inboundBubble(context);
    // Avatar + sender name header at the top of an inbound group only — mirrors
    // Message.dart's `!nextEventSameSender` header. The bubble below aligns
    // under the name, not offset by the avatar (full-width inbound layout).
    final showInboundHeader = !own && !previousSameSender;
    return Padding(
      // Matrix spacing: tight 1px between grouped bubbles, 4px between groups
      // (Message wraps each row in top/bottom 1|4 padding → ~2|8 cumulative).
      padding: EdgeInsets.only(
        top: previousSameSender ? FluffySpacing.xxs : FluffySpacing.xs,
        bottom: nextSameSender ? FluffySpacing.xxs : FluffySpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (showInboundHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _SenderAvatar(initial: senderInitial, cyber: cyber),
                  const SizedBox(width: 10.0),
                  Expanded(
                    child: Text(
                      senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: FluffyTypography.inter,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ConstrainedBox(
            // Matrix bubble cap: columnWidth * 1.5 (= 570dp). On mobile this is
            // wider than the viewport so the bubble effectively spans the row,
            // matching Message.dart instead of the old 80% clamp.
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.columnWidth * 1.5,
            ),
            child: GestureDetector(
              onLongPress: onLongPress,
              child: bubble,
            ),
          ),
          if (showTimestamp || own) ...[
            const SizedBox(height: FluffySpacing.xxs),
            _metaLine(),
          ],
        ],
      ),
    );
  }

  Widget _ownBubble(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _failed
              ? [
                  cyber.magenta.withValues(alpha: 0.55),
                  cyber.magenta.withValues(alpha: 0.35),
                ]
              : [cyber.cyan, cyber.magenta],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: _bubbleRadius(true),
      ),
      child: Opacity(
        opacity: _pending ? 0.75 : 1,
        child: _bubbleContent(
          context,
          textColor: Colors.black,
          linkColor: Colors.black,
          textWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _inboundBubble(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cyber.glassFillLight,
        borderRadius: _bubbleRadius(false),
        border: Border.all(color: cyber.violet.withValues(alpha: 0.35)),
      ),
      child: _bubbleContent(
        context,
        textColor: theme.colorScheme.onSurface,
        linkColor: cyber.cyan,
      ),
    );
  }

  /// Bubble interior: stacks image attachments (when any) above the text body.
  /// The text padding is dropped entirely when [message.body] is empty so an
  /// image-only MMS keeps tight rounded corners. Body text is linkified: URLs
  /// and phone numbers become tappable (cyan inbound / black own).
  Widget _bubbleContent(
    BuildContext context, {
    required Color textColor,
    required Color linkColor,
    FontWeight? textWeight,
  }) {
    final images = message.images;
    final hasText = message.body.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < images.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: hasText || i < images.length - 1 ? FluffySpacing.xs : 0,
            ),
            child: _MmsImage(
              partId: images[i].partId,
              cyber: cyber,
              theme: theme,
              resolveImagePath: resolveImagePath,
            ),
          ),
        if (hasText)
          Padding(
            // Same interior padding as the Matrix bubble (16 / 8).
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.sm,
            ),
            child: Linkify(
              text: message.body,
              linkifiers: _linkifiers,
              options: const LinkifyOptions(humanize: false),
              onOpen: onOpenLink,
              // Match the Matrix bubble exactly: same base font size honoring
              // the user's text-size setting (fontSizeFactor) so SMS and Matrix
              // bubbles read identically.
              style: TextStyle(
                fontFamily: FluffyTypography.inter,
                fontSize: AppConfig.messageFontSize *
                    AppSettings.fontSizeFactor.value,
                height: 1.25,
                color: textColor,
                fontWeight: textWeight,
              ),
              linkStyle: TextStyle(
                fontFamily: FluffyTypography.inter,
                fontSize: AppConfig.messageFontSize *
                    AppSettings.fontSizeFactor.value,
                height: 1.25,
                color: linkColor,
                fontWeight: textWeight,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
            ),
          ),
      ],
    );
  }

  Widget _metaLine() {
    final muted = theme.colorScheme.onSurfaceVariant;
    final time = _formatTime(message.date);
    if (!message.isFromMe) {
      return Text(time, style: FluffyTypography.labelM.copyWith(color: muted));
    }
    final String statusLabel;
    final Color statusColor;
    if (_failed) {
      statusLabel = 'Non délivré';
      statusColor = cyber.magenta;
    } else if (_pending) {
      statusLabel = 'Envoi…';
      statusColor = muted;
    } else {
      statusLabel = 'Envoyé';
      statusColor = cyber.success;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTimestamp) ...[
          Text(time, style: FluffyTypography.labelM.copyWith(color: muted)),
          const SizedBox(width: FluffySpacing.xs),
        ],
        Icon(
          _failed
              ? Icons.error_outline_rounded
              : _pending
                  ? Icons.schedule_rounded
                  : Icons.check_rounded,
          size: 12,
          color: statusColor,
        ),
        const SizedBox(width: FluffySpacing.xxs),
        Text(
          statusLabel,
          style: FluffyTypography.labelM.copyWith(color: statusColor),
        ),
      ],
    );
  }

  String _formatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// 36dp gradient avatar with the sender initial, shown inline next to the
/// sender name at the top of an inbound group. Matches the Matrix [Avatar]
/// footprint (size 36) and the AppBar avatar styling so SMS headers and Matrix
/// headers are visually identical.
class _SenderAvatar extends StatelessWidget {
  final String initial;
  final CyberpunkTheme cyber;

  const _SenderAvatar({required this.initial, required this.cyber});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [cyber.cyan, cyber.magenta],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        initial,
        style: FluffyTypography.title.copyWith(
          color: Colors.black,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// CYBERCORE long-press action sheet for a message (copy / delete).
class _MessageActionSheet extends StatelessWidget {
  final CyberpunkTheme cyber;
  final bool canCopy;

  const _MessageActionSheet({required this.cyber, required this.canCopy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(FluffySpacing.md),
        child: CyberGlass(
          tint: cyber.glassFillStrong,
          padding: const EdgeInsets.symmetric(vertical: FluffySpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canCopy)
                _SheetTile(
                  icon: Icons.copy_rounded,
                  label: 'Copier le texte',
                  color: cyber.cyan,
                  onTap: () =>
                      Navigator.of(context).pop(_MessageAction.copy),
                ),
              _SheetTile(
                icon: Icons.delete_outline_rounded,
                label: 'Supprimer',
                color: cyber.magenta,
                onTap: () => Navigator.of(context).pop(_MessageAction.delete),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluffySpacing.lg,
                  vertical: FluffySpacing.xs,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Annuler',
                      style: FluffyTypography.labelL.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
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

/// CYBERCORE confirmation sheet (destructive). Returns true on confirm.
class _ConfirmDeleteSheet extends StatelessWidget {
  final CyberpunkTheme cyber;
  final String title;
  final String message;

  const _ConfirmDeleteSheet({
    required this.cyber,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(FluffySpacing.md),
        child: CyberGlass(
          tint: cyber.glassFillStrong,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: FluffyTypography.headlineM.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: FluffySpacing.sm),
              Text(
                message,
                style: FluffyTypography.bodyM.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: FluffySpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(
                        'Annuler',
                        style: FluffyTypography.labelL.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: FluffySpacing.sm),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cyber.magenta.withValues(alpha: 0.16),
                        borderRadius: FluffyRadius.brMd,
                        border: Border.all(
                          color: cyber.magenta.withValues(alpha: 0.5),
                        ),
                      ),
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(
                          'Supprimer',
                          style: FluffyTypography.labelL.copyWith(
                            color: cyber.magenta,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tappable row inside a CYBERCORE action sheet.
class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: FluffyRadius.brMd,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.lg,
            vertical: FluffySpacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: FluffySpacing.lg),
              Text(
                label,
                style: FluffyTypography.bodyL.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actions surfaced by the bubble long-press sheet.
enum _MessageAction { copy, delete }

/// Gradient circular send button matching [CyberPrimaryButton]'s look, sized for
/// the composer. Dims + disables when there's nothing to send.
class _SendButton extends StatelessWidget {
  final CyberpunkTheme cyber;
  final bool enabled;
  final bool loading;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  const _SendButton({
    required this.cyber,
    required this.enabled,
    required this.loading,
    required this.onPressed,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled || loading ? 1 : 0.4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [cyber.cyan, cyber.magenta],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: enabled
              ? FluffyElevation.glowMagenta(cyber.magenta, alpha: 0.4)
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            onLongPress: onLongPress,
            child: SizedBox(
              width: 48,
              height: 48,
              child: loading
                  ? const Padding(
                      padding: EdgeInsets.all(FluffySpacing.md),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(
                      Icons.send_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Composer attach button (image picker trigger). Cyan-accented, matches the
/// send button footprint so the row stays visually balanced.
class _AttachButton extends StatelessWidget {
  final CyberpunkTheme cyber;
  final bool enabled;
  final VoidCallback? onPressed;

  const _AttachButton({
    required this.cyber,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              Icons.add_photo_alternate_outlined,
              color: cyber.cyan,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumbnail preview of the image queued in the composer, with a magenta close
/// chip to cancel it.
class _PendingImagePreview extends StatelessWidget {
  final String path;
  final CyberpunkTheme cyber;
  final VoidCallback onRemove;

  const _PendingImagePreview({
    required this.path,
    required this.cyber,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: FluffySpacing.xs,
        bottom: FluffySpacing.sm,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: FluffyRadius.brMd,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: FluffyRadius.brMd,
                border: Border.all(color: cyber.cyan.withValues(alpha: 0.6)),
              ),
              child: ClipRRect(
                borderRadius: FluffyRadius.brMd,
                child: Image.file(
                  File(path),
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  errorBuilder: (context, _, _) => Container(
                    width: 84,
                    height: 84,
                    color: cyber.glassFillLight,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: cyber.magenta,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: -8,
            right: -8,
            child: Material(
              color: cyber.magenta,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onRemove,
                child: const SizedBox(
                  width: 24,
                  height: 24,
                  child:
                      Icon(Icons.close_rounded, size: 16, color: Colors.black),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single MMS image attachment inside a bubble. Resolves its local path lazily
/// via [resolveImagePath] (memoised at the State level), shows a cyan loader
/// while resolving, a fallback icon on null/error, and opens a full-screen
/// zoomable viewer on tap.
class _MmsImage extends StatelessWidget {
  final int partId;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final Future<String?> Function(int partId) resolveImagePath;

  const _MmsImage({
    required this.partId,
    required this.cyber,
    required this.theme,
    required this.resolveImagePath,
  });

  static const double _maxHeight = 240;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: FluffyRadius.brMd,
      child: FutureBuilder<String?>(
        future: resolveImagePath(partId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _placeholder(
              child: CircularProgressIndicator(
                color: cyber.cyan,
                strokeWidth: 2,
              ),
            );
          }
          final path = snapshot.data;
          if (snapshot.hasError || path == null || path.isEmpty) {
            return _placeholder(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: theme.colorScheme.onSurfaceVariant,
                size: 32,
              ),
            );
          }
          return GestureDetector(
            onTap: () => _openViewer(context, path),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxHeight),
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                width: double.infinity,
                errorBuilder: (context, _, _) => _placeholder(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: cyber.magenta,
                    size: 32,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _placeholder({required Widget child}) {
    return Container(
      height: 160,
      width: double.infinity,
      color: cyber.glassFillLight,
      alignment: Alignment.center,
      child: child,
    );
  }

  void _openViewer(BuildContext context, String path) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: reduce ? Duration.zero : FluffyDurations.medium,
        reverseTransitionDuration:
            reduce ? Duration.zero : FluffyDurations.fast,
        pageBuilder: (_, _, _) => _MmsImageViewer(path: path, cyber: cyber),
      ),
    );
  }
}

/// Full-screen, pinch-to-zoom viewer for a single MMS image. Black backdrop +
/// a cyan close button.
class _MmsImageViewer extends StatelessWidget {
  final String path;
  final CyberpunkTheme cyber;

  const _MmsImageViewer({required this.path, required this.cyber});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (context, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: cyber.magenta,
                    size: 64,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(FluffySpacing.sm),
                child: Material(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.close_rounded, color: cyber.cyan),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
