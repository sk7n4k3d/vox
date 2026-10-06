import 'package:fluffychat/utils/media/media_backfill.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Settings entry point for the media backfill: walks every Matrix room and
/// every SMS/MMS thread and mirrors the media into the Android gallery.
class MediaBackfillTile extends StatelessWidget {
  const MediaBackfillTile({super.key});

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    return ValueListenableBuilder<MediaBackfillProgress>(
      valueListenable: MediaBackfill.instance.progress,
      builder: (context, progress, _) => CyberSettingsTile(
        icon: Icons.download_for_offline_outlined,
        accent: cyber.cyan,
        title: 'Récupérer tous les médias',
        subtitle: _subtitle(progress),
        onTap: () => _openSheet(context),
      ),
    );
  }

  String _subtitle(MediaBackfillProgress progress) {
    if (progress.running) {
      final rooms = progress.roomsTotal > 0
          ? '${progress.roomsDone}/${progress.roomsTotal} conversations'
          : 'recherche en cours';
      return 'En cours — $rooms, ${progress.exported} médias exportés';
    }
    if (progress.error != null) return 'Échec : ${progress.error}';
    if (progress.cancelled) {
      return 'Interrompu — ${progress.exported} médias exportés';
    }
    if (progress.finished) {
      return 'Terminé — ${progress.exported} Matrix + '
          '${progress.mmsExported} MMS exportés';
    }
    return "Parcourt tout l'historique Matrix et SMS/MMS pour les copier "
        'dans la galerie';
  }

  void _openSheet(BuildContext context) {
    final client = Matrix.of(context).client;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _BackfillSheet(client: client),
    );
  }
}

class _BackfillSheet extends StatelessWidget {
  const _BackfillSheet({required this.client});

  final Client client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<MediaBackfillProgress>(
      valueListenable: MediaBackfill.instance.progress,
      builder: (context, progress, _) {
        final running = progress.running;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Récupérer tous les médias',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  "VOX parcourt l'historique de chaque conversation Matrix et "
                  'chaque fil SMS/MMS, télécharge les images et vidéos reçues, '
                  'puis les copie dans la galerie Android (Pictures/VOX, '
                  'Movies/VOX). Immich les récupère ensuite. Garde VOX au '
                  'premier plan le temps du premier passage.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                if (progress.roomsTotal > 0)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: progress.roomsDone / progress.roomsTotal,
                    ),
                  ),
                const SizedBox(height: 10),
                Text(_status(progress), style: theme.textTheme.bodySmall),
                if (progress.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    progress.error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (running)
                      OutlinedButton.icon(
                        onPressed: MediaBackfill.instance.cancel,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Annuler'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => MediaBackfill.instance.start(client),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Démarrer'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Fermer'),
                    ),
                  ],
                ),
                if (!running)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: MediaBackfill.instance.reset,
                      child: const Text('Réinitialiser le scan complet'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _status(MediaBackfillProgress progress) {
    if (progress.running) {
      final room = progress.currentRoom.isEmpty
          ? ''
          : ' dans ${progress.currentRoom}';
      return '${progress.roomsDone}/${progress.roomsTotal} conversations'
          '$room — ${progress.exported} médias exportés';
    }
    if (progress.error != null) return 'Arrêté sur une erreur.';
    if (progress.cancelled) {
      return 'Interrompu — ${progress.exported} médias exportés.';
    }
    if (progress.finished) {
      return 'Terminé — ${progress.exported} médias Matrix et '
          '${progress.mmsExported} MMS exportés vers la galerie.';
    }
    return 'Prêt à démarrer.';
  }
}
