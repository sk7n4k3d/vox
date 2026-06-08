import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:flutter/material.dart';

/// Waveform néon : barres d'amplitude avec dégradé cyan→magenta et glow sur les
/// pics. Pur affichage (aucune logique d'enregistrement). [amplitudes] est une
/// liste de valeurs ~0..100 (cf. RecordingViewModel.amplitudeTimeline).
class NeonWaveform extends StatelessWidget {
  final List<double> amplitudes;
  final double maxBarHeight;
  final double barWidth;

  const NeonWaveform({
    required this.amplitudes,
    this.maxBarHeight = 36,
    this.barWidth = 4,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cyber =
        Theme.of(context).extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < amplitudes.length; i++)
          _bar(cyber, i, amplitudes[i]),
      ],
    );
  }

  Widget _bar(CyberpunkTheme cyber, int i, double amplitude) {
    final h = (maxBarHeight * (amplitude / 100)).clamp(2.0, maxBarHeight);
    final hot = amplitude > 70;
    return Container(
      key: ValueKey('wave_bar_$i'),
      margin: const EdgeInsets.only(left: 2),
      width: barWidth,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(barWidth),
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [cyber.cyan, cyber.magenta],
        ),
        boxShadow: hot
            ? [BoxShadow(color: cyber.cyan.withValues(alpha: 0.5), blurRadius: 6)]
            : null,
      ),
    );
  }
}
