# Refonte PREMIUM du flux vocal — contrat

## Objectif
L'overlay d'enregistrement vocal (annuler / verrouiller / slide-to-cancel) ne
s'affiche plus de façon fiable ET son design est médiocre (bandeau plat de 72px
coincé dans la barre d'input). On le refond au niveau PREMIUM 2026 (réfs
WhatsApp/Telegram : waveform live, slide-to-cancel clair, lock qui monte) en
restant dans l'identité CYBERCORE du fork.

## État actuel (à remplacer / fiabiliser)
- lib/pages/chat/voice_recording_overlay.dart : overlay inline (_OverlayShell)
  bandeau 72px dans la barre, contraint, moche. → REFONTE visuelle.
- lib/pages/chat/recording_view_model.dart : logique d'enregistrement (record
  package). Bugs : double hasPermission() (l.79 + l.99), `isStarting` peut
  rester coincé si un await échoue, _subscribe() peut NPE sur _audioRecorder!.
- lib/pages/chat/voice_record_button.dart : bouton micro. Ne REBUILD PAS quand
  l'état d'enregistrement change (lit widget.recordingState sans écouter) →
  l'overlay/scale peuvent ne pas se rafraîchir. Future.delayed non annulé.
- lib/pages/chat/recording_input_row.dart : barre quand isLocked (waveform +
  pause/cancel/send). Waveform = barres plates basiques. → AMÉLIORER.
- lib/pages/chat/voice_record_gesture_state.dart : value class pure des gestes
  (lockProgress, cancelProgress, seuils). NE PAS casser sa logique.

## Design system CYBERCORE (imports)
import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
- cyber.cyan #00F0FF (rec actif, waveform), cyber.magenta #FF2E92 (cancel/danger),
  cyber.violet, cyber.success, neonGlow, glassFillStrong, glassBorder, blurSigma*.
- FluffySpacing / FluffyRadius / FluffyDurations / FluffyCurves / FluffyTypography.
- Timer en FluffyTypography.mono (JetBrainsMono, tabular).

## Cible visuelle premium (overlay enregistrement, NON verrouillé)
Un panneau flottant glass au-dessus de la barre d'input (pas un bandeau plat),
pleine largeur, ~96-110px, BackdropFilter blur, hairline, léger neon glow cyan :
- Point REC pulsant magenta/rouge + timer mono live à gauche.
- Waveform LIVE au centre : barres animées pilotées par state.amplitudeTimeline
  (réagit à la voix), couleur cyan, qui défilent. Pas des barres figées.
- "‹ Glisser pour annuler" animé, qui vire au magenta + se rapproche de la
  corbeille à mesure que cancelProgress monte (gestureState.cancelProgress).
- Badge LOCK à droite qui MONTE et s'illumine cyan quand lockProgress monte
  (gestureState.lockProgress), avec chevron vers le haut.
- Opacité/teinte vire au magenta quand isCancelling.

## Cible visuelle premium (barre VERROUILLÉE, isLocked)
- Corbeille magenta (cancel) | pause/reprise | timer mono | waveform live cyan |
  bouton envoi gradient cyan→magenta (réutiliser le style CyberPrimaryButton /
  glow). Glass cohérent.

## FIABILITÉ (obligatoire — c'est la régression principale)
1. Le bouton VoiceRecordButton DOIT se reconstruire quand l'état change :
   passer par un ListenableBuilder/AnimatedBuilder, ou un ValueNotifier exposé
   par le view model, OU s'assurer que le parent rebuild (RecordingViewModel
   builder rebuild déjà sur setState — vérifier que le bouton est SOUS ce
   builder et reçoit le state à jour). L'overlay doit apparaître dès isStarting.
2. recording_view_model : ne JAMAIS laisser isStarting=true si on return tôt
   (permission refusée l.79 → remettre isStarting=false). Supprimer le double
   hasPermission(). Garder _audioRecorder!.getAmplitude() à l'abri du null
   (capture locale).
3. Pas de Future.delayed non annulé dans voice_record_button (utiliser un Timer
   stocké + annulé, ou un flag isCancelling déjà posé).
4. Reduce-motion : pauser les pulses/anim si MediaQuery.disableAnimationsOf.

## Garde-fous
- NE PAS changer la signature de onVoiceMessageSend ni la logique d'envoi Matrix.
- NE PAS casser le mode accessibleNavigation (tap simple) du bouton.
- NE PAS casser voice_record_gesture_state (value class + computeGestureState).
- Préserver les Key(). flutter analyze : 0 warning. const où possible.
- NE PAS lancer analyze/build (fait globalement après).
