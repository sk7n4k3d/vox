import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:flutter/material.dart';

/// The shared *skin* of a chat bubble — the single source of truth for how an
/// outgoing/incoming message bubble looks across the whole app.
///
/// Both the Matrix message widget (`pages/chat/events/message.dart`) and the
/// native SMS conversation screen (`pages/sms_chat/sms_chat_page.dart`) render
/// their bubbles through this widget, so the two are pixel-identical by
/// construction rather than by hand-copied imitation.
///
/// It only owns the *surface*: decoration (gradient / fill / border / glow),
/// the asymmetric tail (square corner on the grouped side), the radius and the
/// max width. Content, padding and the meta line (time + status) are the
/// caller's responsibility so each screen can feed its own payload.
class ChatBubbleSkin extends StatelessWidget {
  /// True for the local user's own messages (right-aligned, gradient skin).
  final bool ownMessage;

  /// True when the message failed to send (own bubbles turn red).
  final bool isError;

  /// True when the previous bubble (above) is from the same sender in the same
  /// time bucket — squares the matching top corner so grouped bubbles join.
  final bool sameSenderBefore;

  /// True when the next bubble (below) is from the same sender — squares the
  /// matching bottom corner.
  final bool sameSenderAfter;

  /// When true the bubble draws no surface (media-only bubbles); the child is
  /// shown directly with just the clipped radius.
  final bool noBubble;

  final Widget child;

  const ChatBubbleSkin({
    required this.child,
    required this.ownMessage,
    this.isError = false,
    this.sameSenderBefore = false,
    this.sameSenderAfter = false,
    this.noBubble = false,
    super.key,
  });

  /// The exact tail geometry used by both screens. `next` = the bubble below
  /// (chronologically after), `previous` = the bubble above.
  static BorderRadius tailRadius({
    required bool ownMessage,
    required bool sameSenderBefore,
    required bool sameSenderAfter,
  }) {
    const hardCorner = Radius.circular(4);
    const roundedCorner = Radius.circular(AppConfig.borderRadius);
    return BorderRadius.only(
      topLeft: !ownMessage && sameSenderAfter ? hardCorner : roundedCorner,
      topRight: ownMessage && sameSenderAfter ? hardCorner : roundedCorner,
      bottomLeft:
          !ownMessage && sameSenderBefore ? hardCorner : roundedCorner,
      bottomRight:
          ownMessage && sameSenderBefore ? hardCorner : roundedCorner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    final highContrast = MediaQuery.highContrastOf(context);

    final borderRadius = tailRadius(
      ownMessage: ownMessage,
      sameSenderBefore: sameSenderBefore,
      sameSenderAfter: sameSenderAfter,
    );

    // Own bubbles wear a saturated cyan→magenta diagonal gradient with a soft
    // cyan glow; inbound bubbles get a subtle violet 0.5px border. Mirrors the
    // Matrix message bubble exactly (Sprint 2 V3).
    final useOwnGradient =
        ownMessage && !noBubble && !isError && cyber != null && !highContrast;

    final BoxDecoration decoration;
    if (noBubble) {
      decoration = BoxDecoration(
        color: Colors.transparent,
        borderRadius: borderRadius,
      );
    } else if (useOwnGradient) {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cyber.cyan.withValues(alpha: 0.35),
            cyber.magenta.withValues(alpha: 0.30),
          ],
        ),
        borderRadius: borderRadius,
        border: Border.all(
          color: cyber.cyan.withValues(alpha: 0.45),
          width: 0.75,
        ),
        boxShadow: [
          BoxShadow(
            color: cyber.cyan.withValues(alpha: 0.18),
            blurRadius: 14,
            spreadRadius: -2,
          ),
        ],
      );
    } else {
      final color = ownMessage
          ? (isError ? Colors.redAccent : theme.bubbleColor)
          : theme.colorScheme.surfaceContainerHigh;
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
      decoration: decoration,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
