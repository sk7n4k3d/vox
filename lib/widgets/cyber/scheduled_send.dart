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

  /// Opens the edit sheet for a single pending message: edit its text and/or
  /// pick a new send time, then save via [ScheduledMessages.reschedule].
  static void showEditSheet(
    BuildContext context, {
    required ScheduledMessage message,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _ScheduledEditSheet(message: message),
      ),
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

/// In-conversation marker shown at the foot of the message list when the
/// current room/thread has pending scheduled messages. Distinct from
/// [ScheduledBanner] (which sits above the composer): this is a floating pill
/// styled like a date separator, surfacing the *next* upcoming send inline in
/// the timeline. Tapping it opens the manage sheet. Hidden when nothing pends.
class ScheduledInlineMarker extends StatelessWidget {
  /// Returns the current pending messages for this room/address.
  final List<ScheduledMessage> Function() selector;

  const ScheduledInlineMarker({required this.selector, super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: ScheduledMessages.instance.changes,
      builder: (context, _) {
        final pending = selector();
        if (pending.isEmpty) return const SizedBox.shrink();
        final cyber = CyberColors.of(context);
        // `pending` is already sorted by sendAt (ScheduledMessages.all sorts);
        // forRoom/forSms preserve queue order, so take the earliest defensively.
        final next = pending.reduce((a, b) => a.sendAt <= b.sendAt ? a : b);
        final count = pending.length;
        final label = count == 1
            ? 'Programmé · ${ScheduledSend.formatWhen(next.sendAtTime)}'
            : '$count programmés · prochain ${ScheduledSend.formatWhen(next.sendAtTime)}';
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: FluffySpacing.sm),
            child: CyberGlass(
              borderRadius: FluffyRadius.brXl,
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.md,
                vertical: FluffySpacing.xs,
              ),
              glow: FluffyElevation.glowCyan(cyber.cyan, alpha: 0.14),
              onTap: () => ScheduledSend.showManageSheet(
                context,
                selector: selector,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_send_rounded, color: cyber.cyan, size: 15),
                  const SizedBox(width: FluffySpacing.xs),
                  Text(
                    label,
                    style: FluffyTypography.labelM.copyWith(
                      color: cyber.cyan,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
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
          const SizedBox(width: FluffySpacing.xs),
          IconButton(
            tooltip: 'Modifier',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_rounded, color: cyber.cyan, size: 19),
            onPressed: () =>
                ScheduledSend.showEditSheet(context, message: message),
          ),
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

/// Edit sheet for a single pending scheduled message: a prefilled multiline
/// field + a "change time" button + save. Saving calls
/// [ScheduledMessages.reschedule] so the id (and queue position) is preserved.
class _ScheduledEditSheet extends StatefulWidget {
  final ScheduledMessage message;

  const _ScheduledEditSheet({required this.message});

  @override
  State<_ScheduledEditSheet> createState() => _ScheduledEditSheetState();
}

class _ScheduledEditSheetState extends State<_ScheduledEditSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.message.body);
  late DateTime _when = widget.message.sendAtTime;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await ScheduledSend.pickDateTime(context);
    if (picked != null) setState(() => _when = picked);
  }

  Future<void> _save() async {
    final body = _controller.text.trim();
    if (body.isEmpty) return;
    await ScheduledMessages.instance.reschedule(
      widget.message.id,
      body: body,
      sendAt: _when.millisecondsSinceEpoch,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(FluffySpacing.md),
        child: CyberGlass(
          padding: const EdgeInsets.symmetric(
            horizontal: FluffySpacing.lg,
            vertical: FluffySpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CyberSectionHeader('Modifier le message programmé'),
              const SizedBox(height: FluffySpacing.md),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                minLines: 1,
                maxLines: 5,
                style: FluffyTypography.bodyM.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'Texte du message',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: FluffyRadius.brMd,
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: FluffySpacing.md),
              InkWell(
                borderRadius: FluffyRadius.brMd,
                onTap: _pickTime,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluffySpacing.sm,
                    vertical: FluffySpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.schedule_rounded, color: cyber.cyan, size: 18),
                      const SizedBox(width: FluffySpacing.sm),
                      Expanded(
                        child: Text(
                          ScheduledSend.formatWhen(_when),
                          style: FluffyTypography.labelL
                              .copyWith(color: cyber.cyan, letterSpacing: 1.1),
                        ),
                      ),
                      Icon(
                        Icons.edit_calendar_rounded,
                        color: cyber.cyan,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: FluffySpacing.lg),
              CyberPrimaryButton(
                label: 'Enregistrer',
                onPressed: _controller.text.trim().isEmpty ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
