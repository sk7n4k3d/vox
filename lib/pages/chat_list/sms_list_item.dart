import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter/material.dart';

/// Chat-list row for an SMS conversation — the parallel of ChatListItem for the
/// native SMS layer. Visually consistent (avatar disc, title, snippet, time,
/// unread badge) but driven by [SmsConversation], not a Matrix Room. A small
/// "SMS" chip distinguishes it from encrypted Matrix chats.
class SmsListItem extends StatelessWidget {
  final SmsConversation conversation;
  final VoidCallback onTap;

  const SmsListItem({
    required this.conversation,
    required this.onTap,
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
    final title = conversation.title;
    final initial =
        title.trim().isEmpty ? '#' : title.trim()[0].toUpperCase();
    final unread = conversation.unreadCount > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.lg,
            vertical: FluffySpacing.sm,
          ),
          child: Row(
            children: [
              // Avatar disc with a violet ring to mark the SMS channel.
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
                child: Text(
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
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: FluffyTypography.title.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w600,
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
                      conversation.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluffyTypography.bodyS.copyWith(
                        color: unread
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
