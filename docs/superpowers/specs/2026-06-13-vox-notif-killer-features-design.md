# Killer features notifications VOX — run autonome (2026-06-13)

> Décisions prises EN AUTONOMIE (mandat « fait tout, ne me dérange qu'à l'install »).
> Basé sur le rapport de recherche notif du même jour. Additif, compile-gated.

## Garde-fous (les notifs ont déjà cassé 2× aujourd'hui)
- ADDITIF uniquement. NE PAS toucher au drawable `notifications_icon` (logo VOX
  fraîchement réparé) ni au format des notifs existantes.
- Chaque lot : `compileReleaseKotlin` + `flutter analyze` → commit si vert, sinon
  revert + SKIP. Jamais de commit cassé.
- Ne JAMAIS dégrader le chemin actuel (MessagingStyle + reply inline + mark-read
  + aperçu MMS + logo) qui marche.
- Build APK final ; si build rouge → revert le lot fautif.
- Sous-agents Fable 5 (préférence VOX), workflow séquentiel (anti-conflit git).

## Périmètre RETENU (fort impact × faible risque, faisable sans supervision)
1. **Conversations API — SMS** (`SmsNotifier`) : sharing shortcut long-lived par
   thread (`ShortcutInfoCompat.setLongLived(true)` + Person + `pushDynamicShortcut`)
   + `notif.setShortcutId(...)` + `setLocusId`. VOX a déjà MessagingStyle+Person →
   delta minimal. Gain : conversations système (section dédiée, priorité, prérequis
   bulles). Pur AOSP.
2. **Conversations API — Matrix** : vérifier si FluffyChat publie déjà les shortcuts
   (push_helper.dart / le SDK). Si oui : RAS. Si non et trivial : aligner. Sinon SKIP.
3. **Wear — réponses rapides prédéfinies** (`SmsNotifier` reply action) :
   `RemoteInput.setChoices([...])` (ex : 👍 / OK / J'arrive / Je rappelle) → tap
   direct depuis la Galaxy Watch (et le téléphone). Minuscule, sûr.
4. **Smart Reply on-device** (plus risqué, lot ISOLÉ en dernier) : dépendance
   **`com.google.mlkit:smart-reply` BUNDLED** (PAS la variante play-services →
   GMS interdit sur GrapheneOS) + génération de 3 suggestions à partir de
   l'historique du thread, injectées en `setChoices`/`setAllowGeneratedReplies`.
   Risque : build (dépendance), modèle EN (FR faible). Si build casse → revert.
5. **UnifiedPush — audit** : vérifier l'état (pubspec, code, distributeur ntfy
   configuré ?) et documenter. PAS de code risqué (config infra = supervisé).

## Hors périmètre (reporté en travail SUPERVISÉ — trop gros/risqué en autonomie)
- **Bubbles** : nécessite une activity bubble Flutter dédiée (effort + risque UI).
- **UI réglages push rules Matrix** (mentions/keywords/mute par room) : gros morceau Flutter.
- **Suppression de notif lue ailleurs** (cross-device read receipts → cancel) :
  touche le pipeline push Matrix, à faire supervisé.
Ces 3 sont documentés mais NON implémentés cette nuit (je préfère ne pas risquer
le pipeline notif sans validation E2E possible).

## Vérification & livraison
Workflow séquentiel, compile+analyze par lot. Build APK final. Puis TENTATIVE
d'install sur le Pixel (port ADB rotatif → si décroché, je préviens Bastien pour
le port). Bastien n'est dérangé QU'à ce moment (install). Rapport lot par lot fourni.
</content>
