import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/presence_builder.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// A wrapper around [Avatar] that draws a 2px colored ring around the avatar
/// based on the user's online/encryption status.
///
/// Color rules:
///  - **Cyan** : online AND (room is E2EE encrypted)
///  - **Green** : online without E2EE
///  - **Violet** : the room is a Matrix Space (overrides presence)
///  - **Transparent** : offline / unknown
///
/// The ring keeps a 3px gap from the avatar so it never visually merges with
/// the picture. When online, a soft neon glow shadow is added.
///
/// The widget supports two modes:
///  1. Auto presence: pass [presenceUserId] (typically the DM partner mxid),
///     ring color reacts to the live `CachedPresence` stream.
///  2. Manual: pass [online] explicitly, skipping the [PresenceBuilder].
///
/// All overrides are honored: [ringColor] short-circuits the logic, [online]
/// + [encrypted] + [isSpace] override the heuristic when [presenceUserId] is
/// null.
class AvatarWithStatusRing extends StatelessWidget {
  final Uri? mxContent;
  final String? name;
  final double size;
  final VoidCallback? onTap;
  final Client? client;

  /// If non-null, presence is tracked live for that user id (DM partner mxid).
  final String? presenceUserId;

  /// Explicit override for [presenceUserId] resolution.
  final bool? online;

  /// Whether the room is encrypted (E2EE). Drives cyan vs green ring.
  final bool encrypted;

  /// Whether this avatar represents a Matrix Space.
  final bool isSpace;

  /// Hard override of the ring color. Bypasses presence/encryption logic.
  final Color? ringColor;

  /// Avatar shape override forwarded to the inner [Avatar].
  final ShapeBorder? shapeBorder;
  final BorderRadius? borderRadius;

  /// Padding between ring and avatar in logical pixels.
  static const double _ringGap = 3.0;

  /// Ring stroke width in logical pixels.
  static const double _ringWidth = 2.0;

  const AvatarWithStatusRing({
    this.mxContent,
    this.name,
    this.size = Avatar.defaultSize,
    this.onTap,
    this.client,
    this.presenceUserId,
    this.online,
    this.encrypted = false,
    this.isSpace = false,
    this.ringColor,
    this.shapeBorder,
    this.borderRadius,
    super.key,
  });

  Color _resolveRingColor(BuildContext context, bool? isOnline) {
    if (ringColor != null) return ringColor!;
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    if (isSpace) {
      return cyber?.violet ?? theme.colorScheme.tertiary;
    }
    if (isOnline == true) {
      if (encrypted) {
        return cyber?.cyan ?? theme.colorScheme.primary;
      }
      return Colors.green.shade400;
    }
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    // Total widget size = inner avatar + 2*(gap + stroke) on each side.
    final outerSize = size + 2 * (_ringGap + _ringWidth);

    if (presenceUserId != null && online == null && ringColor == null) {
      return RepaintBoundary(
        child: PresenceBuilder(
          client: client,
          userId: presenceUserId,
          builder: (context, presence) {
            final isOnline = presence?.presence.isOnline == true;
            return _buildRing(context, isOnline, outerSize);
          },
        ),
      );
    }

    return RepaintBoundary(
      child: _buildRing(context, online == true, outerSize),
    );
  }

  Widget _buildRing(BuildContext context, bool isOnline, double outerSize) {
    final color = _resolveRingColor(context, isOnline);
    final hasRing = color != Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: outerSize,
      height: outerSize,
      padding: EdgeInsets.all(hasRing ? _ringGap : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: hasRing
            ? Border.all(color: color, width: _ringWidth)
            : null,
        boxShadow: isOnline && hasRing
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
      child: Avatar(
        mxContent: mxContent,
        name: name,
        size: size,
        onTap: onTap,
        client: client,
        // Presence dot is already rendered upstream via the ring — avoid
        // double-signalling by NOT forwarding presenceUserId to the inner
        // Avatar. Consumers that want the legacy bottom-right dot can use
        // [Avatar] directly.
        shapeBorder: shapeBorder,
        borderRadius: borderRadius,
      ),
    );
  }
}
