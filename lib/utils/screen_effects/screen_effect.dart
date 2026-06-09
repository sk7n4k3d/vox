/// Mode de rendu d'un effet plein écran.
/// - particles : confettis via flutter_confetti
/// - snowfall  : flocons qui tombent (particules, plein écran)
/// - rainfall  : pluie qui tombe (particules bleues fines, plein écran)
/// - sparkle   : étoiles/paillettes qui scintillent (particules dorées/cyan)
/// - burning   : « l'app prend feu » (flammes montantes custom)
/// - lottie    : animation Lottie bundlée
enum ScreenEffectRender { particles, snowfall, rainfall, sparkle, burning, lottie }

/// Les effets plein écran disponibles (style iMessage/Telegram).
enum ScreenEffect {
  confetti,
  fireworks,
  hearts,
  snow,
  balloons,
  celebration,
  fire,
  rain,
  sparkle,
  kiss,
  party,
}

extension ScreenEffectMeta on ScreenEffect {
  ScreenEffectRender get render => switch (this) {
        ScreenEffect.confetti => ScreenEffectRender.particles,
        ScreenEffect.party => ScreenEffectRender.particles,
        ScreenEffect.snow => ScreenEffectRender.snowfall,
        ScreenEffect.rain => ScreenEffectRender.rainfall,
        ScreenEffect.sparkle => ScreenEffectRender.sparkle,
        ScreenEffect.fire => ScreenEffectRender.burning,
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
        // kiss réutilise l'anim cœurs ; rain/sparkle/party sont en particules.
        ScreenEffect.kiss => 'assets/effects/hearts.json',
        ScreenEffect.rain => '',
        ScreenEffect.sparkle => '',
        ScreenEffect.party => '',
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
        ScreenEffect.rain => '🌧️',
        ScreenEffect.sparkle => '✨',
        ScreenEffect.kiss => '💋',
        ScreenEffect.party => '🎈',
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
        ScreenEffect.rain => 'Pluie',
        ScreenEffect.sparkle => 'Paillettes',
        ScreenEffect.kiss => 'Bisous',
        ScreenEffect.party => 'Grande fête',
      };
}
