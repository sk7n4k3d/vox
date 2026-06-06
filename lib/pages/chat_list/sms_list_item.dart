import 'dart:io';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/conversation_lock.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/material.dart';

/// Chat-list row for an SMS conversation — the parallel of ChatListItem for the
/// native SMS layer. Visually consistent (avatar disc, title, snippet, time,
/// unread badge) but driven by [SmsConversation], not a Matrix Room. A small
/// "SMS" chip distinguishes it from encrypted Matrix chats.
class SmsListItem extends StatelessWidget {
  final SmsConversation conversation;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const SmsListItem({
    required this.conversation,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  String _timeLabel() {
    if (conversation.date <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(conversation.date);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    if (sameDay) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final isHidden = ConversationLock.instance
        .isHidden(ConversationLock.smsId(conversation.threadId));
    // When locked, show a neutral placeholder instead of the real title — a
    // blurred-but-real title is recoverable, and the address would still leak.
    final title = isHidden
        ? L10n.of(context).locked
        : conversation.title;
    final initial = isHidden
        ? '#'
        : (title.trim().isEmpty ? '#' : title.trim()[0].toUpperCase());
    final unread = conversation.unreadCount > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.lg,
            vertical: FluffySpacing.sm,
          ),
          child: Row(
            children: [
              // Avatar disc with a violet ring to mark the SMS channel. Shows
              // the real contact photo when available (and not locked), else a
              // gradient initial.
              Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      cyber.violet.withValues(alpha: 0.35),
                      cyber.magenta.withValues(alpha: 0.25),
                    ],
                  ),
                  border: Border.all(
                    color: cyber.violet.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: (!isHidden &&
                        conversation.photoPath != null &&
                        conversation.photoPath!.isNotEmpty)
                    ? Image.file(
                        File(conversation.photoPath!),
                        width: 54,
                        height: 54,
                        fit: BoxFit.cover,
                        cacheWidth:
                            (MediaQuery.devicePixelRatioOf(context) * 54)
                                .round(),
                        errorBuilder: (context, error, stack) => Text(
                          initial,
                          style: FluffyTypography.headlineM.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      )
                    : Text(
                        initial,
                        style: FluffyTypography.headlineM.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
              ),
              const SizedBox(width: FluffySpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (isHidden)
                          Padding(
                            padding: const EdgeInsets.only(right: 6.0),
                            child: Icon(
                              Icons.lock_outline,
                              size: 15,
                              color: cyber.cyan,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: FluffyTypography.title.copyWith(
                              color: isHidden
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.onSurface,
                              fontStyle: isHidden
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              fontWeight: unread && !isHidden
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: FluffySpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: cyber.violet.withValues(alpha: 0.18),
                            borderRadius: FluffyRadius.brFull,
                            border: Border.all(
                              color: cyber.violet.withValues(alpha: 0.5),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            'SMS',
                            style: FluffyTypography.labelM.copyWith(
                              color: cyber.violet,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: FluffySpacing.xxs),
                    Text(
                      isHidden
                          ? '••• ${L10n.of(context).locked}'
                          : conversation.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // bodyM (Inter 14 / h1.45) to match the Matrix chat-list
                      // preview, which inherits bodyMedium — was bodyS (12px),
                      // making SMS rows visibly smaller than Matrix rows.
                      style: FluffyTypography.bodyM.copyWith(
                        fontStyle:
                            isHidden ? FontStyle.italic : FontStyle.normal,
                        color: unread && !isHidden
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: FluffySpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _timeLabel(),
                    style: FluffyTypography.labelM.copyWith(
                      color: unread
                          ? cyber.cyan
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: FluffySpacing.xxs),
                  if (unread)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: cyber.magenta,
                        borderRadius: FluffyRadius.brFull,
                      ),
                      child: Text(
                        '${conversation.unreadCount}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
