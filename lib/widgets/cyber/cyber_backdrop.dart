import 'package:fluffychat/config/cyber_themes.dart';
import 'package:fluffychat/config/setting_keys.dart';
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
    final isStarlink =
        AppSettings.cyberThemeId.value == CyberThemeId.starlink.name;
    if (isStarlink) {
      return const StarlinkBackground();
    }
    return const AuroraBackground();
  }
}
