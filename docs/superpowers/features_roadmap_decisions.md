# Décisions / bloqueurs — features demandées 2026-05-30

## ✅ LIVRÉ : 5 thèmes premium + sélecteur
CyberThemes (CYBERCORE, NEXUS, AURORA, EMBER, MONOCHROME). Sélecteur in-app dans
Settings > Apparence, re-skin instantané. Dans l'APK livré.

## ✅ FAISABLE (à faire) : Rich notifications
Notifs style messagerie (MessagingStyle Android : avatar, fil, actions
reply/mark-read inline, image). FluffyChat utilise flutter_local_notifications
(déjà en dep) + le push_helper du fork. Réalisable proprement. Effort moyen.

## ✅ FAISABLE (à cadrer) : Reply vocal depuis notif Wear (Matrix)
Dépend du bridge Wear existant (hermes-wear / WearBridge déjà dans android/wear)
+ STT (Whisper TrueNAS :8300, déjà en prod). Chemin : RemoteInput vocal sur la
notif Wear → enregistrement → upload via le canal voice DataLayer déjà en place
→ Matrix sendFileEvent. La brique voice watch→phone existe DÉJÀ (VoiceUploader).
Reste : brancher le RemoteInput de notif + STT optionnel. Effort moyen.

## ⚠️ BLOQUÉ / DÉCONSEILLÉ : SMS/MMS « app par défaut »
Devenir l'app SMS par défaut Android exige : permissions RECEIVE_SMS/RECEIVE_MMS
/SEND_SMS/READ_SMS, un BroadcastReceiver SMS_DELIVER, le rôle système ROLE_SMS,
une Activity HEADLESS_SMS_SEND, et toute une UI de gestion SMS native. C'est un
client SMS complet.
**MAIS Bastien a DÉJÀ ça** : projet `mautrix-android-sms` (SMS Bridge V3.1,
shipped 2026-05-16) — app SMS native dédiée avec MMS, multi-room Matrix,
BeeperPalette, media viewers. Réimplémenter un client SMS DANS FluffyChat
doublonnerait entièrement cette app pour ~plusieurs jours de travail.
→ RECO : NE PAS faire. Garder la séparation (FluffyChat = Matrix, SMS Bridge =
SMS). Si intégration voulue, passer par le bridge Matrix existant, pas par un
2e client SMS natif. Décision à Bastien.

## ⚠️ BLOQUÉ techniquement : auto-update app Wear via l'app phone
Installer/mettre à jour un APK Wear OS depuis le téléphone programmatiquement
nécessite soit le Play Store (RemoteInstall / node API du Play Store), soit des
permissions système (INSTALL_PACKAGES) qu'une app SIDELOADÉE ne possède pas.
En sideload pur (cas du fork), Android ne laisse PAS une app en installer une
autre sans l'UI système d'installation + confirmation utilisateur sur la montre.
→ POSSIBLE en pratique : pousser l'APK Wear via DataLayer du phone vers la
montre + déclencher l'INTENT d'install système (PackageInstaller session), qui
montre quand même un prompt de confirmation sur la montre. « Auto » silencieux =
non sans root/owner. À confirmer avec Bastien : prompt acceptable ou pas ?
