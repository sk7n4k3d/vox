import 'dart:ui';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
                    child: _GlassActionButton(
                      icon: Icons.edit_outlined,
                      label: l10n.editDisplayname,
                      accent: theme.extension<CyberpunkTheme>()?.cyan ??
                          theme.colorScheme.primary,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        controller.setDisplaynameAction();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GlassActionButton(
                      icon: Icons.qr_code_outlined,
                      label: l10n.share,
                      accent: theme.extension<CyberpunkTheme>()?.magenta ??
                          theme.colorScheme.secondary,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        FluffyShare.share(mxid, context);
                      },
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

/// Glass pill button matching the cyberpunk + Liquid Glass aesthetic of the
/// rest of the settings screen. Accent-colored icon + label on a frosted
/// surface, with a thin border tinted by the accent so the action reads as
/// a primary call-to-action without the heavy tonal fill of FilledButton.
class _GlassActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const _GlassActionButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<_GlassActionButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: widget.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.accent.withValues(alpha: 0.45),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accent.withValues(alpha: 0.22),
                    blurRadius: 14,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, size: 18, color: widget.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
