import 'dart:ui' as ui;

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/encryption_button.dart';
import 'package:fluffychat/pages/chat/jitsi_popup_button.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/sync_status_localization.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/chat_settings_popup_menu.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/presence_builder.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../utils/stream_extension.dart';

/// Liquid Glass app bar for room view.
///
/// Frosted surface (blur 20) sitting on top of the message list via
/// [Scaffold.extendBodyBehindAppBar]. Renders a single-priority subtitle
/// (typing > last seen > member count) to avoid the legacy "3-line stack".
/// Detects bridged rooms (mautrix-gmessages, signal, whatsapp, …) and shows
/// a compact identifier pill next to the room name.
class ChatLiquidGlassAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final ChatController controller;
  final double appbarBottomHeight;
  final Widget? bottom;

  static const double _kAppBarHeight = 64.0;

  const ChatLiquidGlassAppBar({
    super.key,
    required this.controller,
    this.appbarBottomHeight = 0.0,
    this.bottom,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(_kAppBarHeight + appbarBottomHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    final room = controller.room;
    final mediaPadding = MediaQuery.paddingOf(context);
    final blurSigma = cyber?.blurSigmaAppBar ?? 20.0;

    final surfaceColor = theme.colorScheme.surface.withValues(alpha: 0.65);
    final borderColor =
        theme.colorScheme.outlineVariant.withValues(alpha: 0.45);

    return RepaintBoundary(
      child: SizedBox(
        height: _kAppBarHeight + mediaPadding.top + appbarBottomHeight,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: _kAppBarHeight,
                      child: _buildContent(context, theme, room),
                    ),
                    ?bottom,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ThemeData theme, Room room) {
    if (controller.selectedEvents.isNotEmpty) {
      return _buildSelectionMode(context, theme);
    }
    if (controller.activeThreadId != null) {
      return _buildThreadMode(context, theme, room);
    }
    return _buildNormalMode(context, theme, room);
  }

  Widget _buildSelectionMode(BuildContext context, ThemeData theme) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: controller.clearSelectedEvents,
          tooltip: L10n.of(context).close,
          color: theme.colorScheme.onTertiaryContainer,
        ),
        const SizedBox(width: 4),
        Text(
          controller.selectedEvents.length.toString(),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onTertiaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildThreadMode(BuildContext context, ThemeData theme, Room room) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: controller.closeThread,
          tooltip: L10n.of(context).backToMainChat,
          color: theme.colorScheme.onSecondaryContainer,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            L10n.of(context).thread,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNormalMode(BuildContext context, ThemeData theme, Room room) {
    final cyber = theme.extension<CyberpunkTheme>();
    final isDirectChat = room.isDirectChat;
    final isEncrypted = room.encrypted;
    final bridgeLabel = _detectBridgeLabel(room);

    final canPlaceCall = AppSettings.experimentalVoip.value &&
        Matrix.of(context).voipPlugin != null &&
        isDirectChat;

    return Row(
      children: [
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/rooms');
            }
          },
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        ),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: controller.isArchived
              ? null
              : () => FluffyThemes.isThreeColumnMode(context)
                  ? controller.toggleDisplayChatDetailsColumn()
                  : context.go('/rooms/${room.id}/details'),
          child: _AvatarWithRing(
            room: room,
            isDirectChat: isDirectChat,
            isEncrypted: isEncrypted,
            cyber: cyber,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onTap: controller.isArchived
                ? null
                : () => FluffyThemes.isThreeColumnMode(context)
                    ? controller.toggleDisplayChatDetailsColumn()
                    : context.go('/rooms/${room.id}/details'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        room.getLocalizedDisplayname(
                          MatrixLocals(L10n.of(context)),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (bridgeLabel != null) ...[
                      const SizedBox(width: 8),
                      _BridgePill(label: bridgeLabel, cyber: cyber),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                _SubtitleLine(controller: controller),
              ],
            ),
          ),
        ),
        if (!controller.room.isArchived) ...[
          if (canPlaceCall)
            IconButton(
              icon: const Icon(Icons.call_outlined),
              tooltip: L10n.of(context).placeCall,
              onPressed: controller.onPhoneButtonTap,
            )
          else if (AppSettings.jitsiFeature.value)
            JitsiPopupButton(controller.room),
          EncryptionButton(controller.room),
          ChatSettingsPopupMenu(controller.room, true),
        ],
        const SizedBox(width: 4),
      ],
    );
  }

  /// Detects a bridge label for a room based on canonical alias / hero patterns
  /// or the m.bridge state event commonly set by mautrix bridges.
  ///
  /// Returns null when no bridge fingerprint is found.
  static String? _detectBridgeLabel(Room room) {
    // 1. m.bridge / uk.half-shot.bridge state event (commonly set by mautrix).
    for (final type in const ['m.bridge', 'uk.half-shot.bridge']) {
      final state = room.getState(type);
      if (state != null) {
        final protocol = state.content
                .tryGetMap<String, Object?>('protocol')
                ?.tryGet<String>('displayname') ??
            state.content.tryGet<String>('protocol');
        final network = state.content
            .tryGetMap<String, Object?>('network')
            ?.tryGet<String>('displayname');
        if (protocol != null) {
          return network != null && network.isNotEmpty
              ? '$protocol · $network'
              : _humanizeBridge(protocol);
        }
      }
    }

    // 2. Heuristic on canonical alias (mautrix uses #_<network>_<id>:server).
    final alias = room.canonicalAlias;
    if (alias.isNotEmpty) {
      final match = RegExp(r'^#_([a-z0-9]+)_').firstMatch(alias);
      if (match != null) {
        return _humanizeBridge(match.group(1)!);
      }
    }

    // 3. Heuristic on hero user ids (e.g. @signal_+33…:server).
    final heroes = room.summary.mHeroes;
    if (heroes != null) {
      for (final hero in heroes) {
        final match = RegExp(r'^@([a-z0-9]+)_').firstMatch(hero);
        if (match != null) {
          final tag = match.group(1)!;
          if (_knownBridgeTags.contains(tag)) {
            return _humanizeBridge(tag);
          }
        }
      }
    }
    return null;
  }

  static const _knownBridgeTags = {
    'gmessages',
    'signal',
    'signalgo',
    'whatsapp',
    'telegram',
    'discord',
    'discordgo',
    'instagram',
    'instagrambot',
    'meta',
    'facebook',
    'twitter',
    'imessage',
    'imessagebot',
    'slack',
    'slackbot',
    'gvoice',
    'sms',
  };

  static String _humanizeBridge(String raw) {
    switch (raw.toLowerCase()) {
      case 'gmessages':
      case 'sms':
        return 'SMS · GMessages';
      case 'signal':
      case 'signalgo':
        return 'Signal';
      case 'whatsapp':
        return 'WhatsApp';
      case 'telegram':
        return 'Telegram';
      case 'discord':
      case 'discordgo':
        return 'Discord';
      case 'instagram':
      case 'instagrambot':
        return 'Instagram';
      case 'meta':
      case 'facebook':
        return 'Messenger';
      case 'twitter':
        return 'Twitter';
      case 'imessage':
      case 'imessagebot':
        return 'iMessage';
      case 'slack':
      case 'slackbot':
        return 'Slack';
      case 'gvoice':
        return 'Google Voice';
      default:
        return raw[0].toUpperCase() + raw.substring(1);
    }
  }
}

