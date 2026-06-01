import 'dart:async';
import 'dart:io';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/cyber/scheduled_send.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// CYBERCORE SMS conversation screen.
///
/// Renders a single SMS thread end to end **without** the Matrix SDK — it talks
/// straight to [SmsBridge] (native Telephony provider). Bubbles mimic the chat
/// look (gradient cyan→magenta for own / glass for inbound) but are simple,
/// self-contained widgets — no Matrix [Timeline] coupling.
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
      final sameThread = sms.threadId.isNotEmpty &&
          sms.threadId == widget.threadId;
      final sameAddress = _normalize(sms.address) == _normalize(widget.address);
      if (!sameThread && !sameAddress) return;

      setState(() {
        _messages.add(
          SmsMessage(
            id: 'incoming-${sms.date}-${_messages.length}',
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
        content: Text('Message programmé pour ${ScheduledSend.formatWhen(when)}'),
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
                  'SMS',
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
                'No messages yet',
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
      padding: const EdgeInsets.fromLTRB(
        FluffySpacing.lg,
        FluffySpacing.lg,
        FluffySpacing.lg,
        FluffySpacing.sm,
      ),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final previous = index > 0 ? _messages[index - 1] : null;
        final showTimestamp = previous == null ||
            (message.date - previous.date).abs() > 5 * 60 * 1000 ||
            previous.isFromMe != message.isFromMe;
        return _SmsBubble(
          message: message,
          cyber: cyber,
          theme: theme,
          showTimestamp: showTimestamp,
          resolveImagePath: _resolveMmsPart,
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
              selector: () =>
                  ScheduledMessages.instance.forSms(widget.address),
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
                        hintText: 'Text message',
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
}

/// A single SMS bubble: gradient cyan→magenta + right-aligned for own messages,
/// glass + left-aligned for inbound. Shows a discreet timestamp and (for own
/// messages) a small send/fail status line.
class _SmsBubble extends StatelessWidget {
  final SmsMessage message;
  final CyberpunkTheme cyber;
  final ThemeData theme;
  final bool showTimestamp;
  final Future<String?> Function(int partId) resolveImagePath;

  const _SmsBubble({
    required this.message,
    required this.cyber,
    required this.theme,
    required this.showTimestamp,
    required this.resolveImagePath,
  });

  bool get _failed => message.type == _SmsChatPageState._typeFailed;
  bool get _pending =>
      message.type == _SmsChatPageState._typeQueued ||
      message.type == _SmsChatPageState._typeOutbox;

  @override
  Widget build(BuildContext context) {
    final own = message.isFromMe;
    final align = own ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubble = own
        ? _ownBubble(context)
        : _inboundBubble(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: FluffySpacing.sm),
      child: Column(
        crossAxisAlignment: align,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            child: bubble,
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
        borderRadius: const BorderRadius.only(
          topLeft: FluffyRadius.lg,
          topRight: FluffyRadius.lg,
          bottomLeft: FluffyRadius.lg,
          bottomRight: FluffyRadius.sm,
        ),
      ),
      child: Opacity(
        opacity: _pending ? 0.75 : 1,
        child: _bubbleContent(
          context,
          textColor: Colors.black,
          textWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _inboundBubble(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cyber.glassFillLight,
        borderRadius: const BorderRadius.only(
          topLeft: FluffyRadius.lg,
          topRight: FluffyRadius.lg,
          bottomLeft: FluffyRadius.sm,
          bottomRight: FluffyRadius.lg,
        ),
        border: Border.all(color: cyber.violet.withValues(alpha: 0.35)),
      ),
      child: _bubbleContent(
        context,
        textColor: theme.colorScheme.onSurface,
      ),
    );
  }

  /// Bubble interior: stacks image attachments (when any) above the text body.
  /// The text padding is dropped entirely when [message.body] is empty so an
  /// image-only MMS keeps tight rounded corners.
  Widget _bubbleContent(
    BuildContext context, {
    required Color textColor,
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
              bottom:
                  hasText || i < images.length - 1 ? FluffySpacing.xs : 0,
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
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.lg,
              vertical: FluffySpacing.md,
            ),
            child: Text(
              message.body,
              style: FluffyTypography.bodyL.copyWith(
                color: textColor,
                fontWeight: textWeight,
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
      statusLabel = 'Not delivered';
      statusColor = cyber.magenta;
    } else if (_pending) {
      statusLabel = 'Sending…';
      statusColor = muted;
    } else {
      statusLabel = 'Sent';
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
                  child: Icon(Icons.close_rounded, size: 16, color: Colors.black),
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
        transitionDuration:
            reduce ? Duration.zero : FluffyDurations.medium,
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
