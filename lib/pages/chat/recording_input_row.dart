import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat_input_row.dart';
import 'package:fluffychat/pages/chat/recording_view_model.dart';
import 'package:fluffychat/widgets/cyber/neon_waveform.dart';
import 'package:flutter/material.dart';

class RecordingInputRow extends StatelessWidget {
  final RecordingViewModelState state;
  final Future<void> Function(String, int, List<int>, String) onSend;
  const RecordingInputRow({
    required this.state,
    required this.onSend,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ChatInputRow.height,
      child: state.isLocked ? _buildLockedRow(context) : _buildLiveHoldRow(context),
    );
  }

  Widget _buildLockedRow(BuildContext context) {
    final theme = Theme.of(context);
    final time =
        '${state.duration.inMinutes.toString().padLeft(2, '0')}:${(state.duration.inSeconds % 60).toString().padLeft(2, '0')}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const SizedBox(width: 8),
        Container(
          alignment: Alignment.center,
          width: 48,
          child: IconButton(
            tooltip: L10n.of(context).cancel,
            icon: const Icon(Icons.delete_outlined),
            color: theme.colorScheme.error,
            onPressed: state.cancel,
          ),
        ),
        if (state.isPaused)
          Container(
            alignment: Alignment.center,
            width: 48,
            child: IconButton(
              tooltip: L10n.of(context).resume,
              icon: const Icon(Icons.play_circle_outline_outlined),
              onPressed: state.resume,
            ),
          )
        else
          Container(
            alignment: Alignment.center,
            width: 48,
            child: IconButton(
              tooltip: L10n.of(context).pause,
              icon: const Icon(Icons.pause_circle_outline_outlined),
              onPressed: state.pause,
            ),
          ),
        Text(time),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const barWidth = 4.0;
              final maxBars = (constraints.maxWidth / (barWidth + 2)).floor();
              final amps = state.amplitudeTimeline.reversed
                  .take(maxBars)
                  .toList()
                  .reversed
                  .toList();
              return Align(
                alignment: Alignment.centerRight,
                child: NeonWaveform(
                  amplitudes: amps,
                  maxBarHeight: 36,
                  barWidth: barWidth,
                ),
              );
            },
          ),
        ),
        IconButton(
          style: IconButton.styleFrom(
            disabledBackgroundColor: theme.bubbleColor.withAlpha(128),
            backgroundColor: theme.bubbleColor,
            foregroundColor: theme.onBubbleColor,
          ),
          tooltip: L10n.of(context).sendAudio,
          icon: state.isSending
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator.adaptive(),
                )
              : const Icon(Icons.send_outlined),
          onPressed: state.isSending ? null : () => state.stopAndSend(onSend),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildLiveHoldRow(BuildContext context) {
    final theme = Theme.of(context);
    final time =
        '${state.duration.inMinutes.toString().padLeft(2, '0')}:${(state.duration.inSeconds % 60).toString().padLeft(2, '0')}';
    final opacity = state.isCancelling ? 0.4 : 1.0;
    return AnimatedOpacity(
      opacity: opacity,
      duration: FluffyDurations.fast,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 16),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            time,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const barWidth = 4.0;
                final maxBars = (constraints.maxWidth / (barWidth + 2)).floor();
                final amps = state.amplitudeTimeline.reversed
                    .take(maxBars)
                    .toList()
                    .reversed
                    .toList();
                return Align(
                  alignment: Alignment.centerRight,
                  child: NeonWaveform(
                    amplitudes: amps,
                    maxBarHeight: 36,
                    barWidth: barWidth,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 64),
        ],
      ),
    );
  }
}
