import 'dart:math' as math;

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/config/design_tokens.dart';
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

  /// Sprint 2 V2 — when true, draws a subtle pulse animation in cyan to
  /// signal an unread room. Stacked on top of any existing ring color.
  final bool unread;

  /// Sprint 2 V2 — when true, draws a magenta highlight ring (mentions).
  final bool mentioned;

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
    this.unread = false,
    this.mentioned = false,
    this.shapeBorder,
    this.borderRadius,
    super.key,
  });

  Color _resolveRingColor(BuildContext context, bool? isOnline) {
    if (ringColor != null) return ringColor!;
    final theme = Theme.of(context);
    final cyber = theme.extension<CyberpunkTheme>();
    if (mentioned) {
      return cyber?.magenta ?? theme.colorScheme.error;
    }
    if (isSpace) {
      return cyber?.violet ?? theme.colorScheme.tertiary;
    }
    if (isOnline == true) {
      if (encrypted) {
        return cyber?.cyan ?? theme.colorScheme.primary;
      }
      return cyber?.success ?? Colors.green.shade400;
    }
    if (unread) {
      return (cyber?.cyan ?? theme.colorScheme.primary).withValues(alpha: 0.7);
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

    final avatar = Avatar(
      mxContent: mxContent,
      name: name,
      size: size,
      onTap: onTap,
      client: client,
      // Presence dot is already rendered upstream via the ring — avoid
      // double-signalling by NOT forwarding presenceUserId to the inner
      // Avatar.
      shapeBorder: shapeBorder,
      borderRadius: borderRadius,
    );

    // Sprint 2 V2 — unread/mentioned rooms get a soft cyan/magenta pulse.
    // Static avatars stay cheap: pulse only kicks in when [unread] is true,
    // wrapped in a RepaintBoundary so the chatlist viewport doesn't repaint
    // surrounding bubbles each frame.
    if (unread && !mentioned && hasRing) {
      return SizedBox(
        width: outerSize,
        height: outerSize,
        child: _PulseRing(
          color: color,
          ringWidth: _ringWidth,
          gap: _ringGap,
          child: avatar,
        ),
      );
    }

    return AnimatedContainer(
      duration: FluffyDurations.normal,
      curve: FluffyCurves.decelerated,
      width: outerSize,
      height: outerSize,
      padding: EdgeInsets.all(hasRing ? _ringGap : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: hasRing
            ? Border.all(color: color, width: _ringWidth)
            : null,
        boxShadow: (isOnline || mentioned) && hasRing
            ? [
                BoxShadow(
                  color: color.withValues(alpha: mentioned ? 0.55 : 0.4),
                  blurRadius: mentioned ? 12 : 8,
                ),
              ]
            : null,
      ),
      child: avatar,
    );
  }
}

/// Sprint 2 V2 — pulsing ring used to draw the eye toward unread rooms.
class _PulseRing extends StatefulWidget {
  const _PulseRing({
    required this.color,
    required this.ringWidth,
    required this.gap,
    required this.child,
  });

  final Color color;
  final double ringWidth;
  final double gap;
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  // Deux respirations à l'entrée, puis repos définitif. Un `repeat()` permanent
  // sur chaque conversation non lue saturait le thread raster : mesuré à
  // 117 fps et ~7,5 ms de raster par frame en continu, écran pourtant figé
  // (et 0 fps dès que les lignes sortaient du viewport). Le contrat CYBERCORE
  // interdit `.repeat()` en liste.
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _ctrl.stop();
      _ctrl.value = 1;
    } else if (!_ctrl.isAnimating && _ctrl.value == 0) {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          // 2 respirations réparties sur la durée, puis valeur figée à 1 : le
          // halo reste présent mais l'animation s'arrête (plus aucune frame).
          final breath =
              0.5 - 0.5 * math.cos(_ctrl.value * 2 * math.pi * 2);
          final alpha = 0.25 + 0.35 * breath;
          final blur = 6.0 + 8.0 * breath;
          return Container(
            padding: EdgeInsets.all(widget.gap),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color,
                width: widget.ringWidth,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: alpha),
                  blurRadius: blur,
                ),
              ],
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
