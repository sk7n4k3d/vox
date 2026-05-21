import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/playback_speed_controller.dart';
import 'package:flutter/material.dart';

class AudioSpeedBottomSheet extends StatelessWidget {
  const AudioSpeedBottomSheet({super.key});

  String _formatSpeed(double s) =>
      s == s.truncateToDouble() ? '${s.toInt()}x' : '${s}x';

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text(
                l10n.playbackSpeed,
                style: theme.textTheme.titleMedium,
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: playbackSpeedController,
              builder: (context, currentSpeed, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final preset in PlaybackSpeedController.presets)
                      RadioListTile<double>(
                        title: Text(_formatSpeed(preset)),
                        value: preset,
                        groupValue: currentSpeed,
                        onChanged: (selected) async {
                          if (selected == null) return;
                          await playbackSpeedController.setSpeed(selected);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
