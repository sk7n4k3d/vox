import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'settings.dart';

/// XL profile header for the Settings root screen.
///
/// 96dp avatar with subtle primary glow, display name (24sp w700),
/// handle (@user:server, 14sp 65% opacity), presence/status line,
/// and a 2-button row (Edit profile + QR code).
class SettingsProfileHeader extends StatelessWidget {
  final SettingsController controller;

  const SettingsProfileHeader({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final mxid = client.userID ?? l10n.user;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      child: FutureBuilder<Profile>(
        future: controller.profileFuture,
        builder: (context, snapshot) {
          final profile = snapshot.data;
          final avatar = profile?.avatarUrl;
          final displayname =
              profile?.displayName ?? mxid.localpart ?? mxid;

          return Column(
            children: [
              _AvatarBlock(
                avatar: avatar,
                displayname: displayname,
                onAvatarTap: avatar != null
                    ? () => showDialog(
                          context: context,
                          builder: (_) => MxcImageViewer(avatar),
                        )
                    : controller.setAvatarAction,
                onEditAvatar: controller.setAvatarAction,
                glowColor: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                displayname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                mxid,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF22C55E),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Available',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: controller.setDisplaynameAction,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(l10n.editDisplayname),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => FluffyShare.share(mxid, context),
                      icon: const Icon(Icons.qr_code_outlined, size: 18),
                      label: Text(l10n.share),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AvatarBlock extends StatelessWidget {
  final Uri? avatar;
  final String displayname;
  final VoidCallback onAvatarTap;
  final VoidCallback onEditAvatar;
  final Color glowColor;

  const _AvatarBlock({
    required this.avatar,
    required this.displayname,
    required this.onAvatarTap,
    required this.onEditAvatar,
    required this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.25),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          Avatar(
            mxContent: avatar,
            name: displayname,
            size: 96,
            onTap: onAvatarTap,
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Material(
              color: Theme.of(context).colorScheme.primary,
              shape: const CircleBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onEditAvatar,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.camera_alt_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
