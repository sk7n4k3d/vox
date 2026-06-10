import 'package:fluffychat/config/design_tokens.dart';
import 'package:fluffychat/widgets/cyber/cyber_widgets.dart';
import 'package:flutter/material.dart';

/// CYBERCORE loading skeleton — a rounded glass box swept by a translucent
/// cyan→magenta shimmer. Replaces spinners for *initial list loading* states
/// (chat list, archive) so the page keeps its layout silhouette while data
/// streams in.
///
/// Reduce-motion aware: when [MediaQueryData.disableAnimations] is true (or
/// [animate] is false) the sweep is frozen and a faint static cyan→magenta
/// gradient is shown instead — same look, zero motion.
///
/// All visual constants come from [CyberColors] / [FluffyRadius]; the sweep is
/// a cheap CPU gradient (same technique as CyberPrimaryButton's light sweep),
/// no GPU fragment shader.
class CyberSkeleton extends StatefulWidget {
  /// Fixed width, or null to fill the parent (e.g. inside an [Expanded]).
  final double? width;
  final double height;
  final BorderRadius borderRadius;

  /// Set to false for purely decorative placeholders (e.g. the empty-state
  /// backdrop) that should never shimmer.
  final bool animate;

  const CyberSkeleton({
    this.width,
    this.height = 14,
    this.borderRadius = FluffyRadius.brSm,
    this.animate = true,
    super.key,
  });

  @override
  State<CyberSkeleton> createState() => _CyberSkeletonState();
}

class _CyberSkeletonState extends State<CyberSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool get _shouldRun {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return widget.animate && !reduce;
  }

  void _syncAnimation() {
    if (_shouldRun && !_shimmer.isAnimating) {
      _shimmer.repeat();
    } else if (!_shouldRun && _shimmer.isAnimating) {
      _shimmer.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant CyberSkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CyberColors.of(context);
    final running = _shouldRun;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Base glass fill + hairline border.
            DecoratedBox(
              decoration: BoxDecoration(
                color: cyber.glassFillLight,
                borderRadius: widget.borderRadius,
                border: Border.all(color: cyber.glassBorder, width: 1),
              ),
            ),
            if (running)
              AnimatedBuilder(
                animation: _shimmer,
                builder: (context, _) {
                  // Sweep a soft cyan→magenta band from left to right.
                  final x = -1.5 + _shimmer.value * 3.0;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(x - 0.6, 0),
                        end: Alignment(x + 0.6, 0),
                        colors: [
                          cyber.cyan.withValues(alpha: 0.0),
                          cyber.cyan.withValues(alpha: 0.22),
                          cyber.magenta.withValues(alpha: 0.16),
                          cyber.magenta.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.4, 0.6, 1.0],
                      ),
                    ),
                  );
                },
              )
            else
              // Static fallback (reduce-motion / animate:false): frozen faint
              // cyan→magenta tint, no movement.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      cyber.cyan.withValues(alpha: 0.08),
                      cyber.magenta.withValues(alpha: 0.06),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
