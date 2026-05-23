import 'package:flutter/material.dart';

/// Cyberpunk hybrid theme tokens layered on top of Material 3.
///
/// Sprint 2 — bascule palette CYBERCORE (`#00F0FF` / `#FF2E92` / `#A78BFA`).
/// L'identité du fork est dark-first ; le `light()` constructor a été retiré
/// (audit AUDIT-FLUFFYCHAT-FORK-2026-05-23 finding-001) car il dupliquait `.dark()`.
/// Le ThemeMode est forcé à `dark` dans `themes.dart`.
///
/// ```dart
/// final cyber = Theme.of(context).extension<CyberpunkTheme>()!;
/// ```
@immutable
class CyberpunkTheme extends ThemeExtension<CyberpunkTheme> {
  /// Online presence + E2EE OK indicator.
  final Color cyan;

  /// Mentions, errors, CTA highlights.
  final Color magenta;

  /// Spaces and threads accent.
  final Color violet;

  /// Warning (yellow néon CYBERCORE).
  final Color warn;

  /// Success (green néon CYBERCORE).
  final Color success;

  /// Reusable neon glow effect (blur 12, cyan tinted @ ~35% alpha).
  final List<BoxShadow> neonGlow;

  /// Glass fill for low-emphasis surfaces (chips, hint pills).
  final Color glassFillLight;

  /// Glass fill for high-emphasis surfaces (bottom sheets, dialogs).
  final Color glassFillStrong;

  /// Border color matching the glass fills (1px hairline).
  final Color glassBorder;

  /// BackdropFilter sigma for chip-sized surfaces.
  final double blurSigmaChip;

  /// BackdropFilter sigma for bottom sheets.
  final double blurSigmaSheet;

  /// BackdropFilter sigma for full-screen overlays / scrims.
  final double blurSigmaOverlay;

  /// BackdropFilter sigma applied behind the app bar in immersive mode.
  final double blurSigmaAppBar;

  /// Material 3 Expressive emphasized-decelerated curve used by the upcoming
  /// motion language.
  final Curve emphasizedDeceleratedCurve;

  const CyberpunkTheme({
    required this.cyan,
    required this.magenta,
    required this.violet,
    required this.warn,
    required this.success,
    required this.neonGlow,
    required this.glassFillLight,
    required this.glassFillStrong,
    required this.glassBorder,
    required this.blurSigmaChip,
    required this.blurSigmaSheet,
    required this.blurSigmaOverlay,
    required this.blurSigmaAppBar,
    required this.emphasizedDeceleratedCurve,
  });

  /// Tokens dark cyberpunk (CYBERCORE palette).
  factory CyberpunkTheme.dark() {
    const cyan = Color(0xFF00F0FF);
    const magenta = Color(0xFFFF2E92);
    const violet = Color(0xFFA78BFA);
    const warn = Color(0xFFFCEE0A);
    const success = Color(0xFF05FFA1);
    return CyberpunkTheme(
      cyan: cyan,
      magenta: magenta,
      violet: violet,
      warn: warn,
      success: success,
      neonGlow: [
        BoxShadow(
          color: cyan.withValues(alpha: 0.35),
          blurRadius: 12,
          spreadRadius: 0,
        ),
      ],
      glassFillLight: Colors.white.withValues(alpha: 0.12),
      glassFillStrong: Colors.white.withValues(alpha: 0.18),
      glassBorder: Colors.white.withValues(alpha: 0.18),
      blurSigmaChip: 8.0,
      blurSigmaSheet: 24.0,
      blurSigmaOverlay: 36.0,
      blurSigmaAppBar: 20.0,
      emphasizedDeceleratedCurve: Curves.easeInOutCubicEmphasized,
    );
  }

