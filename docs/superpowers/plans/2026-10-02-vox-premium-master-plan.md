# VOX Premium — plan de bataille (2026-10-02)

Objectif : bug-hunt exhaustive + optimisations (même les petites) + refonte INTÉGRALE
de chaque écran. Thème de référence utilisateur : STARLINK (bleu électrique,
particules mouvantes) — livré en 8df174d1.

## Phase 1 — Fixes natifs Kotlin (audit docs/superpowers/audit/audit_bugs_kotlin_2026-10-02.md)
Par gravité :
1. SmsDeliverReceiver : goAsync() + travail hors main thread (ANR) 💥
2. HeadlessSmsSendService : stopSelf() prématuré → réponses rapides perdues 🗑️
3. SmsBridge : OUTBOX → FAILED sur échec d'envoi (jamais fait) 🗑️
4. Pagination date < beforeMs : messages perdus au même timestamp
5. Date PDU MMS jetée → fil/date faux
6. MmsHttpClient.isAccepted() : faux négatifs
7. SmsNotifier.history : accès concurrent non synchronisé 💥
8. onDone() appelé 2× sur chemins d'erreur
9. MmsNetworkManager lock.wait() → callback écrasé
10. WearBridge uuid non validé → path traversal 🔒
+ secondaires (manifest, MmsPduProvider exporté, runCatching muets, bi-SIM).

## Phase 2 — Fixes Dart/upstream (rapport vox_bugs_known_research.md)
- ✅ Fait : leak #3132 matrix.dart dispose (commit 8df174d1)
- Freeze post-sync 0,7 s (#2259) → vérifier version matrix-dart-sdk fork
- Scroll saccadé (#293) + rebuild liste à chaque frappe → isoler composer/liste
- BackdropFilter app bar blur 20 re-floutage par frame → snapshot/cacher
- Blur 8 par pastille de réaction → remplacer par fill translucide
- Multi-comptes notifications (#544) ; startup ANR (#2912) ; read markers (#3425)
(voir docs/superpowers/audit/audit_bugs_dart_2026-10-02.md à paraître)

## Phase 3 — Features premium quick wins (rapport vox_features_premium_research.md)
1. GIF Tenor + stickers/emojis custom dans le picker (#808)
2. Coller/envoyer image sur Android (#2492)
3. Thème OLED pure-black « VOID » (#867) — naturel pour l'identité cyber
4. Transcription vocale on-device
5. Recherche globale + in-room
6. Aperçus de liens fiables (#3075)
7. Threads (#497) ; organisation salons (dossiers/pins)
8. Notifications : contenu/actions multi-comptes fiables
Non-reproposer (existant) : MatrixRTC MVP, polls, réactions, stickers Lottie, OIDC.

## Phase 4 — Refonte INTÉGRALE des écrans (~30, un par un)
Système : tokens CyberThemes (6 presets), cyber_widgets, cyber_fx, contrat
docs/superpowers/cyber_anim_contract.md. Fond = CyberScreenBackdrop (STARLINK →
particules, autres → Aurora). Chaque écran passe par : app bar glass + glitch
titre, entrées staggered one-shot, skeletons au chargement, dialogs glass,
press-scale haptic, vide-états illustrés néon, transitions FadeThrough.
Liste : chat_list (+header/filters/fab) · chat (+app bar/composer/events) ·
sms_chat + new_sms · settings (+8 sous-pages) · chat_details (+6) · login ×3 ·
intro · image_viewer · archive · chat_search · key_verification · new_group ·
new_private_chat · invitation_selection · app_lock · dialer · device_settings ·
settings_3pid/emotes/homeserver/ignore_list/password/security/style/notifications.

## État
- [x] Thème STARLINK + fond particules (8df174d1) — installé sur Pixel pour test
- [x] Fix leak #3132
- [ ] Audit Dart (en cours) · audit Kotlin complément wear/plugin (en cours)
- [ ] Phase 1 → 4
