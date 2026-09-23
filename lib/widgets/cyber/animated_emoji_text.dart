import 'package:animated_emoji/animated_emoji.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Compteur d'instances : [VisibilityDetector] exige une clé unique parmi TOUS
/// ses widgets dans l'app. Un compteur garantit l'unicité et reste stable pour
/// la durée de vie d'un State (contrairement à une clé dérivée du texte, qui
/// changerait si le parent recalcule la chaîne à chaque build).
int _kEmojiDetectorSeq = 0;

/// Rend une courte chaîne d'emojis (1 à [maxEmojis]) en versions ANIMÉES Noto
/// quand elles existent, avec repli sur le glyphe Unicode statique sinon.
///
/// Utilisé pour les messages « jumbo » (un message = quelques emojis seuls) et
/// les réactions. Les emojis non couverts par le pack animé (séquences ZWJ,
/// drapeaux, certaines combinaisons) tombent proprement sur le texte — jamais
/// de trou ni de crash.
///
/// ⚠️ Charge les animations depuis fonts.gstatic.com (réseau, choix assumé).
///
/// ## Coût raster — l'animation est pilotée par la VISIBILITÉ
///
/// `animated_emoji` boucle l'animation Lottie par défaut. Dans une liste qui
/// scrolle, chaque pastille de réaction / message jumbo visible maintenait donc
/// le thread raster occupé à CHAQUE frame : mesuré sur un Pixel 10 Pro XL, une
/// conversation en consommait ~1,3 cœur de CPU **en continu, au repos total**
/// (contre ~0 pour une conversation sans emoji animé). C'est le motif que le
/// contrat CYBERCORE interdit (« `.repeat()` interdit en liste »).
///
/// Ici chaque emoji est donc **au repos tant qu'il n'est pas vu**, animé tant
/// qu'il est visible (via [VisibilityDetector]), et remis au repos dès qu'il
/// sort du viewport. Hors écran : aucune frame Lottie produite.
class AnimatedEmojiText extends StatelessWidget {
  /// Le corps brut du message/réaction (supposé ne contenir que des emojis).
  final String text;

  /// Taille (côté) de chaque emoji animé, et taille de police du repli texte.
  final double size;

  /// Au-delà de ce nombre d'emojis, on ne tente PAS l'animation (trop d'anims
  /// simultanées = jank) et on rend tout en texte statique.
  final int maxEmojis;

  /// Quand false, les emojis restent statiques même visibles (aucune animation).
  final bool animateWhenVisible;

  /// Fraction de visibilité minimale pour déclencher l'animation. Un seuil > 0
  /// évite de démarrer pour un emoji qui n'est qu'à moitié révélé en bord
  /// d'écran pendant un scroll rapide.
  final double visibilityThreshold;

  const AnimatedEmojiText({
    required this.text,
    required this.size,
    this.maxEmojis = 3,
    this.animateWhenVisible = true,
    this.visibilityThreshold = 0.01,
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
        for (final cluster in clusters)
          _EmojiTextItem(
            cluster: cluster,
            size: size,
            animateWhenVisible: animateWhenVisible,
            visibilityThreshold: visibilityThreshold,
          ),
      ],
    );
  }
}

/// Un cluster d'emoji : animé Lottie quand il existe, glyphe Unicode sinon.
/// Bascule animation ⇄ repos selon sa visibilité réelle dans le viewport.
class _EmojiTextItem extends StatefulWidget {
  final String cluster;
  final double size;
  final bool animateWhenVisible;
  final double visibilityThreshold;

  const _EmojiTextItem({
    required this.cluster,
    required this.size,
    required this.animateWhenVisible,
    required this.visibilityThreshold,
  });

  @override
  State<_EmojiTextItem> createState() => _EmojiTextItemState();
}

class _EmojiTextItemState extends State<_EmojiTextItem> {
  /// Clé stable et unique, créée une seule fois pour la vie de ce State.
  final Key _detectorKey = ValueKey('emoji-${_kEmojiDetectorSeq++}');

  /// État initial = repos : rien ne tourne avant que la visibilité soit connue.
  bool _animating = false;

  @override
  Widget build(BuildContext context) {
    final fallback = Text(
      widget.cluster,
      style: TextStyle(fontSize: widget.size),
    );
    final data = AnimatedEmojis.fromEmojiString(widget.cluster);
    if (data == null) {
      // Repli : glyphe Unicode statique à la même taille optique.
      return fallback;
    }
    return VisibilityDetector(
      key: _detectorKey,
      onVisibilityChanged: (info) {
        // Le callback peut être livré après le démontage (batterie de callbacks
        // regroupés hors frame) → sans ce garde, setState sur un State démonté.
        if (!mounted) return;
        final shouldAnimate = widget.animateWhenVisible &&
            info.visibleFraction >= widget.visibilityThreshold;
        if (shouldAnimate != _animating) {
          setState(() => _animating = shouldAnimate);
        }
      },
      child: AnimatedEmoji(
        data,
        size: widget.size,
        // Boucle seulement tant que l'emoji est visible ; au repos (hors écran
        // ou animation désactivée) Lottie est figé et ne produit aucune frame.
        repeat: _animating,
        animate: _animating,
        // Si le réseau échoue (gstatic injoignable), on retombe sur le texte.
        errorWidget: fallback,
      ),
    );
  }
}
