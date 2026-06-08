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

/// Typography tokens — Sprint 2 V2.
///
/// 4 font families bundled :
///   - **Rajdhani** : titles, app bars, section headers (tech-futuriste)
///   - **Inter** : body, labels, input (lecture longue confortable)
///   - **JetBrainsMono** : code blocks, room IDs, event IDs, timestamps debug
///   - **Orbitron** : timer écran d'appel uniquement (decorative)
class FluffyTypography {
  static const String rajdhani = 'Rajdhani';
  static const String inter = 'Inter';
  static const String mono = 'JetBrainsMono';
  static const String orbitron = 'Orbitron';

  /// Les familles proposées pour la police des bulles de message, dans l'ordre
  /// du sélecteur de réglages. La clé '' = défaut (Inter).
  static const List<({String value, String label})> messageFontChoices = [
    (value: '', label: 'Inter (défaut)'),
    (value: rajdhani, label: 'Rajdhani'),
    (value: mono, label: 'JetBrains Mono'),
    (value: orbitron, label: 'Orbitron'),
  ];

  /// Résout la valeur stockée dans AppSettings.messageFontFamily vers une famille
  /// de police réelle. '' (ou inconnue) → Inter, la police de lecture par défaut.
  static String resolveMessageFont(String stored) {
    return messageFontChoices.any((c) => c.value == stored && stored.isNotEmpty)
        ? stored
        : inter;
  }

  static const TextStyle display = TextStyle(
    fontFamily: rajdhani,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.1,
  );
  static const TextStyle headlineL = TextStyle(
    fontFamily: rajdhani,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  static const TextStyle headlineM = TextStyle(
    fontFamily: rajdhani,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const TextStyle title = TextStyle(
    fontFamily: rajdhani,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle bodyL = TextStyle(
    fontFamily: inter,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const TextStyle bodyM = TextStyle(
    fontFamily: inter,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const TextStyle bodyS = TextStyle(
    fontFamily: inter,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static const TextStyle labelL = TextStyle(
    fontFamily: inter,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );
  static const TextStyle labelM = TextStyle(
    fontFamily: inter,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
  );
  static const TextStyle code = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const TextStyle timer = TextStyle(
    fontFamily: orbitron,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
  );

  /// Builds a Material 3 [TextTheme] consistent with these tokens, used by
  /// [FluffyThemes.buildTheme] so every widget reading from
  /// `Theme.of(context).textTheme` gets the fork typography.
  static TextTheme textThemeFor(ColorScheme scheme) {
    final body = scheme.onSurface;
    final heading = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    return TextTheme(
      displayLarge: display.copyWith(color: heading),
      displayMedium: display.copyWith(color: heading, fontSize: 28),
      displaySmall: headlineL.copyWith(color: heading),
      headlineLarge: headlineL.copyWith(color: heading),
      headlineMedium: headlineM.copyWith(color: heading),
      headlineSmall: title.copyWith(color: heading, fontSize: 18),
      titleLarge: title.copyWith(color: heading, fontSize: 18),
      titleMedium: title.copyWith(color: heading),
      titleSmall: title.copyWith(color: heading, fontSize: 14),
      bodyLarge: bodyL.copyWith(color: body),
      bodyMedium: bodyM.copyWith(color: body),
      bodySmall: bodyS.copyWith(color: muted),
      labelLarge: labelL.copyWith(color: body),
      labelMedium: labelM.copyWith(color: muted),
      labelSmall: labelM.copyWith(color: muted, fontSize: 10),
    );
  }
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
