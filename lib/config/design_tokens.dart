import 'package:flutter/material.dart';

/// Design system V2 — Sprint 2 — tokens dérivés de l'audit AUDIT-FLUFFYCHAT-FORK-2026-05-23.
///
/// Source of truth pour spacing, radius, motion, elevation et typography.
/// Couleurs gérées par [CyberpunkTheme] ThemeExtension. Ces tokens sont
/// statiques (pas de lerp inter-themes) pour éviter le coût ThemeExtension.

class FluffySpacing {
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;
  static const double xxxxl = 64.0;
}

class FluffyRadius {
  static const Radius sm = Radius.circular(8);
  static const Radius md = Radius.circular(12);
  static const Radius lg = Radius.circular(16);
  static const Radius xl = Radius.circular(20);
  static const Radius stadium = Radius.circular(28);
  static const Radius full = Radius.circular(999);

  static const BorderRadius brSm = BorderRadius.all(sm);
  static const BorderRadius brMd = BorderRadius.all(md);
  static const BorderRadius brLg = BorderRadius.all(lg);
  static const BorderRadius brXl = BorderRadius.all(xl);
  static const BorderRadius brStadium = BorderRadius.all(stadium);
  static const BorderRadius brFull = BorderRadius.all(full);
}

class FluffyDurations {
  static const Duration instant = Duration(milliseconds: 100);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 380);
  static const Duration xslow = Duration(milliseconds: 500);
}

class FluffyCurves {
  static const Curve standard = Curves.easeInOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve decelerated = Curves.easeOutCubic;
  static const Curve accelerated = Curves.easeInCubic;

  static const SpringDescription spring = SpringDescription(
    mass: 1.0,
    stiffness: 180.0,
    damping: 20.0,
  );

  static const SpringDescription springTight = SpringDescription(
    mass: 1.0,
    stiffness: 380.0,
    damping: 28.0,
  );
}

class FluffyElevation {
  static List<BoxShadow> glowCyan(Color cyan, {double alpha = 0.35}) => [
        BoxShadow(
          color: cyan.withValues(alpha: alpha),
          blurRadius: 12,
          spreadRadius: 0,
        ),
      ];

  static List<BoxShadow> glowMagenta(Color magenta, {double alpha = 0.35}) => [
        BoxShadow(
          color: magenta.withValues(alpha: alpha),
          blurRadius: 12,
          spreadRadius: 0,
        ),
      ];

  static List<BoxShadow> glowViolet(Color violet, {double alpha = 0.35}) => [
        BoxShadow(
          color: violet.withValues(alpha: alpha),
          blurRadius: 12,
          spreadRadius: 0,
        ),
      ];

  static const BoxShadow shadow1 = BoxShadow(
    color: Color(0x33000000),
    blurRadius: 8,
    offset: Offset(0, 2),
  );
  static const BoxShadow shadow2 = BoxShadow(
    color: Color(0x4D000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  );
  static const BoxShadow shadow3 = BoxShadow(
    color: Color(0x66000000),
    blurRadius: 32,
    offset: Offset(0, 12),
  );
}
