# VOX

### Ta messagerie, ton réseau.

> Fork de [FluffyChat](https://github.com/krille-chan/fluffychat) — client Matrix natif Android, augmenté d'une couche SMS/MMS, d'un thème cyberpunk et d'une assistance IA configurable.

![Matrix](https://img.shields.io/badge/Matrix-décentralisé-black?logo=matrix)
![Android](https://img.shields.io/badge/Android-API%2021%2B-3DDC84?logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)
![Licence](https://img.shields.io/badge/Licence-AGPL--3.0-blue)
![Statut](https://img.shields.io/badge/statut-projet%20perso-orange)

---

## Présentation

VOX est un client de messagerie **Matrix** décentralisé, bâti sur le travail de FluffyChat, auquel il ajoute une couche Android native et une identité visuelle propre.

Ce qu'il apporte par rapport à l'amont :

- **SMS / MMS natifs** — l'app peut devenir ton application SMS par défaut. Les MMS sont durcis, avec gestion des OTP et identification de l'appelant (caller-ID). Ajouts récents : blocage de numéros (blacklist système), export des conversations, messages programmés, filtre anti-spam local et aperçus enrichis de liens (lecteurs vidéo intégrés).
- **Thème cyberpunk `CYBERCORE`** — 6 presets, dont `STARLINK` avec un fond en particules animées.
- **Assistance IA** — un backend compatible OpenAI configurable : résumés de conversations, suggestions de réponses dans les notifications.
- **Réponses rapides Wear OS** — répondre depuis la montre.
- **Effets plein écran** — animations d'envoi et de réaction.

Le reste (chiffrement de bout en bout, espaces, appels, sauvegarde chiffrée, stickers…) vient directement de Matrix et de FluffyChat.

## Captures d'écran

| ![Liste des conversations](docs/screenshots/01-chat-list.png) | ![Conversation](docs/screenshots/02-conversation.png) |
|---|---|
| Liste des discussions | Fil de conversation |

*Textes des conversations floutés par respect de la vie privée.*


## Fonctionnalités phares

- 💬 **Matrix décentralisé** — compte sur n'importe quel homeserver compatible.
- 📲 **App SMS/MMS par défaut** — un seul fil pour Matrix et les SMS.
- 🚫 **Blocage de numéros** — blacklist système Android : SMS, MMS et appels rejetés d'un seul geste.
- 💾 **Export des conversations** — sauvegarde JSON d'un fil complet pour changer de téléphone sans rien perdre.
- ⏰ **Messages programmés** — écrits maintenant, envoyés à l'heure que tu choisis.
- 🛡️ **Filtre anti-spam local** — les pubs des numéros inconnus partent dans un dossier Spam, sans notification. 100 % sur l'appareil.
- 🔗 **Aperçus enrichis de liens** — carte avec vignette pour chaque lien partagé ; les vidéos YouTube se jouent dans la conversation, TikTok et Instagram dans leur lecteur officiel intégré.
- 🔐 **Chiffrement de bout en bout** — via la pile Matrix (vodozemac / Olm-Megolm).
- 🤖 **Assistance IA** — résumés, suggestions de réponses, backend configurable.
- 🎨 **Thème cyberpunk CYBERCORE** — 6 presets, mode sombre, Material You.
- ⌚ **Réponses rapides Wear OS**.
- 📎 **Tout type de contenu** — images, fichiers, messages vocaux, localisation.
- 🔔 **Notifications enrichies**, y compris suggestions de réponse.
- 🌌 **Espaces, salons publics, modération de groupe**.
- ✅ **Compatible Element, Nheko, NeoChat** et tout client Matrix.

… et bien plus.

## Build depuis les sources

Prérequis :

- [Flutter](https://flutter.dev) (géré via [fvm](https://fvm.app) de préférence)
- [Rust](https://www.rust-lang.org/tools/install) (pour la crypto Matrix)
- Android SDK / NDK pour cibler Android

```bash
# Récupérer le code
git clone https://github.com/sk7n4k3d/vox.git
cd vox

# Flutter
export PATH="$HOME/fvm/versions/stable/bin:$PATH"
fvm flutter pub get

# Build Android release
fvm flutter build apk --release
```

Le binaire est généré dans `build/app/outputs/flutter-apk/app-release.apk`.

## Statut

Projet **personnel**, non publié sur les stores. Sauvegarde sur un Gitea privé, avec un miroir GitHub public :

- Miroir : https://github.com/sk7n4k3d/vox
- Dépôt amont : https://github.com/krille-chan/fluffychat

Aucun support commercial, aucune garantie.

## Crédits

VOX n'existerait pas sans **FluffyChat**, créé et maintenu par [krille-chan](https://github.com/krille-chan) et une large communauté de contributeurs, traducteurs et testeurs. Le logo, le design, la structure du projet et la quasi-totalité du code Matrix viennent de là. Merci.

- 🧩 **FluffyChat** — https://github.com/krille-chan/fluffychat (AGPL-3.0)
- 🎨 **Design / logo FluffyChat** — [Fabiyamada](https://github.com/fabiyamada)
- 🌍 **Traductions** — toutes les personnes ayant contribué via Weblate
- 📣 **Emoji de vérification** — [Matrix Foundation](https://github.com/matrix-org/matrix-spec) (Apache 2.0)

Le thème cyberpunk, la couche SMS/MMS, l'assistance IA et les réponses Wear OS sont des ajouts propres à ce fork.

## Licence

**AGPL-3.0** — héritée de FluffyChat. Obligatoire pour tout fork distribué ou exposé en réseau : le code source complet reste disponible.

Voir le fichier [LICENSE](LICENSE).
