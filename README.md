![VOX — messagerie Matrix et SMS chiffrées sur Android](docs/images/banner.png)

# VoxOne

### Ta messagerie, ton réseau — Matrix et SMS dans la même application.

> Fork de [FluffyChat](https://github.com/krille-chan/fluffychat) : client Matrix natif Android, augmenté d'une couche SMS/MMS, d'un thème cyberpunk et d'une assistance IA configurable.

*VoxOne est le nom d'affichage du projet ; le dépôt reste `vox` et l'identifiant d'application `eu.devlabz.vox`.*

![Matrix](https://img.shields.io/badge/Matrix-décentralisé-black?logo=matrix)
![Android](https://img.shields.io/badge/Android-API%2021%2B-3DDC84?logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)
![Licence](https://img.shields.io/badge/Licence-AGPL--3.0-blue)
![Statut](https://img.shields.io/badge/statut-projet%20perso-orange)

---

## Présentation

VoxOne est un client de messagerie **Matrix** décentralisé, bâti sur le travail de FluffyChat, auquel il ajoute une couche Android native et une identité visuelle propre. Son pari : **une seule application pour les discussions chiffrées décentralisées et les SMS/MMS du quotidien**, réunis dans la même liste de conversations.

Ce qu'il apporte par rapport à l'amont :

- **App SMS / MMS par défaut** — l'app peut détenir le rôle SMS d'Android. Les MMS sont durcis (plafonds anti-OOM, validation des en-têtes PDU), avec gestion des codes OTP et identification de l'appelant (caller-ID).
- **Mode SMS/MMS sans compte Matrix** — VoxOne se lance et s'utilise comme messagerie SMS pure, sans jamais créer de compte ; un compte Matrix peut être ajouté plus tard sans rien perdre.
- **Fonctions d'appelant SMS** — blocage de numéros (blacklist système), export de conversation, messages programmés, filtre anti-spam 100 % local et aperçus enrichis de liens (lecteurs vidéo intégrés YouTube / TikTok / Instagram).
- **Appels Matrix 1:1** — audio et vidéo, deux protocoles pris en charge (signaling `m.call.*` historique et MatrixRTC/LiveKit), avec pont Wear OS.
- **Thème cyberpunk `CYBERCORE`** — 6 presets, dont `STARLINK` avec fond en particules animées, effets plein écran à l'envoi et jumbomoji.
- **Assistance IA** — un backend compatible OpenAI configurable : résumés de conversations, suggestions de réponses dans les notifications.
- **Webhook sortant optionnel** — chaque message peut être copié, signé en HMAC, vers une URL que tu contrôles (désactivé par défaut, contenu optionnellement masqué).

Le reste (chiffrement de bout en bout, espaces, sauvegarde chiffrée, stickers…) vient directement de Matrix et de FluffyChat.

## Confidentialité

- Le filtre anti-spam et la détection des codes OTP tournent **sur l'appareil**, sans aucun service Google.
- Le webhook est **désactivé par défaut**, et peut n'envoyer que les métadonnées.
- L'assistance IA est **facultative** : son backend est une URL que tu configure (ou aucune).
- Pas de Firebase ni GMS : le push Matrix passe par [UnifiedPush](https://unifiedpush.org/).

## Captures d'écran

| ![Liste des conversations](docs/screenshots/01-chat-list.png) | ![Conversation](docs/screenshots/02-conversation.png) |
|---|---|
| Liste des discussions | Fil de conversation |

*Textes des conversations floutés par respect de la vie privée.*

## Fonctionnalités phares

- 💬 **Matrix décentralisé** — compte sur n'importe quel homeserver compatible.
- 📲 **Un seul fil pour Matrix et les SMS** — l'app assume le rôle d'app SMS par défaut.
- 🚫 **Blocage de numéros** — blacklist système Android : SMS, MMS et appels rejetés d'un seul geste.
- 💾 **Export des conversations** — sauvegarde JSON d'un fil complet pour changer de téléphone sans rien perdre.
- ⏰ **Messages programmés** — écrits maintenant, envoyés à l'heure que tu choisis.
- 🛡️ **Filtre anti-spam local** — les pubs des numéros inconnus partent dans un dossier Spam, sans notification.
- 🔗 **Aperçus enrichis de liens** — carte avec vignette pour chaque lien partagé ; les vidéos se jouent dans la conversation.
- 🔐 **Chiffrement de bout en bout** — via la pile Matrix (vodozemac / Olm-Megolm).
- 📞 **Appels 1:1 audio et vidéo** — legacy `m.call.*` et MatrixRTC (le nouveau protocole des appels Element).
- 🤖 **Assistance IA** — résumés, suggestions de réponses, backend configurable.
- 🎨 **Thème cyberpunk CYBERCORE** — 6 presets, mode sombre, Material You.
- ⌚ **Wear OS** — réponses rapides et écoute des vocaux depuis la montre.
- 📎 **Tout type de contenu** — images, fichiers, messages vocaux, localisation.
- 🌌 **Espaces, salons publics, modération de groupe**.
- ✅ **Compatible Element, Nheko, NeoChat** et tout client Matrix.

… et bien plus.

## Build depuis les sources

Prérequis :

- **Flutter 3.47.5 stable** (Dart 3.13.4) — [flutter.dev](https://flutter.dev)
- **Rust** (pour la crypto Matrix) — [rust-lang.org](https://www.rust-lang.org/tools/install)
- Android SDK / NDK

⚠️ Le fork utilise un **SDK Matrix patché** déclaré dans `pubspec.yaml`
(`dependency_overrides: matrix: path: ../matrix-dart-sdk-patched`, branche
`bastien-patch-sqflite-recovery`, dépôt non public). Sans ce dépôt **jumeau** à
côté du clone, `flutter pub get` échoue : soit tu fournis ce dépôt (les patches
sont défensifs et ne changent pas l'API), soit tu retires l'override pour
repartir du paquet `matrix` publié — à tes risques.

```bash
git clone https://github.com/sk7n4k3d/vox.git
cd vox
flutter pub get
flutter test                 # suite Dart, hors appareil
flutter build apk --release  # APK signé si android/key.properties est présent
```

Le binaire est généré dans `build/app/outputs/flutter-apk/app-release.apk`.

## Statut

Projet **personnel**, non publié sur les stores. Sauvegarde sur un Gitea privé, avec un miroir GitHub public :

- Miroir : https://github.com/sk7n4k3d/vox
- Dépôt amont : https://github.com/krille-chan/fluffychat
- Historique complet du fork d'origine : [README.fluffychat.md](README.fluffychat.md)

Aucun support commercial, aucune garantie.

## Crédits

VoxOne n'existerait pas sans **FluffyChat**, créé et maintenu par [krille-chan](https://github.com/krille-chan) et une large communauté de contributeurs, traducteurs et testeurs. Le logo, le design, la structure du projet et la quasi-totalité du code Matrix viennent de là. Merci.

- 🧩 **FluffyChat** — https://github.com/krille-chan/fluffychat (AGPL-3.0)
- 🎨 **Design / logo FluffyChat** — [Fabiyamada](https://github.com/fabiyamada)
- 🌍 **Traductions** — toutes les personnes ayant contribué via Weblate
- 📣 **Emoji de vérification** — [Matrix Foundation](https://github.com/matrix-org/matrix-spec) (Apache 2.0)

Le thème cyberpunk, la couche SMS/MMS, les appels MatrixRTC, l'assistance IA, le webhook et les fonctions Wear OS sont des ajouts propres à ce fork.

## Licence

**AGPL-3.0** — héritée de FluffyChat. Obligatoire pour tout fork distribué ou exposé en réseau : le code source complet reste disponible.

Voir le fichier [LICENSE](LICENSE).
