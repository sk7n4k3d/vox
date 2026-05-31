import 'dart:async';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

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

  StreamSubscription<SmsIncoming>? _incomingSub;
  bool _loading = true;
  bool _sending = false;
  bool _hasText = false;

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
    if (body.isEmpty || _sending) return;

    final optimistic = SmsMessage(
      id: '$_optimisticPrefix${DateTime.now().microsecondsSinceEpoch}',
      address: widget.address,
      body: body,
      date: DateTime.now().millisecondsSinceEpoch,
      isFromMe: true,
      type: _typeQueued,
      status: -1,
      read: true,
    );

    setState(() {
      _sending = true;
      _messages.add(optimistic);
      _sortMessages();
      _composer.clear();
      _hasText = false;
    });
    _scrollToBottom();

    final rowId = await SmsBridge.instance.sendSms(widget.address, body);
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
      );
    });
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
        );
      },
    );
  }

  Widget _buildComposer(ThemeData theme, CyberpunkTheme cyber) {
    final canSend = _hasText && !_sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FluffySpacing.md,
          FluffySpacing.sm,
          FluffySpacing.md,
          FluffySpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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

  const _SmsBubble({
    required this.message,
    required this.cyber,
    required this.theme,
    required this.showTimestamp,
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
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.lg,
            vertical: FluffySpacing.md,
          ),
          child: Text(
            message.body,
            style: FluffyTypography.bodyL.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w500,
            ),
          ),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FluffySpacing.lg,
          vertical: FluffySpacing.md,
        ),
        child: Text(
          message.body,
          style: FluffyTypography.bodyL.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
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

  const _SendButton({
    required this.cyber,
    required this.enabled,
    required this.loading,
    required this.onPressed,
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
