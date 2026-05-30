import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:flutter/material.dart';

/// Premium theme presets selectable in Settings > Appearance.
///
/// Each preset bundles a Material seed color (drives the [ColorScheme]) and a
/// matching [CyberpunkTheme] accent set (cyan/magenta/violet/warn/success used
/// by every CYBERCORE widget). Switching preset re-skins the whole app.
enum CyberThemeId {
  /// Ultra-futuristic #1 — the original cyan/magenta/violet neon identity.
  cybercore,

  /// Ultra-futuristic #2 — electric green + cyan terminal/Matrix vibe.
  nexus,

  /// Premium — soft violet / rose / indigo dusk.
  aurora,

  /// Premium — warm amber / orange / red ember.
  ember,

  /// Premium — minimal monochrome with a single cool accent.
  monochrome,
}

class CyberThemePreset {
  final CyberThemeId id;
  final String label;
  final String description;
  final Color seed;
  final CyberpunkTheme tokens;

  const CyberThemePreset({
    required this.id,
    required this.label,
    required this.description,
    required this.seed,
    required this.tokens,
  });

  /// The accent shown in the picker swatch.
  Color get swatch => tokens.cyan;
}

class CyberThemes {
  const CyberThemes._();

  static const List<CyberThemePreset> all = [
    CyberThemePreset(
      id: CyberThemeId.cybercore,
      label: 'CYBERCORE',
      description: 'Cyan · Magenta · Violet — néon ultra-futuriste',
      seed: Color(0xFF00F0FF),
      tokens: CyberpunkTheme(
        cyan: Color(0xFF00F0FF),
        magenta: Color(0xFFFF2E92),
        violet: Color(0xFFA78BFA),
        warn: Color(0xFFFCEE0A),
        success: Color(0xFF05FFA1),
        neonGlow: [BoxShadow(color: Color(0x5900F0FF), blurRadius: 12)],
        glassFillLight: Color(0x1FFFFFFF),
        glassFillStrong: Color(0x2EFFFFFF),
        glassBorder: Color(0x2EFFFFFF),
        blurSigmaChip: 8.0,
        blurSigmaSheet: 24.0,
        blurSigmaOverlay: 36.0,
        blurSigmaAppBar: 20.0,
        emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
      ),
    ),
    CyberThemePreset(
      id: CyberThemeId.nexus,
      label: 'NEXUS',
      description: 'Vert électrique · Cyan — terminal/Matrix',
      seed: Color(0xFF00FF9C),
      tokens: CyberpunkTheme(
        cyan: Color(0xFF00FF9C),
        magenta: Color(0xFF00E5FF),
        violet: Color(0xFF7CFFB2),
        warn: Color(0xFFE8FF3B),
        success: Color(0xFF00FF9C),
        neonGlow: [BoxShadow(color: Color(0x5900FF9C), blurRadius: 12)],
        glassFillLight: Color(0x1FFFFFFF),
        glassFillStrong: Color(0x2EFFFFFF),
        glassBorder: Color(0x2E7CFFB2),
        blurSigmaChip: 8.0,
        blurSigmaSheet: 24.0,
        blurSigmaOverlay: 36.0,
        blurSigmaAppBar: 20.0,
        emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
      ),
    ),
    CyberThemePreset(
      id: CyberThemeId.aurora,
      label: 'AURORA',
      description: 'Violet · Rose · Indigo — premium doux',
      seed: Color(0xFF9D7BFF),
      tokens: CyberpunkTheme(
        cyan: Color(0xFF9D7BFF),
        magenta: Color(0xFFFF7BC2),
        violet: Color(0xFF6C8BFF),
        warn: Color(0xFFFFD36E),
        success: Color(0xFF7BFFD3),
        neonGlow: [BoxShadow(color: Color(0x599D7BFF), blurRadius: 12)],
        glassFillLight: Color(0x1FFFFFFF),
        glassFillStrong: Color(0x2EFFFFFF),
        glassBorder: Color(0x2EFFFFFF),
        blurSigmaChip: 8.0,
        blurSigmaSheet: 24.0,
        blurSigmaOverlay: 36.0,
        blurSigmaAppBar: 20.0,
        emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
      ),
    ),
    CyberThemePreset(
      id: CyberThemeId.ember,
      label: 'EMBER',
      description: 'Ambre · Orange · Rouge — premium chaud',
      seed: Color(0xFFFF9E3D),
      tokens: CyberpunkTheme(
        cyan: Color(0xFFFFB24D),
        magenta: Color(0xFFFF5A5F),
        violet: Color(0xFFFFCF6E),
        warn: Color(0xFFFFE08A),
        success: Color(0xFF7BFFB2),
        neonGlow: [BoxShadow(color: Color(0x59FF9E3D), blurRadius: 12)],
        glassFillLight: Color(0x1FFFFFFF),
        glassFillStrong: Color(0x2EFFFFFF),
        glassBorder: Color(0x2EFFFFFF),
        blurSigmaChip: 8.0,
        blurSigmaSheet: 24.0,
        blurSigmaOverlay: 36.0,
        blurSigmaAppBar: 20.0,
        emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
      ),
    ),
    CyberThemePreset(
      id: CyberThemeId.monochrome,
      label: 'MONOCHROME',
      description: 'Blanc · Gris · accent froid — premium minimal',
      seed: Color(0xFFB8C4D0),
      tokens: CyberpunkTheme(
        cyan: Color(0xFFEAF2FF),
        magenta: Color(0xFF8FA8C4),
        violet: Color(0xFFB8C4D0),
        warn: Color(0xFFFFD36E),
        success: Color(0xFF9FE8C4),
        neonGlow: [BoxShadow(color: Color(0x40EAF2FF), blurRadius: 10)],
        glassFillLight: Color(0x14FFFFFF),
        glassFillStrong: Color(0x24FFFFFF),
        glassBorder: Color(0x24FFFFFF),
        blurSigmaChip: 8.0,
        blurSigmaSheet: 24.0,
        blurSigmaOverlay: 36.0,
        blurSigmaAppBar: 20.0,
        emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
      ),
    ),
  ];

  static CyberThemePreset byId(CyberThemeId id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);

  static CyberThemePreset byName(String? name) {
    if (name == null) return all.first;
    return all.firstWhere(
      (p) => p.id.name == name,
      orElse: () => all.first,
    );
  }
}
