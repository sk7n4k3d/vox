import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:flutter/material.dart';

class _AttachItem {
  final AddPopupMenuActions action;
  final IconData icon;
  final String label;
  final Color tint;
  final bool mobileOnly;
  const _AttachItem(this.action, this.icon, this.label, this.tint,
      {this.mobileOnly = false});
}

/// Ouvre le panneau frosted glass d'attach (grille 3 colonnes). Renvoie l'action
/// choisie ou null si fermé. [isMobile] masque les items mobile-only (caméra,
/// localisation) sur desktop/web.
Future<AddPopupMenuActions?> showAttachMenu(
  BuildContext context, {
  required bool isMobile,
}) {
  return showModalBottomSheet<AddPopupMenuActions>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) => _AttachMenuSheet(isMobile: isMobile),
  );
}

class _AttachMenuSheet extends StatelessWidget {
  final bool isMobile;
  const _AttachMenuSheet({required this.isMobile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cyber =
        theme.extension<CyberpunkTheme>() ?? CyberpunkTheme.dark();
    final l10n = L10n.of(context);
    final items = <_AttachItem>[
      _AttachItem(AddPopupMenuActions.image, Icons.photo_outlined,
          l10n.sendImage, cyber.cyan),
      _AttachItem(AddPopupMenuActions.photoCamera, Icons.camera_alt_outlined,
          l10n.takeAPhoto, cyber.violet,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.video,
          Icons.video_camera_back_outlined, l10n.sendVideo, cyber.cyan),
      _AttachItem(AddPopupMenuActions.videoCamera, Icons.videocam_outlined,
          l10n.recordAVideo, cyber.violet,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.file, Icons.attachment_outlined,
          l10n.sendFile, cyber.magenta),
      _AttachItem(AddPopupMenuActions.poll, Icons.poll_outlined,
          l10n.startPoll, cyber.magenta),
      _AttachItem(AddPopupMenuActions.location, Icons.gps_fixed_outlined,
          l10n.shareLocation, cyber.cyan,
          mobileOnly: true),
      _AttachItem(AddPopupMenuActions.ephemeral, Icons.timer_outlined,
          l10n.ephemeralMessages, cyber.violet),
    ];
    final visible =
        items.where((i) => !i.mobileOnly || isMobile).toList();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.82),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(color: cyber.violet.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.92,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < visible.length; i++)
                _AttachTile(
                  item: visible[i],
                  index: i,
                  onTap: () => Navigator.of(context).pop(visible[i].action),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  final _AttachItem item;
  final int index;
  final VoidCallback onTap;
  const _AttachTile({
    required this.item,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('attach_${item.action.name}'),
      borderRadius: FluffyRadius.brLg,
      onTap: onTap,
      // La zone cliquable couvre toute la cellule de la grille (pas seulement le
      // disque), pour un tap fiable et plus ergonomique.
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: item.tint.withValues(alpha: 0.13),
                borderRadius: FluffyRadius.brLg,
                border: Border.all(color: item.tint.withValues(alpha: 0.32)),
              ),
              child: Icon(item.icon, color: item.tint),
            ),
            const SizedBox(height: 6),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
