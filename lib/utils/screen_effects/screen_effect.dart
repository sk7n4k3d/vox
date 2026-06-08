/// Mode de rendu d'un effet plein écran.
enum ScreenEffectRender { particles, lottie }

/// Les effets plein écran disponibles (style iMessage/Telegram).
enum ScreenEffect {
  confetti,
  fireworks,
  hearts,
  snow,
  balloons,
  celebration,
  fire,
}

extension ScreenEffectMeta on ScreenEffect {
  ScreenEffectRender get render => switch (this) {
        ScreenEffect.confetti => ScreenEffectRender.particles,
        _ => ScreenEffectRender.lottie,
      };

  /// Chemin de l'asset Lottie (vide pour les effets en particules).
  String get assetPath => switch (this) {
        ScreenEffect.confetti => '',
        ScreenEffect.fireworks => 'assets/effects/fireworks.json',
        ScreenEffect.hearts => 'assets/effects/hearts.json',
        ScreenEffect.snow => 'assets/effects/snow.json',
        ScreenEffect.balloons => 'assets/effects/balloons.json',
        ScreenEffect.celebration => 'assets/effects/celebration.json',
        ScreenEffect.fire => 'assets/effects/fire.json',
      };

  /// Emoji représentatif (vignette du menu manuel + insertion déclencheur).
  String get emoji => switch (this) {
        ScreenEffect.confetti => '🎉',
        ScreenEffect.fireworks => '🎆',
        ScreenEffect.hearts => '❤️',
        ScreenEffect.snow => '❄️',
        ScreenEffect.balloons => '🎂',
        ScreenEffect.celebration => '🥳',
        ScreenEffect.fire => '🔥',
      };

  /// Libellé FR pour le menu manuel.
  String get label => switch (this) {
        ScreenEffect.confetti => 'Confettis',
        ScreenEffect.fireworks => 'Feux d\'artifice',
        ScreenEffect.hearts => 'Cœurs',
        ScreenEffect.snow => 'Neige',
        ScreenEffect.balloons => 'Ballons',
        ScreenEffect.celebration => 'Fête',
        ScreenEffect.fire => 'Feu',
      };
}