class _AvatarWithRing extends StatelessWidget {
  final Room room;
  final bool isDirectChat;
  final bool isEncrypted;
  final CyberpunkTheme? cyber;

  const _AvatarWithRing({
    required this.room,
    required this.isDirectChat,
    required this.isEncrypted,
    required this.cyber,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = Hero(
      tag: 'content_banner',
      child: Avatar(
        mxContent: room.avatar,
        name: room.getLocalizedDisplayname(MatrixLocals(L10n.of(context))),
        size: 40,
      ),
    );
    if (!isDirectChat) return avatar;
    return PresenceBuilder(
      userId: room.directChatMatrixID,
      builder: (context, presence) {
        final online = presence?.currentlyActive == true;
        final accent = isEncrypted && online
            ? (cyber?.cyan ?? theme.colorScheme.tertiary)
            : (online
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant);
        return Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: accent, width: 1.5),
            boxShadow: online && isEncrypted && cyber != null
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.35),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
          child: avatar,
        );
      },
    );
  }
}

class _BridgePill extends StatelessWidget {
  final String label;
  final CyberpunkTheme? cyber;

  const _BridgePill({required this.label, required this.cyber});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = cyber?.violet ?? theme.colorScheme.tertiary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accent.withValues(alpha: 0.45),
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: accent,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-priority subtitle: typing > last seen > member count.
class _SubtitleLine extends StatelessWidget {
  final ChatController controller;

  const _SubtitleLine({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = controller.room;
    final style = theme.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.2,
        ) ??
        TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.2,
        );

    return StreamBuilder<Object>(
      stream: room.client.onSync.stream
          .where((s) => s.hasRoomUpdate)
          .rateLimit(const Duration(milliseconds: 500)),
      builder: (context, _) {
        // Sync status takes over when the client is still warming up.
        final syncStatus = room.client.onSyncStatus.value;
        final syncing = !FluffyThemes.isColumnMode(context) &&
            (room.client.onSync.value == null ||
                (syncStatus != null &&
                    syncStatus.status == SyncStatus.error) ||
                room.client.prevBatch == null);
        if (syncing && syncStatus != null) {
          return Row(
            children: [
              SizedBox.square(
                dimension: 10,
                child: CircularProgressIndicator.adaptive(
                  strokeWidth: 1,
                  value: syncStatus.progress,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  syncStatus.calcLocalizedString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          );
        }

        // 1. Typing (highest priority).
        final typing = room.typingUsers
            .where((u) => u.id != room.client.userID)
            .toList();
        if (typing.isNotEmpty) {
          final text = typing.length == 1
              ? L10n.of(context).isTyping
              : L10n.of(context).numUsersTyping(typing.length);
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          );
        }

        // 2. Direct chat presence (last seen / currently active).
        if (room.isDirectChat) {
          return PresenceBuilder(
            userId: room.directChatMatrixID,
            builder: (context, presence) {
              if (presence?.currentlyActive == true) {
                return Text(
                  L10n.of(context).currentlyActive,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                );
              }
              final lastActive = presence?.lastActiveTimestamp;
              if (lastActive != null) {
                return Text(
                  L10n.of(context)
                      .lastActiveAgo(lastActive.localizedTimeShort(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                );
              }
              return const SizedBox.shrink();
            },
          );
        }

        // 3. Group room: member count.
        final joined = room.summary.mJoinedMemberCount ?? 0;
        if (joined > 0) {
          return Text(
            L10n.of(context).countParticipants(joined),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
