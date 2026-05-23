import 'dart:ui' as ui;

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Floating frosted pill placed between two days inside the chat timeline.
///
/// Uses a backdrop blur so the message bubbles underneath show through, with
/// a hairline outline and Material 3 surfaceContainerHigh tint. The label is
/// produced by [_formatRelative] — "Today" / "Yesterday" / weekday for the
/// current week, falling back to "DD MMM YYYY" otherwise.
class ChatDateSeparator extends StatelessWidget {
  final DateTime date;

  const ChatDateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    final locale = Localizations.localeOf(context).languageCode;
    final label = _formatRelative(date, locale);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Center(
        child: TweenAnimationBuilder<double>(
          duration: FluffyDurations.medium,
          curve:
              cyber?.emphasizedDeceleratedCurve ?? FluffyCurves.emphasized,
          tween: Tween(begin: 0.0, end: 1.0),
          builder: (context, t, child) {
            return Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: (cyber?.blurSigmaSheet ?? 24) * 0.5,
                sigmaY: (cyber?.blurSigmaSheet ?? 24) * 0.5,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh
                      .withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.4),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Whether two dates fall on the same calendar day in the local zone.
  static bool sameCalendarDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatRelative(DateTime d, String locale) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diffDays = today.difference(that).inDays;

    if (diffDays == 0) {
      return _localizedToday(locale);
    }
    if (diffDays == 1) {
      return _localizedYesterday(locale);
    }
    if (diffDays > 1 && diffDays < 7) {
      // Weekday label (e.g. "Lundi" / "Monday").
      final weekday = DateFormat.EEEE(locale).format(d);
      return _capitalize(weekday);
    }
    if (d.year == now.year) {
      return DateFormat.MMMd(locale).format(d);
    }
    return DateFormat.yMMMd(locale).format(d);
  }

  /// We cannot rely on the app's L10n for today/yesterday (no keys yet) — fall
  /// back to a small hard-coded map for the languages FluffyChat ships and let
  /// English be the catch-all. Cheaper than introducing new ARB entries here.
  String _localizedToday(String locale) {
    switch (locale) {
      case 'fr':
        return "Aujourd'hui";
      case 'de':
        return 'Heute';
      case 'es':
        return 'Hoy';
      case 'it':
        return 'Oggi';
      case 'pt':
        return 'Hoje';
      case 'nl':
        return 'Vandaag';
      case 'ru':
        return 'Сегодня';
      case 'ja':
        return '今日';
      case 'zh':
        return '今天';
      default:
        return 'Today';
    }
  }

  String _localizedYesterday(String locale) {
    switch (locale) {
      case 'fr':
        return 'Hier';
      case 'de':
        return 'Gestern';
      case 'es':
        return 'Ayer';
      case 'it':
        return 'Ieri';
      case 'pt':
        return 'Ontem';
      case 'nl':
        return 'Gisteren';
      case 'ru':
        return 'Вчера';
      case 'ja':
        return '昨日';
      case 'zh':
        return '昨天';
      default:
        return 'Yesterday';
    }
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
