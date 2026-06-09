import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chewie/chewie.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat_date_separator.dart';
import 'package:fluffychat/pages/chat/events/swipe_to_reply.dart';
import 'package:fluffychat/utils/ephemeral/ephemeral_messages.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/utils/sms/map_linkifier.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/chat_bubble_skin.dart';
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/cyber/ephemeral_picker.dart';
import 'package:fluffychat/widgets/cyber/link_preview_card.dart';
import 'package:fluffychat/widgets/cyber/scheduled_send.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:glow_effects/glow_effects.dart';
import 'package:image_picker/image_picker.dart';
import 'package:linkify/linkify.dart' show PhoneNumberLinkifier;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:video_player/video_player.dart';

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

  /// Local path of the contact's photo (same one the conversation list shows),
  /// or null. Used for the room app-bar avatar so it matches the list.
  final String? photoPath;

  /// When true (opened from a notification's Voice action), focus the composer
  /// and prompt the user to dictate via the keyboard mic on first frame.
  final bool startVoiceReply;

  const SmsChatPage({
    required this.threadId,
    required this.address,
    this.displayName,
    this.photoPath,
    this.startVoiceReply = false,
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

  /// Composer row height — matches the Matrix ChatInputRow.height (56dp) so the
  /// SMS composer footprint is identical.
  static const double _composerRowHeight = 56.0;

  /// App bar height — matches ChatLiquidGlassAppBar._kAppBarHeight (64dp).
  static const double _kSmsAppBarHeight = 64.0;

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
  final Map<int, Future<String?>> _mmsFutures = {};

  /// Optimistic (locally-sent) image attachments keyed by their synthetic
  /// negative partId → on-disk path of the picked image.
  final Map<int, String> _localOptimisticPaths = {};

  StreamSubscription<SmsIncoming>? _incomingSub;
  bool _loading = true;

  /// Generation token for the "keep pinned to the bottom" retry loop. Bumped on
  /// every new _scrollToBottom so a stale retry chain from a previous call (or
  /// after the user manually scrolled) stops re-pinning.
  int _stickGeneration = 0;
  bool _sending = false;
  bool _hasText = false;

  /// Path of the image queued in the composer (null = text-only send).
  String? _pendingImagePath;

  /// One-shot per-message disappearing override, consumed on the next send.
  EphemeralDuration? _pendingEphemeralOverride;

  /// Monotonic counter for synthetic ids of stream-incoming messages. Using
  /// `_messages.length` was unsafe: after a delete the length rewinds and a new
  /// incoming could reuse an id, so a later removeWhere would drop two bubbles.
  int _incomingSeq = 0;

  /// Id of the bubble that should play the slide-up + fade-in on first build
  /// (the just-sent or just-received message). Cleared shortly after so a bubble
  /// scrolled off and back doesn't re-animate. Matches Matrix's _AnimateIn.
  String? _animateInId;
  Timer? _animateInClear;

  /// Schedules clearing [_animateInId] once the entry animation has played, so a
  /// bubble scrolled off and back doesn't re-trigger it. Call right after the
  /// setState that sets _animateInId.
  void _scheduleAnimateInClear(String id) {
    _animateInClear?.cancel();
    _animateInClear = Timer(const Duration(milliseconds: 400), () {
      if (mounted && _animateInId == id) setState(() => _animateInId = null);
    });
  }

  /// True when the list is scrolled up far enough to warrant a jump-to-bottom
  /// button (the list grows downward, so "down" = toward newest).
  bool _showScrollDown = false;

  /// Mirrors the Matrix composer's emoji toggle: when true the inline emoji
  /// panel is shown below the input row and the leading emoji button flips to a
  /// keyboard icon.
  bool _showEmoji = false;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _scroll.addListener(_onScroll);
    // Mark this thread as on-screen (no notif while open) and clear any pending
    // notification + unread badge for it.
    SmsBridge.instance.setActiveThread(widget.threadId);
    SmsBridge.instance.cancelNotification(widget.threadId);
    _load();
    _listenIncoming();
    if (widget.startVoiceReply) {
      // Voice action from the notification: focus the composer and invite the
      // user to dictate via the keyboard mic. (Full server-side STT will plug in
      // once the Whisper backend is exposed.)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _composerFocus.requestFocus();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dictez votre réponse 🎤')),
        );
      });
    }
  }

  @override
  void dispose() {
    // No longer on screen: let notifications fire for this thread again.
    SmsBridge.instance.setActiveThread(null);
    _incomingSub?.cancel();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _animateInClear?.cancel();
    super.dispose();
  }

  void _onComposerChanged() {
    final hasText = _composer.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  /// Taille de la première page et des pages suivantes (pagination SMS pour
  /// ouvrir instantanément les longues conversations).
  static const int _pageSize = 50;
  bool _hasMore = true;
  bool _loadingMore = false;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // > 240px above the bottom → show the jump-to-bottom button.
    final show = _scroll.position.maxScrollExtent - _scroll.position.pixels >
        240;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
    // Proche du HAUT (messages anciens) → charger la page précédente.
    if (_scroll.position.pixels <= 80 && _hasMore && !_loadingMore) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    // 1re page : les [_pageSize] messages les plus récents → affichage immédiat
    // même sur une conversation de plusieurs milliers de messages.
    final messages = await SmsBridge.instance.listMessages(
      widget.threadId,
      limit: _pageSize,
    );
    unawaited(SmsBridge.instance.markRead(widget.threadId));
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
      _sortMessages();
      _hasMore = messages.length >= _pageSize;
      _loading = false;
    });
    _scrollToBottom(animated: false);
    _prefetchMedia(messages);
  }

  /// Pré-extrait en arrière-plan les parts média (images + vidéos) des messages
  /// chargés, pour qu'elles soient déjà en cache quand la bulle arrive à l'écran
  /// (plus de loader « à la volée » au scroll). Best-effort, non bloquant.
  void _prefetchMedia(List<SmsMessage> messages) {
    for (final m in messages) {
      for (final a in m.visualMedia) {
        // putIfAbsent via _resolveMmsPart : déclenche le chargement une fois et
        // mémoïse, sans relancer si déjà en cours / fait.
        unawaited(_resolveMmsPart(a.partId));
      }
    }
  }

  /// Charge la page précédente (messages plus anciens) quand on remonte. Préserve
  /// la position de scroll pour ne pas faire sauter la liste.
  Future<void> _loadMore() async {
    if (_messages.isEmpty) return;
    _loadingMore = true;
    final oldestMs = _messages.first.date;
    final older = await SmsBridge.instance.listMessages(
      widget.threadId,
      limit: _pageSize,
      beforeMs: oldestMs,
    );
    if (!mounted) {
      _loadingMore = false;
      return;
    }
    final before = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    setState(() {
      // Insère en tête en évitant les doublons (id déjà présents).
      final seen = _messages.map((m) => m.id).toSet();
      _messages.insertAll(0, older.where((m) => !seen.contains(m.id)));
      _sortMessages();
      _hasMore = older.length >= _pageSize;
      _loadingMore = false;
    });
    _prefetchMedia(older);
    // Compense le décalage introduit par les nouveaux items en tête.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final after = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(_scroll.position.pixels + (after - before));
    });
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

      final incomingId = sms.hasMessageId
          ? '${sms.messageId}'
          : '$_incomingPrefix${sms.date}-${_incomingSeq++}';
      setState(() {
        _animateInId = incomingId;
        _messages.add(
          SmsMessage(
            // Prefer the real provider rowId when the native side supplies it
            // (stable + lets a delete target the right row); fall back to a
            // monotonic synthetic id otherwise.
            id: incomingId,
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
      _scheduleAnimateInClear(incomingId);
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
      _animateInId = optimistic.id;
      _messages.add(optimistic);
      _sortMessages();
      _composer.clear();
      _hasText = false;
      _pendingImagePath = null;
    });
    _scheduleAnimateInClear(optimistic.id);
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

    // Disappearing messages: arm expiry for the sent SMS/MMS if a policy (or a
    // one-shot per-message override) is active for this thread.
    if (rowId != null) {
      final override = _pendingEphemeralOverride;
      await EphemeralMessages.instance.trackSmsMessage(
        widget.threadId,
        '$rowId',
        isMms: hasImage,
        explicit: override,
      );
      if (mounted && override != null) {
        setState(() => _pendingEphemeralOverride = null);
      }
    }
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
  /// Picks an image from the gallery and queues it in the composer.
  Future<void> _pickImage() => _pickFrom(ImageSource.gallery);

  /// Captures a photo with the camera and queues it in the composer.
  Future<void> _takePhoto() => _pickFrom(ImageSource.camera);

  Future<void> _pickFrom(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
        source: source,
        imageQuality: 85,
      );
      if (!mounted || file == null) return;
      setState(() => _pendingImagePath = file.path);
    } catch (_) {
      // Picker can throw on some OEMs (no gallery/camera app, permission
      // denied). Stay silent — the user simply gets no image queued.
    }
  }

  void _clearPendingImage() {
    if (_pendingImagePath == null) return;
    setState(() => _pendingImagePath = null);
  }

  /// Toggles the inline emoji panel. Opening it drops the soft keyboard (like
  /// the Matrix composer) so the panel and the IME don't fight for space.
  void _toggleEmoji() {
    setState(() => _showEmoji = !_showEmoji);
    if (_showEmoji) {
      _composerFocus.unfocus();
    } else {
      _composerFocus.requestFocus();
    }
  }

  /// Inserts [glyph] at the current caret position of the SMS field, keeping the
  /// selection right after the inserted emoji.
  void _insertEmoji(String glyph) {
    final value = _composer.value;
    final sel = value.selection;
    final base = sel.isValid ? sel.start : value.text.length;
    final extent = sel.isValid ? sel.end : value.text.length;
    final text = value.text.replaceRange(base, extent, glyph);
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: base + glyph.length),
    );
  }

  /// Deletes the grapheme before the caret — backspace for the emoji panel.
  void _emojiBackspace() {
    final value = _composer.value;
    final sel = value.selection;
    final end = sel.isValid ? sel.start : value.text.length;
    if (end == 0) return;
    final characters = value.text.substring(0, end).characters;
    if (characters.isEmpty) return;
    final removed = characters.last.length;
    final text = value.text.replaceRange(end - removed, end, '');
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: end - removed),
    );
  }

  /// Memoises the *Future* per partId (not just its result) so a FutureBuilder
  /// fed by [_resolveMmsPart] keeps the same future across rebuilds and never
  /// flashes back to its loading state while scrolling.
  Future<String?> _resolveMmsPart(int partId) =>
      _mmsFutures.putIfAbsent(partId, () => _loadMmsPart(partId));

  Future<String?> _loadMmsPart(int partId) async {
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

  /// Opens the system dialer with this conversation's number pre-filled
  /// (`tel:` intent — no CALL_PHONE permission, the user taps "call"). The raw
  /// SMS address may carry spaces/punctuation, so we strip them for the URI.
  /// Alphanumeric sender IDs (e.g. "Orange", "Free Mobile") and group threads
  /// with comma-separated addresses are not dialable → snackbar instead.
  Future<void> _callContact() async {
    final raw = widget.address.trim();
    // Group MMS thread (multiple recipients) or alpha sender → not a number.
    final hasComma = raw.contains(',') || raw.contains(';');
    final dialable = raw.replaceAll(RegExp(r'[\s\-().]'), '');
    final isPhoneNumber =
        !hasComma && RegExp(r'^\+?\d{3,}$').hasMatch(dialable);
    if (!isPhoneNumber) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ce numéro n’est pas appelable')),
      );
      return;
    }
    try {
      await launchUrlString(
        'tel:$dialable',
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible de lancer l’appel')),
      );
    }
  }

  /// Long-press on a bubble → CYBERCORE action sheet (copy / delete).
  /// Swipe-to-reply for SMS: there is no native reply protocol, so we quote the
  /// message text into the composer (`> quoted line`) and focus it, the way SMS
  /// clients fake replies. No-op for an empty (image-only) message.
  void _quoteMessage(SmsMessage message) {
    final quoted = message.body.trim();
    if (quoted.isEmpty) return;
    final prefix = quoted.split('\n').map((l) => '> $l').join('\n');
    final existing = _composer.text;
    _composer.text = existing.isEmpty ? '$prefix\n' : '$existing\n$prefix\n';
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    _composerFocus.requestFocus();
    setState(() => _hasText = _composer.text.trim().isNotEmpty);
  }

  Future<void> _onMessageLongPress(SmsMessage message) async {
    // mediumImpact to match the Matrix message long-press feel.
    HapticFeedback.mediumImpact();
    final cyber = CyberColors.of(context);
    final failed = message.type == _SmsChatPageState._typeFailed;
    final action = await showModalBottomSheet<_MessageAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _MessageActionSheet(
        cyber: cyber,
        canCopy: message.body.isNotEmpty,
        canResend: failed,
        canForward: message.body.isNotEmpty,
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
      case _MessageAction.forward:
        await _forwardMessage(message);
      case _MessageAction.resend:
        await _resendMessage(message);
      case _MessageAction.delete:
        await _deleteMessage(message);
    }
  }

  /// Forwards a message's text via the system share sheet — lets the user send
  /// it to any other contact / app (SMS has no native forward protocol, so this
  /// is the standard "transférer" behaviour).
  Future<void> _forwardMessage(SmsMessage message) async {
    final text = message.body.trim();
    if (text.isEmpty) return;
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      // Share sheet unavailable — nothing actionable.
    }
  }

  /// Re-sends a previously failed SMS: drops the failed bubble and routes the
  /// text back through the normal send path.
  Future<void> _resendMessage(SmsMessage message) async {
    setState(() => _messages.removeWhere((m) => m.id == message.id));
    final rowId = await SmsBridge.instance.sendSms(widget.address, message.body);
    if (!mounted) return;
    if (rowId == null) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Échec du renvoi')),
      );
    }
    await _load();
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
    // Dart's List.sort isn't stable; break date ties by id so two messages with
    // the same millisecond timestamp keep a deterministic order (no flicker).
    _messages.sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
  }

  void _scrollToBottom({bool animated = true}) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final generation = ++_stickGeneration;
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
      // maxScrollExtent at this frame is computed BEFORE async MMS images
      // resolve and claim their real height (240dp each). As they pop in, the
      // content grows above us and a single jump lands mid-list. Re-pin to the
      // bottom over the next ~800ms while the thread settles — but bail out the
      // moment the user scrolls up themselves (don't fight their finger).
      _keepPinnedToBottom(generation, 0, _scroll.position.pixels);
    });
  }

  static const int _stickRetries = 8;
  static const Duration _stickInterval = Duration(milliseconds: 100);

  /// [lastPixels] is the scroll offset we left the list at. When content grows
  /// underneath us, maxScrollExtent rises while `pixels` stays put — so we
  /// detect a *user* scroll-up as `pixels` dropping clearly below where we
  /// pinned it, and only then stop fighting to stay at the bottom.
  void _keepPinnedToBottom(int generation, int attempt, double lastPixels) {
    if (generation != _stickGeneration) return; // superseded
    if (attempt >= _stickRetries) return;
    Future.delayed(_stickInterval, () {
      if (!mounted || generation != _stickGeneration) return;
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      // The user deliberately scrolled up → leave them be.
      if (pos.pixels < lastPixels - 24) return;
      if (pos.pixels < pos.maxScrollExtent) {
        _scroll.jumpTo(pos.maxScrollExtent);
      }
      _keepPinnedToBottom(generation, attempt + 1, _scroll.position.pixels);
    });
  }

  static final RegExp _normalizeRe = RegExp(r'[\s\-().]');

  /// Strips spaces/punctuation so `+33 6 12` and `0612` compare loosely. Cheap
  /// best-effort match for the incoming-stream fallback only.
  String _normalize(String address) =>
      address.replaceAll(_normalizeRe, '');

  String get _title {
    final name = widget.displayName;
    if (name != null && name.isNotEmpty) return name;
    return widget.address;
  }

  /// Subtitle below the header title: "MMS" when any message carries an image,
  /// otherwise "SMS".
  String get _subtitle =>
      _messages.any((m) => m.isMms && m.images.isNotEmpty) ? 'MMS' : 'SMS';

  static final RegExp _alnumRe = RegExp(r'[A-Za-z0-9]');

  String _initial() {
    final source = _title.trim();
    if (source.isEmpty) return '#';
    final first = source[0];
    return _alnumRe.hasMatch(first) ? first.toUpperCase() : '#';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = CyberColors.of(context);
    // Mirror the Matrix chat scaffold: frosted app bar floating over the body
    // (extendBodyBehindAppBar) on top of a subtle Aurora backdrop, with the
    // body reserving the app bar's height. Identical chrome to a Matrix room.
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.colorScheme.surface,
      appBar: _buildAppBar(theme, cyber),
      floatingActionButton: AnimatedSlide(
        duration: FluffyDurations.fast,
        offset: _showScrollDown ? Offset.zero : const Offset(0, 2),
        child: AnimatedOpacity(
          duration: FluffyDurations.fast,
          opacity: _showScrollDown ? 1 : 0,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 72),
            child: FloatingActionButton.small(
              heroTag: null,
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
              foregroundColor: cyber.cyan,
              onPressed: _showScrollDown ? _scrollToBottom : null,
              child: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Same animated aurora backdrop as the Matrix timeline, faded low and
          // isolated in a RepaintBoundary; renders nothing under reduce-motion.
          Positioned.fill(
            child: RepaintBoundary(
              child: Opacity(
                opacity: 0.22,
                child: CyberManaged(
                  effect: const AuroraEffect(speed: 0.35),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Column(
              children: [
                // Reserve space for the frosted app bar sitting above the body.
                SizedBox(
                  height: MediaQuery.paddingOf(context).top + _kSmsAppBarHeight,
                ),
                Expanded(child: _buildBody(theme, cyber)),
                _buildComposer(theme, cyber),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Frosted "liquid glass" app bar — a faithful copy of the Matrix
  /// [ChatLiquidGlassAppBar] surface (height 64, BackdropFilter blur 20,
  /// surface@0.65 fill, 0.5px outlineVariant bottom border) so the SMS header
  /// chrome is identical to a Matrix room header. Only the avatar (gradient
  /// initial vs Matrix mxc avatar) and the subtitle source differ.
  PreferredSizeWidget _buildAppBar(ThemeData theme, CyberpunkTheme cyber) {
    return _SmsLiquidGlassAppBar(
      height: _kSmsAppBarHeight,
      title: _title,
      subtitle: _subtitle,
      initial: _initial(),
      photoPath: widget.photoPath,
      cyber: cyber,
      onBack: () {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      onDelete: _deleteConversation,
      onGallery: _openSmsMediaGallery,
      onCall: _callContact,
    );
  }

  /// Opens the per-conversation media gallery: every image exchanged in this
  /// SMS/MMS thread, in a grid, tap-to-zoom. Images are pulled from the
  /// already-loaded [_messages] (their MMS parts), resolved on demand through
  /// the same cached [_loadMmsPart] used by the bubbles.
  void _openSmsMediaGallery() {
    final attachments = <SmsAttachment>[];
    for (final m in _messages) {
      attachments.addAll(m.visualMedia);
    }
    // Newest first feels right for a gallery; _messages is chronological asc.
    final ordered = attachments.reversed.toList();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SmsMediaGalleryPage(
          title: _title,
          attachments: ordered,
          cyber: CyberColors.of(context),
          resolveImagePath: _loadMmsPart,
        ),
      ),
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
    // Hoisted once per build instead of recomputed for every row (the sender
    // header is identical for the whole thread).
    final senderInitial = _initial();
    final senderName = _title;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: FluffySpacing.sm),
      cacheExtent: 600,
      // +1 trailing slot for the in-conversation "scheduled" marker (renders
      // itself to nothing when the thread has no pending scheduled messages).
      itemCount: _messages.length + 1,
      itemBuilder: (context, index) {
        if (index == _messages.length) {
          return ScheduledInlineMarker(
            selector: () => ScheduledMessages.instance.forSms(widget.address),
          );
        }
        final message = _messages[index];
        final previous = index > 0 ? _messages[index - 1] : null;
        final next =
            index < _messages.length - 1 ? _messages[index + 1] : null;
        // New calendar day → inline date separator above the bubble.
        final showDateSeparator =
            previous == null || !_sameDay(previous.date, message.date);
        // Heure affichée sur CHAQUE message (demande Bastien) — pas seulement au
        // changement d'expéditeur / gap / jour comme Google Messages. Le collage
        // visuel des bulles reste piloté par previous/nextSameSender ci-dessous,
        // donc montrer l'heure partout n'éclate pas les groupes.
        const showTimestamp = true;
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
        return RepaintBoundary(
          // Stable key per message so ListView.builder doesn't reuse one row's
          // State (animation, MMS FutureBuilder) for a different message while
          // recycling during scroll — the root cause of the scroll glitches.
          key: ValueKey('sms_row_${message.id}'),
          child: Column(
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
                senderInitial: senderInitial,
                senderName: senderName,
                animateIn: message.id == _animateInId,
                resolveImagePath: _resolveMmsPart,
                onOpenLink: _openLink,
                onLongPress: () => _onMessageLongPress(message),
                onReply: () => _quoteMessage(message),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Disappearing-message indicator chip in the composer. Shown when a per-
  /// conversation ephemeral policy OR a one-shot per-message override is active.
  /// Tapping it sets a per-message override. Mirrors the Matrix composer's
  /// _EphemeralIndicator so the SMS user can actually see/set the timer (the
  /// state existed but was never surfaced).
  Widget _buildEphemeralChip(ThemeData theme, CyberpunkTheme cyber) {
    final convId = EphemeralMessages.smsConvId(widget.threadId);
    final policy = EphemeralMessages.instance.policyFor(convId);
    final effective = _pendingEphemeralOverride ?? policy;
    if (!effective.isActive) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: FluffySpacing.sm, left: 8),
      child: InkResponse(
        onTap: _editEphemeralOverride,
        radius: 22,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.bubbleColor.withValues(
              alpha: _pendingEphemeralOverride != null ? 0.30 : 0.18,
            ),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: theme.bubbleColor.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer, size: 14, color: theme.bubbleColor),
              const SizedBox(width: 4),
              Text(
                EphemeralPicker.label(context, effective),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.bubbleColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editEphemeralOverride() async {
    final convId = EphemeralMessages.smsConvId(widget.threadId);
    final current = _pendingEphemeralOverride ??
        EphemeralMessages.instance.policyFor(convId);
    final chosen = await EphemeralPicker.show(
      context,
      current: current,
      perMessage: true,
    );
    if (chosen == null || !mounted) return;
    setState(() => _pendingEphemeralOverride =
        chosen == EphemeralDuration.off ? null : chosen);
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
            _buildEphemeralChip(theme, cyber),
            if (hasImage)
              _PendingImagePreview(
                path: _pendingImagePath!,
                cyber: cyber,
                onRemove: _clearPendingImage,
              ),
            // Composer row aligned to the Matrix ChatInputRow: 56dp tall, a
            // leading "+" popup button that collapses while typing, an emoji
            // toggle, a borderless transparent field, and a round bubbleColor
            // send button — visually identical to a Matrix room composer.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 8),
                // "+" attach popup — same 48dp animated slot as Matrix; it
                // collapses to width 0 once there is text, just like the room
                // composer's add button.
                AnimatedContainer(
                  duration: FluffyThemes.animationDuration,
                  curve: FluffyThemes.animationCurve,
                  width: _hasText ? 0 : 48,
                  height: _composerRowHeight,
                  alignment: Alignment.center,
                  clipBehavior: Clip.hardEdge,
                  decoration: const BoxDecoration(),
                  child: PopupMenuButton<_SmsComposerAction>(
                    useRootNavigator: true,
                    icon: const Icon(Icons.add_circle_outline),
                    iconColor: theme.colorScheme.onPrimaryContainer,
                    enabled: !_sending,
                    onSelected: (action) {
                      switch (action) {
                        case _SmsComposerAction.camera:
                          _takePhoto();
                        case _SmsComposerAction.image:
                          _pickImage();
                        case _SmsComposerAction.ephemeral:
                          _editEphemeralOverride();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _SmsComposerAction.camera,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
                            child: const Icon(Icons.photo_camera_outlined),
                          ),
                          title: const Text('Prendre une photo'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: _SmsComposerAction.image,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
                            child: const Icon(Icons.photo_outlined),
                          ),
                          title: const Text('Envoyer une image'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: _SmsComposerAction.ephemeral,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.onPrimaryContainer,
                            foregroundColor: theme.colorScheme.primaryContainer,
                            child: const Icon(Icons.timer_outlined),
                          ),
                          title: Text(L10n.of(context).ephemeralMessages),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
                // Emoji toggle — mirrors Matrix's add_reaction/keyboard swap.
                Container(
                  height: _composerRowHeight,
                  width: 48,
                  alignment: Alignment.center,
                  child: IconButton(
                    tooltip: L10n.of(context).emojis,
                    color: theme.colorScheme.onPrimaryContainer,
                    icon: Icon(
                      _showEmoji
                          ? Icons.keyboard
                          : Icons.add_reaction_outlined,
                      key: ValueKey(_showEmoji),
                    ),
                    onPressed: _toggleEmoji,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      minLines: 1,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      // Honour the same "Enter to send" setting as the Matrix
                      // composer instead of always inserting a newline.
                      textInputAction:
                          AppSettings.sendOnEnter.value == true
                              ? TextInputAction.send
                              : TextInputAction.newline,
                      onSubmitted: (_) {
                        if (AppSettings.sendOnEnter.value == true) _send();
                      },
                      cursorColor: cyber.cyan,
                      style: TextStyle(
                        fontFamily: FluffyTypography.inter,
                        fontSize: AppConfig.messageFontSize *
                            AppSettings.fontSizeFactor.value,
                        color: theme.colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.only(
                          left: 6.0,
                          right: 6.0,
                          bottom: 6.0,
                          top: 3.0,
                        ),
                        counter: const SizedBox.shrink(),
                        hintText: 'Écrivez un SMS…',
                        hintMaxLines: 1,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        filled: false,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: _composerRowHeight,
                  width: _composerRowHeight,
                  child: Center(
                    child: GestureDetector(
                      onLongPress:
                          _hasText && !_sending ? _schedule : null,
                      child: IconButton(
                        tooltip: 'Envoyer',
                        onPressed: canSend ? _send : null,
                        style: IconButton.styleFrom(
                          backgroundColor: theme.bubbleColor,
                          foregroundColor: theme.onBubbleColor,
                          disabledBackgroundColor:
                              theme.bubbleColor.withValues(alpha: 0.4),
                        ),
                        icon: _sending
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.onBubbleColor,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Inline emoji panel — same slide-open behaviour as the Matrix
            // ChatEmojiPicker, minus the (SMS-irrelevant) sticker tab. Inserts
            // the picked glyph at the caret of the SMS field.
            AnimatedContainer(
              duration: FluffyThemes.animationDuration,
              curve: FluffyThemes.animationCurve,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              height: _showEmoji ? MediaQuery.sizeOf(context).height / 2.6 : 0,
              child: _showEmoji
                  ? EmojiPicker(
                      onEmojiSelected: (category, emoji) =>
                          _insertEmoji(emoji.emoji),
                      onBackspacePressed: _emojiBackspace,
                      config: Config(
                        locale: Localizations.localeOf(context),
                        emojiViewConfig: EmojiViewConfig(
                          backgroundColor: theme.colorScheme.onInverseSurface,
                        ),
                        bottomActionBarConfig:
                            const BottomActionBarConfig(enabled: false),
                        categoryViewConfig: CategoryViewConfig(
                          backspaceColor: theme.colorScheme.primary,
                          iconColor:
                              theme.colorScheme.primary.withAlpha(128),
                          iconColorSelected: theme.colorScheme.primary,
                          indicatorColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.surface,
                        ),
                      ),
                    )
                  : null,
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

  /// Play a slide-up + fade-in on first build (just-sent / just-received).
  final bool animateIn;

  final Future<String?> Function(int partId) resolveImagePath;
  final Future<void> Function(LinkableElement link) onOpenLink;
  final VoidCallback onLongPress;
  final VoidCallback onReply;

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
    required this.onReply,
    this.animateIn = false,
  });

  /// URL + email + phone + postal-address detection inside SMS bodies. The map
  /// linkifier turns a French-style address into a geo: link the OS opens in
  /// the maps/GPS app.
  static const List<Linkifier> _linkifiers = [
    UrlLinkifier(),
    EmailLinkifier(),
    PhoneNumberLinkifier(),
    MapAddressLinkifier(),
  ];

  bool get _failed => message.type == _SmsChatPageState._typeFailed;
  bool get _pending =>
      message.type == _SmsChatPageState._typeQueued ||
      message.type == _SmsChatPageState._typeOutbox;

  @override
  Widget build(BuildContext context) {
    final own = message.isFromMe;
    final align = own ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubble = _bubble(context, own);
    // Avatar + sender name header at the top of an inbound group only — mirrors
    // Message.dart's `!nextEventSameSender` header. The bubble below aligns
    // under the name, not offset by the avatar (full-width inbound layout).
    final showInboundHeader = !own && !previousSameSender;
    final content = Padding(
      // Exact Matrix spacing (message.dart): 1px between grouped bubbles, 4px
      // between groups. Was FluffySpacing.xxs (2px) → bubbles were twice as far
      // apart as Matrix.
      padding: EdgeInsets.only(
        top: previousSameSender ? 1.0 : FluffySpacing.xs,
        bottom: nextSameSender ? 1.0 : FluffySpacing.xs,
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
            // Cap the bubble at 78% of the viewport so own messages sit clearly
            // on the right and inbound on the left (WhatsApp/iMessage style).
            // The old columnWidth*1.5 (570dp) was wider than the screen on the
            // Fold, so every bubble spanned the full row and the own/inbound
            // alignment was invisible — everything looked left-aligned.
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            child: SwipeToReply(
              // SMS bubbles are full-width: swipe own messages right-to-left and
              // inbound left-to-right, matching the Matrix timeline convention.
              reverse: own,
              onReply: onReply,
              child: GestureDetector(
                onLongPress: onLongPress,
                child: bubble,
              ),
            ),
          ),
          if (showTimestamp || own) ...[
            const SizedBox(height: FluffySpacing.xxs),
            _metaLine(),
          ],
        ],
      ),
    );
    // Slide-up + fade-in ONLY the first time this specific bubble is built.
    // Uses a stateful one-shot wrapper (like Matrix's _AnimateIn) instead of
    // flutter_animate's .animate(), which re-fired on every rebuild — and
    // ListView.builder rebuilds recycled bubbles during scroll, which caused
    // bubbles to replay the slide/fade and produced the scroll glitches.
    if (CyberMotion.reduced(context)) return content;
    return _AnimateInOnce(animate: animateIn, child: content);
  }

  /// Builds the bubble through the shared [ChatBubbleSkin] so it is identical to
  /// a Matrix message bubble at the pixel level (same gradient/glow own, same
  /// hairline-violet glass inbound, same tail geometry). Only the *content* and
  /// text colours differ per channel.
  Widget _bubble(BuildContext context, bool own) {
    final textColor = own
        ? theme.onBubbleColor
        : theme.colorScheme.onSurface;
    final linkColor = own
        ? (theme.brightness == Brightness.light
            ? theme.colorScheme.primaryFixed
            : theme.colorScheme.onTertiaryContainer)
        : theme.colorScheme.primary;
    return Opacity(
      opacity: _pending ? 0.75 : 1,
      child: ChatBubbleSkin(
        ownMessage: own,
        isError: _failed,
        // The SMS list is chronological (oldest at top), the inverse of the
        // reverse Matrix timeline ChatBubbleSkin is named for. Map the older
        // neighbour (above) to the *after* slot (squares the top corner) and the
        // newer neighbour (below) to the *before* slot (squares the bottom).
        sameSenderAfter: previousSameSender,
        sameSenderBefore: nextSameSender,
        child: _bubbleContent(
          context,
          textColor: textColor,
          linkColor: linkColor,
        ),
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
    final media = message.visualMedia;
    final files = message.otherFiles;
    final hasText = message.body.isNotEmpty;
    final hasTrailing = hasText || files.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < media.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: hasTrailing || i < media.length - 1 ? FluffySpacing.xs : 0,
            ),
            child: media[i].isVideo
                ? _MmsVideo(
                    key: ValueKey('mms_part_${media[i].partId}'),
                    partId: media[i].partId,
                    cyber: cyber,
                    theme: theme,
                    resolveMediaPath: resolveImagePath,
                  )
                : _MmsImage(
                    // Stable key so the State (resolved path) follows this exact
                    // part across recycling and never gets reused for another.
                    key: ValueKey('mms_part_${media[i].partId}'),
                    partId: media[i].partId,
                    cyber: cyber,
                    theme: theme,
                    resolveImagePath: resolveImagePath,
                  ),
          ),
        for (var i = 0; i < files.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: hasText || i < files.length - 1 ? FluffySpacing.xs : 0,
            ),
            child: _MmsFileChip(
              key: ValueKey('mms_file_${files[i].partId}'),
              attachment: files[i],
              cyber: cyber,
              theme: theme,
              resolveMediaPath: resolveImagePath,
            ),
          ),
        if (hasText)
          Padding(
            // Same interior padding as the Matrix bubble (16 / 8).
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.sm,
            ),
            // SelectableLinkify so the message text can be partially selected
            // and copied (long-press to start a selection), while still keeping
            // tappable URL / phone / email / address links. The bubble-level
            // action sheet stays available on the non-text parts of the bubble.
            child: SelectableLinkify(
              text: message.body,
              linkifiers: _linkifiers,
              options: const LinkifyOptions(humanize: false),
              onOpen: onOpenLink,
              // SelectableLinkify défaut textScaleFactor:1.0 → ignore le zoom de
              // police système (Réglages Android > Taille de police). Les bulles
              // Matrix (Text.rich) le respectent, elles. Sans ça, à font_scale
              // 1.2 le SMS paraissait plus petit que Matrix. On répercute le
              // même facteur système pour aligner les deux.
              textScaleFactor: MediaQuery.textScalerOf(context).scale(1.0),
              // Match the Matrix bubble exactly: same base font size honoring
              // the user's text-size setting (fontSizeFactor), AND the same
              // explicit line-height 1.25 that HtmlMessage forces (html_message
              // .dart:600) so it doesn't inherit bodyMedium's 1.45 — without it
              // SMS lines sat looser than Matrix ones.
              style: TextStyle(
                fontFamily: FluffyTypography.resolveMessageFont(
                  AppSettings.messageFontFamily.value,
                ),
                height: 1.25,
                fontSize: AppConfig.messageFontSize *
                    AppSettings.fontSizeFactor.value,
                color: textColor,
                fontWeight: textWeight,
              ),
              linkStyle: TextStyle(
                fontFamily: FluffyTypography.resolveMessageFont(
                  AppSettings.messageFontFamily.value,
                ),
                fontSize: AppConfig.messageFontSize *
                    AppSettings.fontSizeFactor.value,
                color: linkColor,
                fontWeight: textWeight,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
            ),
          ),
        // Inline link preview (og: title/image) under the text, when the body
        // contains a URL. Loads lazily; renders nothing until/unless metadata
        // is fetched.
        if (LinkPreviewCard.firstUrl(message.body) case final url?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FluffySpacing.sm,
              0,
              FluffySpacing.sm,
              FluffySpacing.sm,
            ),
            child: LinkPreviewCard(
              key: ValueKey('preview_$url'),
              url: url,
              onOpen: () => onOpenLink(
                LinkableElement(url, url),
              ),
            ),
          ),
      ],
    );
  }

  /// Meta line under the bubble — same JetBrainsMono timestamp style as the
  /// Matrix bubble footer (FluffyTypography.code, 10px, +0.3 tracking) so SMS
  /// and Matrix read identically. Own messages append a compact send/fail
  /// status, which has no Matrix equivalent but stays in the same type scale.
  Widget _metaLine() {
    final muted = theme.colorScheme.onSurfaceVariant;
    final time = _formatTime(message.date);
    // Scale the meta line with the user's text-size setting like the Matrix
    // timestamp does (was a hardcoded 10 that ignored fontSizeFactor → stayed
    // tiny for low-vision users who enlarge the font).
    final metaSize = 10 * AppSettings.fontSizeFactor.value;
    final timeStyle = FluffyTypography.code.copyWith(
      color: muted,
      fontSize: metaSize,
      letterSpacing: 0.3,
    );
    if (!message.isFromMe) {
      return Text(time, style: timeStyle);
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
          Text(time, style: timeStyle),
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
          style: FluffyTypography.code.copyWith(
            color: statusColor,
            fontSize: metaSize,
            letterSpacing: 0.3,
          ),
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

/// One-shot slide-up + fade-in wrapper. Plays the animation exactly once on the
/// first build when [animate] is true, then renders the child statically — so a
/// ListView.builder rebuild during scroll never replays it. Mirrors Matrix's
/// _AnimateIn.
class _AnimateInOnce extends StatefulWidget {
  final bool animate;
  final Widget child;
  const _AnimateInOnce({required this.animate, required this.child});

  @override
  State<_AnimateInOnce> createState() => _AnimateInOnceState();
}

class _AnimateInOnceState extends State<_AnimateInOnce> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.animate || _done) return widget.child;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _done = true);
    });
    return AnimatedSlide(
      duration: FluffyDurations.medium,
      curve: FluffyCurves.emphasized,
      offset: _done ? Offset.zero : const Offset(0, 0.25),
      child: AnimatedOpacity(
        duration: FluffyDurations.medium,
        curve: FluffyCurves.decelerated,
        opacity: _done ? 1 : 0,
        child: widget.child,
      ),
    );
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

/// Room app-bar avatar: 40dp contact photo (or gradient-initial fallback) in a
/// violet ring, mirroring the Matrix room app-bar avatar (`_AvatarWithRing`).
/// SMS has no presence/E2EE, so the ring is static violet rather than the
/// online/encrypted-driven accent of the Matrix one.
class _SmsAvatarWithRing extends StatelessWidget {
  final String initial;
  final String? photoPath;
  final CyberpunkTheme cyber;

  const _SmsAvatarWithRing({
    required this.initial,
    required this.photoPath,
    required this.cyber,
  });

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoPath != null && photoPath!.isNotEmpty;
    final inner = ClipOval(
      child: SizedBox(
        width: _size,
        height: _size,
        child: hasPhoto
            ? Image.file(
                File(photoPath!),
                fit: BoxFit.cover,
                width: _size,
                height: _size,
                errorBuilder: (_, _, _) => _gradientInitial(),
              )
            : _gradientInitial(),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: cyber.violet, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: cyber.violet.withValues(alpha: 0.30),
            blurRadius: 6,
          ),
        ],
      ),
      child: inner,
    );
  }

  Widget _gradientInitial() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cyber.cyan, cyber.magenta],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: FluffyTypography.title.copyWith(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}


/// CYBERCORE long-press action sheet for a message (resend / copy / delete).
class _MessageActionSheet extends StatelessWidget {
  final CyberpunkTheme cyber;
  final bool canCopy;
  final bool canResend;
  final bool canForward;

  const _MessageActionSheet({
    required this.cyber,
    required this.canCopy,
    this.canResend = false,
    this.canForward = false,
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
          padding: const EdgeInsets.symmetric(vertical: FluffySpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canResend)
                _SheetTile(
                  icon: Icons.refresh_rounded,
                  label: 'Réessayer l\'envoi',
                  color: cyber.success,
                  onTap: () =>
                      Navigator.of(context).pop(_MessageAction.resend),
                ),
              if (canCopy)
                _SheetTile(
                  icon: Icons.copy_rounded,
                  label: 'Copier le texte',
                  color: cyber.cyan,
                  onTap: () =>
                      Navigator.of(context).pop(_MessageAction.copy),
                ),
              if (canForward)
                _SheetTile(
                  icon: Icons.forward_rounded,
                  label: 'Transférer',
                  color: cyber.violet,
                  onTap: () =>
                      Navigator.of(context).pop(_MessageAction.forward),
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
enum _MessageAction { resend, copy, forward, delete }

/// Frosted-glass app bar for the SMS conversation, replicating the Matrix
/// [ChatLiquidGlassAppBar] surface so the two headers are visually identical.
class _SmsLiquidGlassAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final double height;
  final String title;
  final String subtitle;
  final String initial;
  final String? photoPath;
  final CyberpunkTheme cyber;
  final VoidCallback onBack;
  final VoidCallback onDelete;
  final VoidCallback onGallery;
  final VoidCallback onCall;

  const _SmsLiquidGlassAppBar({
    required this.height,
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.photoPath,
    required this.cyber,
    required this.onBack,
    required this.onDelete,
    required this.onGallery,
    required this.onCall,
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaPadding = MediaQuery.paddingOf(context);
    final blurSigma = cyber.blurSigmaAppBar;
    final surfaceColor = theme.colorScheme.surface.withValues(alpha: 0.65);
    final borderColor =
        theme.colorScheme.outlineVariant.withValues(alpha: 0.45);

    return RepaintBoundary(
      child: SizedBox(
        height: height + mediaPadding.top,
        child: ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surfaceColor,
                border: Border(
                  bottom: BorderSide(color: borderColor, width: 0.5),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(top: mediaPadding.top),
                child: SizedBox(
                  height: height,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: onBack,
                        tooltip: MaterialLocalizations.of(context)
                            .backButtonTooltip,
                      ),
                      // Contact photo (or gradient initial fallback) in a 40dp
                      // ring — parity with the Matrix room app-bar avatar.
                      _SmsAvatarWithRing(
                        initial: initial,
                        photoPath: photoPath,
                        cyber: cyber,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.call_outlined,
                          color: cyber.cyan,
                        ),
                        onPressed: onCall,
                        tooltip: 'Appeler',
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          color: theme.colorScheme.onSurface,
                        ),
                        color: theme.colorScheme.surfaceContainerHigh,
                        shape: const RoundedRectangleBorder(
                          borderRadius: FluffyRadius.brMd,
                        ),
                        onSelected: (value) {
                          if (value == 'gallery') onGallery();
                          if (value == 'delete') onDelete();
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem<String>(
                            value: 'gallery',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.photo_library_outlined,
                                  color: cyber.cyan,
                                  size: 20,
                                ),
                                const SizedBox(width: FluffySpacing.md),
                                Text(
                                  'Galerie médias',
                                  style: FluffyTypography.bodyM.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
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
                  // 84dp thumbnail — never decode the full-res source.
                  cacheWidth:
                      (MediaQuery.devicePixelRatioOf(context) * 84).round(),
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
            top: -12,
            right: -12,
            // 48dp tap target (Material/iOS minimum) while keeping the 24dp
            // visual chip — the transparent padding around the disc absorbs
            // the extra touch area.
            child: Tooltip(
              message: 'Retirer l\'image',
              child: InkResponse(
                onTap: onRemove,
                radius: 28,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: cyber.magenta,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Colors.black,
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

/// A single MMS image attachment inside a bubble.
///
/// Stateful + FIXED height so it never reflows or flashes during scroll, which
/// was the source of the graphical glitches:
///  - the path is resolved ONCE in initState (not in build / not via a
///    FutureBuilder that re-entered `waiting` on every recycled rebuild);
///  - the slot has a constant [_height] (cover-cropped inside) so the bubble
///    can't grow when the image finally decodes;
///  - `gaplessPlayback` keeps the last frame on rebuild instead of blanking.
class _MmsImage extends StatefulWidget {
  final int partId;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final Future<String?> Function(int partId) resolveImagePath;

  const _MmsImage({
    required this.partId,
    required this.cyber,
    required this.theme,
    required this.resolveImagePath,
    super.key,
  });

  static const double _height = 240;

  @override
  State<_MmsImage> createState() => _MmsImageState();
}

class _MmsImageState extends State<_MmsImage> {
  String? _path;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final path = await widget.resolveImagePath(widget.partId);
    if (!mounted) return;
    setState(() {
      _path = path;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cyber = widget.cyber;
    final theme = widget.theme;
    // The slot is ALWAYS this exact size — content swaps inside without ever
    // changing the bubble's height.
    return Semantics(
      label: 'Image MMS',
      image: true,
      button: true,
      child: ClipRRect(
        borderRadius: FluffyRadius.brMd,
        child: SizedBox(
          height: _MmsImage._height,
          width: double.infinity,
          child: _buildContent(context, cyber, theme),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    CyberpunkTheme cyber,
    ThemeData theme,
  ) {
    if (!_resolved) {
      return Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: CircularProgressIndicator(color: cyber.cyan, strokeWidth: 2),
      );
    }
    final path = _path;
    if (path == null || path.isEmpty) {
      return Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: Icon(
          Icons.image_not_supported_outlined,
          color: theme.colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
    return GestureDetector(
      onTap: () => _openViewer(context, path),
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: _MmsImage._height,
        // Keep the previous frame while rebuilding instead of blanking — kills
        // the flicker when the row is recycled during scroll.
        gaplessPlayback: true,
        // Bound the decode resolution (avoid OOM on a thread full of MMS).
        cacheWidth: (MediaQuery.devicePixelRatioOf(context) * 600).round(),
        errorBuilder: (context, _, _) => Container(
          color: cyber.glassFillLight,
          alignment: Alignment.center,
          child: Icon(
            Icons.broken_image_outlined,
            color: cyber.magenta,
            size: 32,
          ),
        ),
      ),
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
        pageBuilder: (_, _, _) =>
            _MmsImageViewer(path: path, cyber: widget.cyber),
      ),
    );
  }
}

/// Per-conversation media gallery: a 3-column grid of every image exchanged in
/// the thread. Tapping a tile opens the same full-screen [_MmsImageViewer] as
/// the bubbles. Empty state when the thread has no media.
class _SmsMediaGalleryPage extends StatelessWidget {
  final String title;
  final List<SmsAttachment> attachments;
  final CyberpunkTheme cyber;
  final Future<String?> Function(int partId) resolveImagePath;

  const _SmsMediaGalleryPage({
    required this.title,
    required this.attachments,
    required this.cyber,
    required this.resolveImagePath,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Médias · $title'),
        backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.95),
      ),
      body: attachments.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: FluffySpacing.md),
                  Text(
                    'Aucun média dans cette conversation',
                    style: FluffyTypography.bodyM.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(FluffySpacing.xs),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: FluffySpacing.xs,
                mainAxisSpacing: FluffySpacing.xs,
              ),
              itemCount: attachments.length,
              itemBuilder: (context, i) => _SmsGalleryTile(
                key: ValueKey('gallery_${attachments[i].partId}'),
                attachment: attachments[i],
                cyber: cyber,
                resolveImagePath: resolveImagePath,
              ),
            ),
    );
  }
}

/// One square tile in the media gallery. Resolves its MMS part on demand
/// (shared cache). Images open [_MmsImageViewer]; videos show a play badge and
/// open [_MmsVideoPlayer].
class _SmsGalleryTile extends StatefulWidget {
  final SmsAttachment attachment;
  final CyberpunkTheme cyber;
  final Future<String?> Function(int partId) resolveImagePath;

  const _SmsGalleryTile({
    required this.attachment,
    required this.cyber,
    required this.resolveImagePath,
    super.key,
  });

  @override
  State<_SmsGalleryTile> createState() => _SmsGalleryTileState();
}

class _SmsGalleryTileState extends State<_SmsGalleryTile> {
  String? _path;
  bool _resolved = false;
  VideoPlayerController? _thumb;

  bool get _isVideo => widget.attachment.isVideo;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final path = await widget.resolveImagePath(widget.attachment.partId);
    if (!mounted) return;
    setState(() {
      _path = path;
      _resolved = true;
    });
    if (_isVideo && path != null && path.isNotEmpty) {
      final c = VideoPlayerController.file(File(path));
      try {
        await c.initialize();
        if (!mounted) {
          await c.dispose();
          return;
        }
        setState(() => _thumb = c);
      } catch (_) {
        await c.dispose();
      }
    }
  }

  @override
  void dispose() {
    _thumb?.dispose();
    super.dispose();
  }

  void _open(String path) {
    if (_isVideo) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _MmsVideoPlayer(path: path, cyber: widget.cyber),
        ),
      );
      return;
    }
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: reduce ? Duration.zero : FluffyDurations.medium,
        reverseTransitionDuration:
            reduce ? Duration.zero : FluffyDurations.fast,
        pageBuilder: (_, _, _) =>
            _MmsImageViewer(path: path, cyber: widget.cyber),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cyber = widget.cyber;
    final theme = Theme.of(context);
    Widget content;
    if (!_resolved) {
      content = Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: CircularProgressIndicator(color: cyber.cyan, strokeWidth: 2),
      );
    } else if (_path == null || _path!.isEmpty) {
      content = Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: Icon(
          Icons.broken_image_outlined,
          color: cyber.magenta,
          size: 28,
        ),
      );
    } else {
      final thumb = _thumb;
      content = GestureDetector(
        onTap: () => _open(_path!),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isVideo)
              (thumb != null && thumb.value.isInitialized)
                  ? FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: thumb.value.size.width,
                        height: thumb.value.size.height,
                        child: VideoPlayer(thumb),
                      ),
                    )
                  : ColoredBox(color: Colors.black)
            else
              Image.file(
                File(_path!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth:
                    (MediaQuery.devicePixelRatioOf(context) * 300).round(),
                errorBuilder: (context, _, _) => Container(
                  color: cyber.glassFillLight,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: cyber.magenta,
                    size: 28,
                  ),
                ),
              ),
            if (_isVideo)
              Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  color: cyber.cyan.withValues(alpha: 0.9),
                  size: 34,
                ),
              ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: FluffyRadius.brSm,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHigh,
        child: AspectRatio(aspectRatio: 1, child: content),
      ),
    );
  }
}

/// MMS video bubble: a 240dp slot showing the first frame with a play badge.
/// Tapping opens a full-screen [_MmsVideoPlayer]. Resolves its part path the
/// same way images do (cached [loadMmsPart]).
class _MmsVideo extends StatefulWidget {
  final int partId;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final Future<String?> Function(int partId) resolveMediaPath;

  const _MmsVideo({
    required this.partId,
    required this.cyber,
    required this.theme,
    required this.resolveMediaPath,
    super.key,
  });

  static const double _height = 240;

  @override
  State<_MmsVideo> createState() => _MmsVideoState();
}

class _MmsVideoState extends State<_MmsVideo> {
  String? _path;
  bool _resolved = false;
  VideoPlayerController? _thumbController;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final path = await widget.resolveMediaPath(widget.partId);
    if (!mounted) return;
    setState(() {
      _path = path;
      _resolved = true;
    });
    if (path != null && path.isNotEmpty) {
      // Initialize a controller just to grab the first frame as a poster.
      final c = VideoPlayerController.file(File(path));
      try {
        await c.initialize();
        if (!mounted) {
          await c.dispose();
          return;
        }
        setState(() => _thumbController = c);
      } catch (_) {
        await c.dispose();
      }
    }
  }

  @override
  void dispose() {
    _thumbController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cyber = widget.cyber;
    final theme = widget.theme;
    return ClipRRect(
      borderRadius: FluffyRadius.brMd,
      child: SizedBox(
        height: _MmsVideo._height,
        width: double.infinity,
        child: _buildContent(context, cyber, theme),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    CyberpunkTheme cyber,
    ThemeData theme,
  ) {
    if (!_resolved) {
      return Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: CircularProgressIndicator(color: cyber.cyan, strokeWidth: 2),
      );
    }
    final path = _path;
    if (path == null || path.isEmpty) {
      return Container(
        color: cyber.glassFillLight,
        alignment: Alignment.center,
        child: Icon(
          Icons.videocam_off_outlined,
          color: theme.colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
    final thumb = _thumbController;
    return GestureDetector(
      onTap: () => _openPlayer(context, path),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumb != null && thumb.value.isInitialized)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: thumb.value.size.width,
                height: thumb.value.size.height,
                child: VideoPlayer(thumb),
              ),
            )
          else
            ColoredBox(color: Colors.black),
          // Scrim + play badge.
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
            ),
          ),
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
                border: Border.all(color: cyber.cyan, width: 1.5),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: cyber.cyan,
                size: 34,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openPlayer(BuildContext context, String path) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MmsVideoPlayer(path: path, cyber: widget.cyber),
      ),
    );
  }
}

/// Full-screen MMS video player (chewie). Black backdrop + close.
class _MmsVideoPlayer extends StatefulWidget {
  final String path;
  final CyberpunkTheme cyber;

  const _MmsVideoPlayer({required this.path, required this.cyber});

  @override
  State<_MmsVideoPlayer> createState() => _MmsVideoPlayerState();
}

class _MmsVideoPlayerState extends State<_MmsVideoPlayer> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final v = VideoPlayerController.file(File(widget.path));
      await v.initialize();
      if (!mounted) {
        await v.dispose();
        return;
      }
      setState(() {
        _video = v;
        _chewie = ChewieController(
          videoPlayerController: v,
          autoPlay: true,
          looping: false,
          aspectRatio: v.value.aspectRatio,
        );
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: _error
                  ? Icon(
                      Icons.error_outline_rounded,
                      color: widget.cyber.magenta,
                      size: 64,
                    )
                  : _chewie != null
                      ? Chewie(controller: _chewie!)
                      : CircularProgressIndicator(color: widget.cyber.cyan),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(FluffySpacing.sm),
                child: IconButton(
                  icon: Icon(Icons.close_rounded, color: widget.cyber.cyan),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Non-visual MMS attachment (audio clip, vCard, …) rendered as a tappable file
/// chip. Tapping resolves the part to a cache file and opens the OS share/open
/// sheet (share_plus) so the system handler takes over.
class _MmsFileChip extends StatelessWidget {
  final SmsAttachment attachment;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final Future<String?> Function(int partId) resolveMediaPath;

  const _MmsFileChip({
    required this.attachment,
    required this.cyber,
    required this.theme,
    required this.resolveMediaPath,
    super.key,
  });

  IconData get _icon {
    if (attachment.isAudio) return Icons.audiotrack_rounded;
    if (attachment.isVcard) return Icons.contact_page_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String get _label {
    if (attachment.isAudio) return 'Message audio';
    if (attachment.isVcard) return 'Contact (vCard)';
    final name = attachment.fileName;
    return name.isNotEmpty ? name : 'Pièce jointe';
  }

  Future<void> _open(BuildContext context) async {
    final path = await resolveMediaPath(attachment.partId);
    if (path == null || path.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path, mimeType: attachment.mimeType)]),
      );
    } catch (_) {
      // System sheet unavailable — nothing actionable.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: FluffyRadius.brMd,
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.md,
            vertical: FluffySpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, color: cyber.cyan, size: 22),
              const SizedBox(width: FluffySpacing.sm),
              Flexible(
                child: Text(
                  _label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FluffyTypography.bodyM.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: FluffySpacing.sm),
              Icon(
                Icons.open_in_new_rounded,
                color: theme.colorScheme.onSurfaceVariant,
                size: 16,
              ),
            ],
          ),
        ),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _viewerButton(
                      icon: Icons.ios_share_rounded,
                      tooltip: 'Partager',
                      color: cyber.cyan,
                      onTap: () => _shareImage(context),
                    ),
                    const SizedBox(width: FluffySpacing.sm),
                    _viewerButton(
                      icon: Icons.close_rounded,
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      color: cyber.cyan,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewerButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: color),
          ),
        ),
      ),
    );
  }

  Future<void> _shareImage(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }
}

/// Actions in the SMS composer "+" popup. Kept minimal to what SMS/MMS can
/// actually do (vs the Matrix room composer's polls/location/files).
enum _SmsComposerAction { camera, image, ephemeral }
