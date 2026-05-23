import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/author_color.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../../config/app_config.dart';

/// Sprint 2 V3.2 — robust reply preview for media events.
///
/// Bug capture 2026-05-24 : Hermes (Jarvis) reply quoting our voice messages
/// rendered as bare `00:07` because the body of some m.audio events is just
/// the duration string. Now we synthesise a proper preview:
///   - m.audio voice → 🎙️ mm:ss · Voice message
///   - m.audio       → 🎵 audio
///   - m.image       → 📷 image
///   - m.video       → 🎞️ video
///   - m.file        → 📎 file
///   - m.text+formatted → body / plaintext (unchanged)
String _previewBodyFor(Event event, MatrixLocalizations i18n) {
  if (event.type == EventTypes.Message) {
    final mt = event.messageType;
    if (mt == MessageTypes.Audio) {
      final isVoice =
          event.content.tryGetMap('org.matrix.msc3245.voice') != null;
      final durationMs = event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('duration');
      final durStr = durationMs == null
          ? ''
          : '${(durationMs ~/ 60000).toString().padLeft(2, '0')}'
              ':${((durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}';
      if (isVoice) {
        return durStr.isEmpty ? '🎙️ Voice message' : '🎙️ $durStr · Voice';
      }
      return durStr.isEmpty ? '🎵 Audio' : '🎵 $durStr';
    }
    if (mt == MessageTypes.Image) return '📷 Image';
    if (mt == MessageTypes.Video) return '🎞️ Video';
    if (mt == MessageTypes.File) return '📎 File';
  }
  final fallback = event.calcLocalizedBodyFallback(
    i18n,
    withSenderNamePrefix: false,
    hideReply: true,
    plaintextBody: true,
  );
  return fallback.trim().isEmpty ? '…' : fallback;
}

class ReplyContent extends StatelessWidget {
  final Event replyEvent;
  final bool ownMessage;
  final Timeline? timeline;

  const ReplyContent(
    this.replyEvent, {
    this.ownMessage = false,
    super.key,
    this.timeline,
  });

  static const BorderRadius borderRadius = BorderRadius.only(
    topRight: Radius.circular(AppConfig.borderRadius / 2),
    bottomRight: Radius.circular(AppConfig.borderRadius / 2),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final timeline = this.timeline;
    final displayEvent = timeline != null
        ? replyEvent.getDisplayEvent(timeline)
        : replyEvent;
    final fontSize =
        AppConfig.messageFontSize * AppSettings.fontSizeFactor.value;
    final color = theme.brightness == Brightness.dark
        ? theme.colorScheme.onTertiaryContainer
        : ownMessage
        ? theme.colorScheme.tertiaryContainer
        : theme.colorScheme.tertiary;

    final isDirectChat = displayEvent.room.isDirectChat;
    final highContrast = MediaQuery.highContrastOf(context);
    final Color senderNameColor;
    if (ownMessage || isDirectChat) {
      senderNameColor = color;
    } else if (highContrast) {
      senderNameColor = theme.colorScheme.onSurface;
    } else if (!AppSettings.colorfulSenderNames.value) {
      senderNameColor = theme.colorScheme.primary;
    } else {
      senderNameColor = AuthorColors.forUserId(
        displayEvent.senderId,
        theme.brightness,
      );
    }

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      child: Row(
        mainAxisSize: .min,
        children: <Widget>[
          Container(
            width: 5,
            height: fontSize * 2 + 16,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: .start,
              mainAxisAlignment: .center,
              children: <Widget>[
                FutureBuilder<User?>(
                  initialData: displayEvent.senderFromMemoryOrFallback,
                  future: displayEvent.fetchSenderUser(),
                  builder: (context, snapshot) {
                    return Text(
                      '${snapshot.data?.calcDisplayname() ?? displayEvent.senderFromMemoryOrFallback.calcDisplayname()}:',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: senderNameColor,
                        fontSize: fontSize,
                      ),
                    );
                  },
                ),
                Text(
                  _previewBodyFor(
                    displayEvent,
                    MatrixLocals(L10n.of(context)),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: theme.brightness == Brightness.dark
                        ? theme.colorScheme.onSurface
                        : ownMessage
                        ? theme.colorScheme.onTertiary
                        : theme.colorScheme.onSurface,
                    fontSize: fontSize,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
