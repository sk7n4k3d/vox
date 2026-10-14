import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// Palette et formes propres aux écrans d'appel.
///
/// Ne réinvente rien : part de [CyberpunkTheme] (la source unique du thème VOX,
/// déjà utilisée par l'app bar liquid-glass et les réglages) et n'ajoute que ce
/// qui est propre à un appel — vert répondre, rouge raccrocher, fond noir de
/// l'écran plein écran.
abstract final class CallTheme {
  /// Vert « répondre ». Distinct du [CyberpunkTheme.success], plus doux.
  static const Color answer = Color(0xFF05FFA1);

  /// Rouge « raccrocher ».
  static const Color decline = Color(0xFFFF2E92);

  /// Fond de l'écran d'appel : noir profond, le dégradé du CyberBackdrop
  /// passerait bien mais coûte un frame de plus au moment de la sonnerie.
  static const Color background = Color(0xFF05070A);

  /// Rayon des boutons circulaires de contrôle.
  static const double controlRadius = 36;

  static CyberpunkTheme of(BuildContext context) => CyberColors.of(context);

  /// Fond de verre standard des panneaux de contrôle sur fond noir.
  static Color controlSurface(CyberpunkTheme cyber, {bool active = false}) =>
      active ? cyber.cyan.withValues(alpha: 0.22) : cyber.glassBorder;
}