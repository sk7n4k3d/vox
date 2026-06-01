import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// CYBERCORE "schedule send" UI helpers shared by the Matrix and SMS composers.
///
/// Three pieces, all stateless / self-contained:
///  - [ScheduledSend.pickDateTime] : a dark date+time picker returning the chosen
///    instant (or null when cancelled).
///  - [ScheduledSend.nextId] : a collision-free id generator that uses **no**
///    `DateTime.now()` / `Random` (forbidden). It combines a monotonic static
///    counter, the picked send time and the body hash.
///  - [ScheduledBanner] : the glass banner shown above a composer when the
///    room/address has pending scheduled messages, opening a manage sheet on tap.
class ScheduledSend {
  ScheduledSend._();

  /// Monotonic counter feeding [nextId]. Static so two schedules created within
  /// the same millisecond (and identical body) still get distinct ids.
  static int _seq = 0;

  /// Builds a unique id WITHOUT `DateTime.now()` or `Random`.
  ///
  /// Shape: `sched-<sendAtMs>-<bodyHash>-<seq>`. The picked [sendAt] is already a
  /// timestamp, [body] varies per message, and [_seq] guarantees uniqueness for
  /// the degenerate "same time + same body" case.
  static String nextId({required int sendAt, required String body}) {
    final n = _seq++;
    return 'sched-$sendAt-${body.hashCode}-$n';
  }

  /// Opens a dark-themed date picker then time picker, returning the combined
  /// [DateTime] or null if the user cancelled either step. The returned instant
  /// is the source of truth for `sendAt` (no `DateTime.now()` used for it).
  static Future<DateTime?> pickDateTime(BuildContext context) async {
    final cyber = CyberColors.of(context);
    // `initialDate`/`firstDate` need a reference; this is a UI default only and
    // is never used as the scheduled timestamp itself (that comes from the
    // user's selection). Clock read is unavoidable for sane picker bounds.
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      builder: (context, child) => _pickerTheme(context, cyber, child),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      builder: (context, child) => _pickerTheme(context, cyber, child),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  static Widget _pickerTheme(
    BuildContext context,
    CyberpunkTheme cyber,
    Widget? child,
  ) {
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: cyber.cyan,
          onPrimary: Colors.black,
          surface: const Color(0xFF12101C),
          onSurface: Colors.white,
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }

  /// Formats a scheduled instant for snackbars / list rows, e.g. `01/06 14:30`.
  static String formatWhen(DateTime dt) {
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$dd/$mo $hh:$mm';
  }

  /// Opens the bottom sheet listing the given pending scheduled messages with a
  /// per-message cancel button. Live-refreshes via [ScheduledMessages.changes].
  static void showManageSheet(
    BuildContext context, {
    required List<ScheduledMessage> Function() selector,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _ScheduledSheet(selector: selector),
    );
  }
}

/// Glass banner shown above a composer when there are pending scheduled
/// messages. Tap opens the manage sheet. Rebuilds itself on queue changes.
class ScheduledBanner extends StatelessWidget {
  /// Returns the current pending messages for this room/address.
  final List<ScheduledMessage> Function() selector;

  const ScheduledBanner({required this.selector, super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: ScheduledMessages.instance.changes,
      builder: (context, _) {
        final pending = selector();
        if (pending.isEmpty) return const SizedBox.shrink();
        final cyber = CyberColors.of(context);
        final count = pending.length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            FluffySpacing.md,
            FluffySpacing.sm,
            FluffySpacing.md,
            0,
          ),
          child: CyberGlass(
            borderRadius: FluffyRadius.brMd,
            padding: const EdgeInsets.symmetric(
              horizontal: FluffySpacing.md,
              vertical: FluffySpacing.sm,
            ),
            glow: FluffyElevation.glowCyan(cyber.cyan, alpha: 0.18),
            onTap: () => ScheduledSend.showManageSheet(
              context,
              selector: selector,
            ),
            child: Row(
              children: [
                Icon(Icons.schedule_rounded, color: cyber.cyan, size: 18),
                const SizedBox(width: FluffySpacing.sm),
                Expanded(
                  child: Text(
                    count == 1
                        ? '1 message programmé'
                        : '$count messages programmés',
                    style: FluffyTypography.labelL.copyWith(color: cyber.cyan),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: cyber.cyan,
                  size: 20,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet body listing pending scheduled messages + per-row cancel.
class _ScheduledSheet extends StatelessWidget {
  final List<ScheduledMessage> Function() selector;

  const _ScheduledSheet({required this.selector});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(FluffySpacing.md),
        child: CyberGlass(
          padding: const EdgeInsets.symmetric(vertical: FluffySpacing.lg),
          child: StreamBuilder<void>(
            stream: ScheduledMessages.instance.changes,
            builder: (context, _) {
              final pending = selector();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const CyberSectionHeader('Messages programmés'),
                  if (pending.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FluffySpacing.xl,
                        FluffySpacing.sm,
                        FluffySpacing.xl,
                        FluffySpacing.lg,
                      ),
                      child: Text(
                        'Aucun message programmé',
                        style: FluffyTypography.bodyM.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: FluffySpacing.sm,
                        ),
                        itemCount: pending.length,
                        itemBuilder: (context, i) => _ScheduledRow(
                          message: pending[i],
                          cyber: cyber,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One row in the manage sheet: send time + body preview + cancel button.
class _ScheduledRow extends StatelessWidget {
  final ScheduledMessage message;
  final CyberpunkTheme cyber;

  const _ScheduledRow({required this.message, required this.cyber});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = message.body.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FluffySpacing.md,
        vertical: FluffySpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule_rounded, color: cyber.cyan, size: 18),
          const SizedBox(width: FluffySpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ScheduledSend.formatWhen(message.sendAtTime),
                  style: FluffyTypography.labelM.copyWith(
                    color: cyber.cyan,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: FluffySpacing.xxs),
                Text(
                  preview.isEmpty ? '(vide)' : preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: FluffyTypography.bodyM.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: FluffySpacing.sm),
          IconButton(
            tooltip: 'Annuler',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, color: cyber.magenta, size: 20),
            onPressed: () => ScheduledMessages.instance.cancel(message.id),
          ),
        ],
      ),
    );
  }
}
