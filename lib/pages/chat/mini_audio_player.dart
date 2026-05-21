import 'dart:async';

import 'package:async/async.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/utils/audio_playback_controller.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';

/// Sticky Telegram-style mini player. Slides in below the AppBar when a
/// voice message is playing but its source bubble is off-screen.
class MiniAudioPlayer extends StatelessWidget {
  /// Optional active [ChatController]. When provided and the active track
  /// belongs to the same room, tapping the mini player scrolls to the
  /// source bubble instead of routing.
  final ChatController? chatController;

  const MiniAudioPlayer({this.chatController, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = Matrix.of(context).audioPlayback;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final eventId = controller.eventId;
        final roomId = controller.roomId;
        final visible = eventId != null && !controller.sourceVisible;

        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !visible
              ? const SizedBox(width: double.infinity, height: 0)
              : Material(
                  color: theme.colorScheme.surfaceContainerHigh,
                  elevation: 4,
                  child: InkWell(
                    onTap: () => _onTap(context, eventId, roomId),
                    child: SizedBox(
                      height: 64,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: _MiniAudioPlayerContent(
                          key: ValueKey(eventId),
                          controller: controller,
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }

  void _onTap(BuildContext context, String? eventId, String? roomId) {
    if (eventId == null || roomId == null) return;
    final chat = chatController;
    if (chat != null && chat.roomId == roomId) {
      chat.scrollToEventId(eventId);
      return;
    }
    FluffyChatApp.router.go('/rooms/$roomId?event=$eventId');
  }
}

class _MiniAudioPlayerContent extends StatelessWidget {
  final AudioPlaybackController controller;

  const _MiniAudioPlayerContent({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final player = controller.player;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Avatar(
            mxContent: controller.senderAvatarUrl,
            name: controller.senderDisplayName,
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: StreamBuilder<Object?>(
              stream: player == null
                  ? null
                  : StreamGroup.merge(<Stream<Object?>>[
                      player.positionStream,
                      player.playerStateStream,
                      player.durationStream,
                    ]),
              builder: (context, _) {
                final pos = player?.position ?? Duration.zero;
                final dur = player?.duration ?? Duration.zero;
                final progress =
                    dur.inMilliseconds == 0
                        ? 0.0
                        : (pos.inMilliseconds / dur.inMilliseconds).clamp(
                          0.0,
                          1.0,
                        );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.senderDisplayName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${l10n.nowPlaying} • ${_format(pos)} / ${_format(dur)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          StreamBuilder<Object?>(
            stream: player?.playerStateStream,
            builder: (context, _) {
              final playing = player?.playing ?? false;
              return IconButton(
                tooltip: playing ? l10n.pause : l10n.nowPlaying,
                icon: Icon(
                  playing
                      ? Icons.pause_outlined
                      : Icons.play_arrow_outlined,
                ),
                onPressed: player == null
                    ? null
                    : () {
                        if (playing) {
                          controller.pause();
                        } else {
                          controller.resume();
                        }
                      },
              );
            },
          ),
          IconButton(
            tooltip: l10n.stopPlayback,
            icon: const Icon(Icons.close_outlined),
            onPressed: () {
              final p = controller.player;
              controller.stop();
              p?.pause();
            },
          ),
        ],
      ),
    );
  }

  static String _format(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
