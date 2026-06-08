import 'package:animated_emoji/animated_emoji.dart';
import 'package:flutter/material.dart';

/// Rend une courte chaîne d'emojis (1 à [maxEmojis]) en versions ANIMÉES Noto
/// quand elles existent, avec repli sur le glyphe Unicode statique sinon.
///
/// Utilisé pour les messages « jumbo » (un message = quelques emojis seuls) et
/// les réactions. Les emojis non couverts par le pack animé (séquences ZWJ,
/// drapeaux, certaines combinaisons) tombent proprement sur le texte — jamais
/// de trou ni de crash.
///
/// ⚠️ Charge les animations depuis fonts.gstatic.com (réseau, choix assumé).
class AnimatedEmojiText extends StatelessWidget {
  /// Le corps brut du message/réaction (supposé ne contenir que des emojis).
  final String text;

  /// Taille (côté) de chaque emoji animé, et taille de police du repli texte.
  final double size;

  /// Au-delà de ce nombre d'emojis, on ne tente PAS l'animation (trop d'anims
  /// simultanées = jank) et on rend tout en texte statique.
  final int maxEmojis;

  const AnimatedEmojiText({
    required this.text,
    required this.size,
    this.maxEmojis = 3,
    super.key,
  });

  /// True si [body] est une suite courte d'emojis tous animables → vaut le coup
  /// de basculer en rendu animé. Sinon on laisse le rendu texte habituel.
  static bool hasAnimatable(String body, {int maxEmojis = 3}) {
    final clusters = body.characters.toList();
    if (clusters.isEmpty || clusters.length > maxEmojis) return false;
    return clusters.any((c) => AnimatedEmojis.fromEmojiString(c) != null);
  }

  @override
  Widget build(BuildContext context) {
    final clusters = text.characters.toList();
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final c in clusters) _emoji(c),
      ],
    );
  }

  Widget _emoji(String cluster) {
    final data = AnimatedEmojis.fromEmojiString(cluster);
    if (data == null) {
      // Repli : glyphe Unicode statique à la même taille optique.
      return Text(cluster, style: TextStyle(fontSize: size));
    }
    return AnimatedEmoji(
      data,
      size: size,
      // Si le réseau échoue (gstatic injoignable), on retombe sur le texte.
      errorWidget: Text(cluster, style: TextStyle(fontSize: size)),
    );
  }
}
