# Contrat d'ANIMATION CYBERCORE — appliqué par chaque agent

## Règle d'or (identique à la refonte)
Modifier UNIQUEMENT la présentation/animation. Aucune logique métier, controller,
callback, condition, routing, appel SDK ne change. Préserver toutes les Key().

## Briques d'animation dispo (imports)
```dart
import 'package:fluffychat/widgets/cyber/cyber_fx.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:flutter_animate/flutter_animate.dart'; // déjà dans les deps
```
- `CyberGlitchText('TITRE', style:)` — titre qui se révèle en glitch au 1er paint
  puis statique. Fallback Text plat sous reduce-motion. POUR LES TITRES D'APPBAR /
  HEADERS DE PAGE STATIQUES.
- `CyberNeonFrame(child:, color:)` — cadre néon glow shader autour d'un élément
  STATIQUE (bouton, carte mise en avant, avatar de header). JAMAIS dans une liste.
- `flutter_animate` : `.animate().fadeIn().slideY()` pour les entrées staggered de
  blocs statiques (en-têtes, cartes de réglage au 1er affichage). Bornes courtes
  (FluffyDurations.fast/normal), `.animate(onPlay: (c) => c.stop())` si one-shot.

## RÈGLES PERF ABSOLUES (non négociables — leçon de l'audit)
1. AUCUN effet shader (CyberNeonFrame, glow_effects) derrière une ListView /
   timeline / liste qui scrolle. Coût GPU permanent = jank garanti.
2. Les animations dans des items de liste = uniquement entrées one-shot légères
   (fadeIn/slideY <= 300ms), jamais en boucle (`.repeat()` interdit en liste).
3. Titres d'AppBar : CyberGlitchText OK (1 par écran, statique après reveal).
4. Toujours fallback reduce-motion (les briques Cyber* le gèrent déjà ;
   pour flutter_animate, wrapper d'un check `MediaQuery.disableAnimationsOf(context)`).

## OÙ appliquer quoi (par écran)
- Titre de page / AppBar title (texte) → CyberGlitchText (effet d'entrée).
- En-têtes de section settings (CyberSectionHeader déjà là) → ajouter
  `.animate().fadeIn(duration: FluffyDurations.fast).slideX(begin: -0.1)` one-shot.
- Boutons d'action primaires → déjà animés (sweep intégré au CyberPrimaryButton),
  NE PAS doubler.
- Avatar de header de page (chat_details, profile) → CyberNeonFrame autour (statique).
- Listes de messages / rooms / membres → NE RIEN animer en continu. OK: entrée
  staggered one-shot déjà en place (ne pas y toucher).

## Qualité
- flutter analyze : zéro nouveau warning, imports triés, pas d'import inutile.
- const partout où possible. Préserver les Key().
- Ne pas lancer analyze/build (fait globalement après).