  @override
  CyberpunkTheme copyWith({
    Color? cyan,
    Color? magenta,
    Color? violet,
    Color? warn,
    Color? success,
    List<BoxShadow>? neonGlow,
    Color? glassFillLight,
    Color? glassFillStrong,
    Color? glassBorder,
    double? blurSigmaChip,
    double? blurSigmaSheet,
    double? blurSigmaOverlay,
    double? blurSigmaAppBar,
    Curve? emphasizedDeceleratedCurve,
  }) {
    return CyberpunkTheme(
      cyan: cyan ?? this.cyan,
      magenta: magenta ?? this.magenta,
      violet: violet ?? this.violet,
      warn: warn ?? this.warn,
      success: success ?? this.success,
      neonGlow: neonGlow ?? this.neonGlow,
      glassFillLight: glassFillLight ?? this.glassFillLight,
      glassFillStrong: glassFillStrong ?? this.glassFillStrong,
      glassBorder: glassBorder ?? this.glassBorder,
      blurSigmaChip: blurSigmaChip ?? this.blurSigmaChip,
      blurSigmaSheet: blurSigmaSheet ?? this.blurSigmaSheet,
      blurSigmaOverlay: blurSigmaOverlay ?? this.blurSigmaOverlay,
      blurSigmaAppBar: blurSigmaAppBar ?? this.blurSigmaAppBar,
      emphasizedDeceleratedCurve:
          emphasizedDeceleratedCurve ?? this.emphasizedDeceleratedCurve,
    );
  }

  @override
  CyberpunkTheme lerp(ThemeExtension<CyberpunkTheme>? other, double t) {
    if (other is! CyberpunkTheme) return this;
    return CyberpunkTheme(
      cyan: Color.lerp(cyan, other.cyan, t) ?? cyan,
      magenta: Color.lerp(magenta, other.magenta, t) ?? magenta,
      violet: Color.lerp(violet, other.violet, t) ?? violet,
      warn: Color.lerp(warn, other.warn, t) ?? warn,
      success: Color.lerp(success, other.success, t) ?? success,
      neonGlow:
          BoxShadow.lerpList(neonGlow, other.neonGlow, t) ?? neonGlow,
      glassFillLight:
          Color.lerp(glassFillLight, other.glassFillLight, t) ?? glassFillLight,
      glassFillStrong:
          Color.lerp(glassFillStrong, other.glassFillStrong, t) ??
              glassFillStrong,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t) ?? glassBorder,
      blurSigmaChip: _lerpDouble(blurSigmaChip, other.blurSigmaChip, t),
      blurSigmaSheet: _lerpDouble(blurSigmaSheet, other.blurSigmaSheet, t),
      blurSigmaOverlay:
          _lerpDouble(blurSigmaOverlay, other.blurSigmaOverlay, t),
      blurSigmaAppBar: _lerpDouble(blurSigmaAppBar, other.blurSigmaAppBar, t),
      emphasizedDeceleratedCurve:
          t < 0.5 ? emphasizedDeceleratedCurve : other.emphasizedDeceleratedCurve,
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CyberpunkTheme) return false;
    return cyan == other.cyan &&
        magenta == other.magenta &&
        violet == other.violet &&
        warn == other.warn &&
        success == other.success &&
        _listEquals(neonGlow, other.neonGlow) &&
        glassFillLight == other.glassFillLight &&
        glassFillStrong == other.glassFillStrong &&
        glassBorder == other.glassBorder &&
        blurSigmaChip == other.blurSigmaChip &&
        blurSigmaSheet == other.blurSigmaSheet &&
        blurSigmaOverlay == other.blurSigmaOverlay &&
        blurSigmaAppBar == other.blurSigmaAppBar &&
        emphasizedDeceleratedCurve == other.emphasizedDeceleratedCurve;
  }

  @override
  int get hashCode => Object.hash(
        cyan,
        magenta,
        violet,
        warn,
        success,
        Object.hashAll(neonGlow),
        glassFillLight,
        glassFillStrong,
        glassBorder,
        blurSigmaChip,
        blurSigmaSheet,
        blurSigmaOverlay,
        blurSigmaAppBar,
        emphasizedDeceleratedCurve,
      );

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
