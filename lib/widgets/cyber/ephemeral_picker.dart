import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/ephemeral/ephemeral_messages.dart';
import 'package:flutter/material.dart';

/// CYBERCORE bottom sheet to pick a disappearing-message [EphemeralDuration].
/// Used both for the per-conversation default and the per-message override.
class EphemeralPicker {
  /// Shows the picker and returns the chosen duration, or null if dismissed.
  static Future<EphemeralDuration?> show(
    BuildContext context, {
    required EphemeralDuration current,
    bool perMessage = false,
  }) {
    return showModalBottomSheet<EphemeralDuration>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _EphemeralPickerSheet(
        current: current,
        perMessage: perMessage,
      ),
    );
  }

  /// Human-readable label for a duration.
  static String label(BuildContext context, EphemeralDuration d) {
    final l10n = L10n.of(context);
    switch (d) {
      case EphemeralDuration.off:
        return l10n.ephemeralOff;
      case EphemeralDuration.afterRead:
        return l10n.ephemeralAfterRead;
      case EphemeralDuration.seconds30:
        return l10n.ephemeral30s;
      case EphemeralDuration.minutes5:
        return l10n.ephemeral5min;
      case EphemeralDuration.hour1:
        return l10n.ephemeral1h;
      case EphemeralDuration.day1:
        return l10n.ephemeral1d;
      case EphemeralDuration.week1:
        return l10n.ephemeral1w;
    }
  }

  static IconData icon(EphemeralDuration d) =>
      d == EphemeralDuration.off ? Icons.timer_off_outlined : Icons.timer;
}

class _EphemeralPickerSheet extends StatelessWidget {
  final EphemeralDuration current;
  final bool perMessage;

  const _EphemeralPickerSheet({
    required this.current,
    required this.perMessage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final l10n = L10n.of(context);

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(FluffySpacing.md),
        decoration: BoxDecoration(
          color: cyber.glassFillStrong,
          borderRadius: FluffyRadius.brLg,
          border: Border.all(color: cyber.glassBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluffySpacing.lg,
                FluffySpacing.lg,
                FluffySpacing.lg,
                FluffySpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.timer, color: cyber.cyan, size: 20),
                  const SizedBox(width: FluffySpacing.sm),
                  Expanded(
                    child: Text(
                      perMessage
                          ? l10n.ephemeralPerMessageTitle
                          : l10n.ephemeralTitle,
                      style: FluffyTypography.title.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FluffySpacing.lg,
              ),
              child: Text(
                l10n.ephemeralDescription,
                style: FluffyTypography.bodyS.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: FluffySpacing.sm),
            ...EphemeralDuration.values.map((d) {
              final selected = d == current;
              return ListTile(
                leading: Icon(
                  EphemeralPicker.icon(d),
                  color: selected ? cyber.cyan : theme.colorScheme.onSurface,
                ),
                title: Text(EphemeralPicker.label(context, d)),
                trailing: selected
                    ? Icon(Icons.check, color: cyber.cyan)
                    : null,
                onTap: () => Navigator.of(context).pop(d),
              );
            }),
            const SizedBox(height: FluffySpacing.sm),
          ],
        ),
      ),
    );
  }
}
