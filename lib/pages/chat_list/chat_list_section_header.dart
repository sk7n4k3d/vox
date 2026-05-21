import 'package:flutter/material.dart';

/// A small uppercase header used to chunk the chat list into temporal sections
/// (TODAY / YESTERDAY / THIS WEEK / EARLIER).
///
/// Designed to be sliver-friendly via wrapping in a `SliverToBoxAdapter`. The
/// styling mirrors the rest of the cyberpunk surface — heavy letter-spacing,
/// small caps, subdued color.
class ChatListSectionHeader extends StatelessWidget {
  final String label;

  const ChatListSectionHeader({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Coarse temporal buckets used by the chat list grouping.
enum ChatListSection { today, yesterday, thisWeek, earlier }

/// Maps a datetime to a [ChatListSection] using local-timezone day boundaries.
///
/// - `today`: same calendar day as `now`.
/// - `yesterday`: previous calendar day.
/// - `thisWeek`: within the last 7 days (excluding today/yesterday).
/// - `earlier`: anything older (including null / epoch).
ChatListSection sectionFromDate(DateTime date, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final target = DateTime(date.year, date.month, date.day);
  final diff = today.difference(target).inDays;
  if (diff <= 0) return ChatListSection.today;
  if (diff == 1) return ChatListSection.yesterday;
  if (diff < 7) return ChatListSection.thisWeek;
  return ChatListSection.earlier;
}

/// Resolves a fallback label for a [ChatListSection].
///
/// French strings for now — a follow-up arb pass will swap these to proper
/// l10n keys once the chat_list_view integration lands.
String sectionLabel(BuildContext context, ChatListSection section) {
  switch (section) {
    case ChatListSection.today:
      return "Aujourd'hui";
    case ChatListSection.yesterday:
      return 'Hier';
    case ChatListSection.thisWeek:
      return 'Cette semaine';
    case ChatListSection.earlier:
      return 'Plus tôt';
  }
}
