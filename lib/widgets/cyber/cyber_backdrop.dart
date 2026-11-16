import 'package:fluffychat/config/cyber_themes.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/vox_perf_probe.dart';
import 'package:fluffychat/widgets/cyber/aurora_background.dart';
import 'package:fluffychat/widgets/cyber/starlink_background.dart';
import 'package:flutter/material.dart';

/// Theme-aware animated backdrop for conversation screens.
///
/// STARLINK preset gets its moving satellite-mesh constellation; every other
/// preset keeps the soft aurora blobs. Both honour the CYBERCORE perf
/// contract (no shader behind the timeline) and reduce-motion.
class CyberScreenBackdrop extends StatelessWidget {
  const CyberScreenBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    // Sonde de profiling : fond coupable couvert par ext.vox.perf.screenBackdrop
    // (éliminé en release). Attention au sens du test : la sonde n'éteint le
    // fond qu'en debug quand le drapeau est explicitement baissé ; en release
    // (`enabled` false) le fond doit rester actif — l'inverse (`!enabled ||`)
    // supprimait tout le fond en release (bug du 2026-11-16).
    if (VoxPerfProbe.enabled && !VoxPerfProbe.screenBackdrop) {
      return const SizedBox.shrink();
    }
    final isStarlink =
        AppSettings.cyberThemeId.value == CyberThemeId.starlink.name;
    if (isStarlink) {
      return const StarlinkBackground();
    }
    return const AuroraBackground();
  }
}
