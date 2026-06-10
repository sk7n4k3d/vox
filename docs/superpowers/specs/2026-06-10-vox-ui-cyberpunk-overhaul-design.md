# Refonte animations cyberpunk VOX — run autonome de nuit (2026-06-10)

> Décisions prises EN AUTONOMIE (Bastien dort, mandat « tu fais tout en total
> autonomie »). À relire/ajuster au réveil. Tout est additif et réversible.

## Objectif
Pousser les animations cyberpunk « partout, au max » sur VOX, en comblant les
zones plates identifiées par la cartographie, SANS casser l'existant.

## Constat (cartographie)
Base cyber déjà riche et réutilisable : palette CYBERCORE (cyan #00F0FF / magenta
#FF2E92 / violet), `design_tokens` (spacing/radius/durations/curves dont 2 springs,
typo 4 fonts, elevation glow), primitives `cyber_widgets`/`cyber_fx` (CyberGlass,
CyberPrimaryButton sweep, CyberBackdrop mesh, CyberGlitchText, CyberNeonFrame,
`cyberRoute()` warp NON branché), effets plein écran, jumbomoji, stagger
`_StaggeredFadeIn`. Packages dispo mais sous-exploités : `animations` (SharedAxis/
FadeThrough, 0 import), `flutter_animate` (1 usage). Gold standard = chat Matrix/SMS.

Zones PLATES (gains max) : transitions de page (MaterialPage par défaut), aucun
skeleton (52 spinners bruts), dialogs/bottom sheets vanilla, écrans settings/
chat_search/chat_members/key_verification/dialer-in-call/bootstrap statiques,
pas de pull-to-refresh, pas de pressed-scale générique.

## Périmètre (lots, additifs, gated analyze, 1 commit/lot)
1. **Transitions de page** — brancher une transition douce (FadeThrough/SharedAxis
   via `animations`) sur GoRouter `routes.dart` (mobile ; garder NoTransition desktop).
   Conservateur (pas de warp désorientant). Reduce-motion safe.
2. **Skeletons/shimmer** — widget réutilisable `cyber_skeleton.dart` + appliqué aux
   chargements initiaux de liste évidents (chat list, archive).
3. **Dialogs glass** — transition d'ouverture (scale+fade spring) + fond CyberGlass
   sur les dialogs custom `adaptive_dialogs/`.
4. **Pressable générique** — `cyber_pressable.dart` (scale-down + haptic) sur
   CyberSettingsTile + FAB.
5. **Stagger écrans plats** — entrée en cascade sur settings/chat_search/chat_members.
6. **Pull-to-refresh néon** — RefreshIndicator cyber sur la liste (si trivial).
7. **Build + install** — `flutter build apk --release` + install Pixel + rapport.

## Hors périmètre (NE PAS faire sans Bastien)
Changer la palette, réécrire la navigation, refactor non lié, supprimer/altérer une
feature, transitions agressives type warp plein écran. Mieux vaut SKIP un lot que
casser le build.

## Vérification
Chaque lot : `flutter analyze` sur ses fichiers → commit si vert, sinon revert +
SKIP. Final : build release complet (échec build → report honnête, pas d'install).

## Exécution
Workflow séquentiel (anti-conflit git), sous-agents **Fable 5**, commits incrémentaux.
Rapport done/skipped/build au réveil. Préférence enregistrée : Fable 5 = défaut
sous-agents pour VOX.
