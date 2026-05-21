import 'dart:ui';

import 'package:fluffychat/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

/// Refonte 2026 — incoming call screen :
///   - Background = avatar de l'appelant en blur + gradient primary→noir
///   - Halos concentriques animés autour de l'avatar (M3 Expressive)
///   - Chip "🔒 Matrix · E2EE"
///   - Status animé "ringing." → "ringing.." → "ringing..."
///   - Boutons FAB 84px avec spring elasticOut au tap
///   - Haptic feedback heavy à l'apparition, selection click sur tap
class IncomingCallView extends StatefulWidget {
  final Room room;
  final User caller;
  final bool encrypted;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  const IncomingCallView({
    required this.room,
    required this.caller,
    required this.encrypted,
    required this.onAnswer,
    required this.onDecline,
    super.key,
  });

  @override
  State<IncomingCallView> createState() => _IncomingCallViewState();
}

class _IncomingCallViewState extends State<IncomingCallView>
    with TickerProviderStateMixin {
  late final AnimationController _ripple;
  late final AnimationController _dots;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _dots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 60));
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void dispose() {
    _ripple.dispose();
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final displayName = widget.caller.calcDisplayname();
    final avatarUrl = widget.caller.avatarUrl;
    final roomName =
        widget.room.isDirectChat ? null : widget.room.getLocalizedDisplayname();

    return AnimatedScale(
      scale: _entered ? 1.0 : 0.92,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _entered ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 280),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _BlurredBackground(
              avatarUrl: avatarUrl,
              accent: scheme.primary,
            ),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _GlassChip(
                        icon: widget.encrypted ? Icons.lock : Icons.lock_open,
                        label: widget.encrypted
                            ? 'Matrix · E2EE'
                            : 'Matrix · clair',
                        scheme: scheme,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Center(
                    child: SizedBox(
                      width: 280,
                      height: 280,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _RippleHalo(
                            controller: _ripple,
                            offset: 0,
                            color: scheme.primary,
                          ),
                          _RippleHalo(
                            controller: _ripple,
                            offset: 0.33,
                            color: scheme.primary,
                          ),
                          _RippleHalo(
                            controller: _ripple,
                            offset: 0.66,
                            color: scheme.primary,
                          ),
                          Container(
                            width: 180,
                            height: 180,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withValues(alpha: 0.35),
                                  blurRadius: 32,
                                  spreadRadius: 4,
                                ),
                              ],
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                                width: 1.5,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Avatar(
                              mxContent: avatarUrl,
                              name: displayName,
                              size: 180,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    displayName,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (roomName != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      roomName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  AnimatedBuilder(
                    animation: _dots,
                    builder: (context, _) {
                      final n = (_dots.value * 3).floor() + 1;
                      return Text(
                        'Appel entrant${'.' * n}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      );
                    },
                  ),
                  const Spacer(flex: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallActionButton(
                        icon: Icons.call_end,
                        label: 'Décliner',
                        background: const Color(0xFFB3261E),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onDecline();
                        },
                      ),
                      _CallActionButton(
                        icon: Icons.call,
                        label: 'Décrocher',
                        background: const Color(0xFF34A853),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onAnswer();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlurredBackground extends StatelessWidget {
  final Uri? avatarUrl;
  final Color accent;

  const _BlurredBackground({required this.avatarUrl, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (avatarUrl != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: 0.4),
                BlendMode.darken,
              ),
              child: Avatar(
                mxContent: avatarUrl,
                size: MediaQuery.sizeOf(context).longestSide,
              ),
            ),
          )
        else
          const ColoredBox(color: Color(0xFF0A0A0F)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                accent.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0.85),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ColorScheme scheme;

  const _GlassChip({
    required this.icon,
    required this.label,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RippleHalo extends StatelessWidget {
  final AnimationController controller;
  final double offset;
  final Color color;

  const _RippleHalo({
    required this.controller,
    required this.offset,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final raw = (controller.value + offset) % 1.0;
        final t = Curves.easeOut.transform(raw);
        final size = 180.0 + t * 100.0;
        final opacity = (1.0 - t) * 0.55;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withValues(alpha: opacity),
              width: 1.5 + (1.0 - t) * 1.0,
            ),
          ),
        );
      },
    );
  }
}

class _CallActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color background;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
  });

  @override
  State<_CallActionButton> createState() => _CallActionButtonState();
}

class _CallActionButtonState extends State<_CallActionButton>
    with SingleTickerProviderStateMixin {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _down ? 0.88 : 1.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.elasticOut,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.background,
                boxShadow: [
                  BoxShadow(
                    color: widget.background.withValues(alpha: 0.55),
                    blurRadius: 28,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(widget.icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          widget.label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}
