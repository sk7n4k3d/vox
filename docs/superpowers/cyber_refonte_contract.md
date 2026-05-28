# Contrat de refonte CYBERCORE — à respecter STRICTEMENT par chaque agent

## Règle d'or
Refondre l'ESTHÉTIQUE uniquement. NE JAMAIS modifier la logique métier, les
controllers, les callbacks, les conditions, le routing, les appels SDK Matrix.
Seuls les widgets de présentation changent. Si un doute sur la logique → ne pas
toucher.

## Design system — source de vérité (imports)
```dart
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
```
- `final cyber = CyberColors.of(context);` → cyan #00F0FF, magenta #FF2E92,
  violet #A78BFA, warn #FCEE0A (jaune néon), success #05FFA1 (vert néon),
  neonGlow, glassFillLight/Strong, glassBorder, blurSigma*.
- `FluffySpacing` xxs..xxxxl (2/4/8/12/16/24/32/48/64) — JAMAIS de padding magique.
- `FluffyRadius` brSm/brMd/brLg/brXl/brStadium/brFull.
- `FluffyDurations` instant/fast/normal/medium/slow/xslow + `FluffyCurves`.
- `FluffyTypography` display/headlineL/M/title/bodyL/M/S/labelL/M/code + `.copyWith(color:)`.
- `FluffyElevation.glowCyan/Magenta/Violet(color)`.

## Briques réutilisables (privilégier)
- `CyberGlass(child:, onTap:, glow:, tint:)` — surface glass + hairline + blur.
- `CyberSettingsTile(icon:, accent:, title:, subtitle:, trailing:, onTap:)` —
  ligne de réglage avec chip icône colorée.
- `CyberSectionHeader('LABEL', accent:)` — en-tête de section Rajdhani uppercase.
- `CyberField(focused:, child:)` — wrapper champ glass (focus = bordure cyan glow).
- `CyberPrimaryButton(label:, icon:, loading:, onPressed:)` — CTA gradient cyan→magenta.
- `CyberBackdrop(animation:, child:)` — fond mesh animé (auth/immersif).

## Conventions visuelles
1. Couleurs d'accent par catégorie : sécurité/privacy → success ou cyan,
   notifications → magenta, devices/threads/spaces → violet, warnings → warn,
   actions principales → gradient cyan→magenta.
2. Les `AppBar` : laisser le `AppBar` standard MAIS `backgroundColor:
   Colors.transparent`, `elevation: 0`, titre en `FluffyTypography.headlineM`
   ou via textTheme (Rajdhani hérité). Si scaffold dark, garder.
3. `ElevatedButton`/`FilledButton` d'action primaire → `CyberPrimaryButton`.
4. `ListTile` de réglage → `CyberSettingsTile` quand ça colle (sinon teinter
   l'icône en cyber.cyan et titre Rajdhani).
5. `SwitchListTile`/`Switch` → `activeColor: cyber.cyan` ou
   `activeTrackColor: cyber.cyan.withValues(alpha: 0.4)`.
6. Icônes colorées en `cyber.cyan` (neutres), accents selon catégorie.
7. Cartes/sections → envelopper dans `CyberGlass` ou Container glass.
8. Avatars de contacts → réutiliser `AvatarWithStatusRing` si liste de membres.
9. Aucune couleur hardcodée type `Colors.orange`/`Colors.black` sur fond dark :
   remplacer par tokens (`cyber.warn`, `theme.colorScheme.onSurface*`).
10. Texte d'erreur → `cyber.warn`. Texte destructif/danger → `cyber.magenta` ou
    `theme.colorScheme.error`.

## Qualité
- Respecter le `flutter analyze` : zéro nouveau warning, pas d'import inutile,
  imports triés (dart: puis package: alpha).
- Ne pas casser les `Key` existantes (tests/intégration en dépendent).
- Préserver l'accessibilité (tooltips, semantics, tailles de tap >= 40).
- Garder les `const` partout où possible.
