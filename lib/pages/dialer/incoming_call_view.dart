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
  final Future<void> Function(String message)? onReplyAndDecline;

  const IncomingCallView({
    required this.room,
    required this.caller,
    required this.encrypted,
    required this.onAnswer,
    required this.onDecline,
    this.onReplyAndDecline,
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

  Future<void> _openCustomReply(BuildContext context) async {
    HapticFeedback.selectionClick();
    final controller = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      'Répondre par message',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLines: 4,
                      minLines: 2,
                      style: TextStyle(color: scheme.onSurface),
                      decoration: InputDecoration(
                        hintText: 'Tape un message qui sera envoyé puis '
                            'l\'appel sera décliné',
                        hintStyle: TextStyle(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            child: const Text('Annuler'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final text = controller.text.trim();
                              if (text.isEmpty) return;
                              Navigator.pop(sheetContext, text);
                            },
                            child: const Text('Envoyer & décliner'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    if (result != null && result.isNotEmpty && mounted) {
      await widget.onReplyAndDecline?.call(result);
    }
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
                          _CallerAvatar(
                            avatarUrl: avatarUrl,
                            displayName: displayName,
                            accent: scheme.primary,
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
                  if (widget.onReplyAndDecline != null)
                    _ReplyTemplatesRow(
                      onPick: (msg) async {
                        HapticFeedback.selectionClick();
                        await widget.onReplyAndDecline!(msg);
                      },
                      onCustom: () => _openCustomReply(context),
                    ),
                  if (widget.onReplyAndDecline != null)
                    const SizedBox(height: 20),
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

/// Avatar XL avec fallback cyberpunk gradient quand l'appelant n'a pas
/// d'avatar mxc. Le hash du displayName décide de la palette pour rester
/// stable entre appels.
class _CallerAvatar extends StatelessWidget {
  final Uri? avatarUrl;
  final String displayName;
  final Color accent;

  const _CallerAvatar({
    required this.avatarUrl,
    required this.displayName,
    required this.accent,
  });

  static const List<List<Color>> _palettes = [
    [Color(0xFF7B2FF7), Color(0xFFF107A3)], // violet → pink
    [Color(0xFF00DBDE), Color(0xFFFC00FF)], // cyan → magenta
    [Color(0xFF4158D0), Color(0xFFC850C0)], // indigo → fuchsia
    [Color(0xFF0093E9), Color(0xFF80D0C7)], // azure → mint
    [Color(0xFFFA8BFF), Color(0xFF2BD2FF)], // pink → cyan
    [Color(0xFFFF3CAC), Color(0xFF562B7C)], // hot pink → purple
  ];

  @override
  Widget build(BuildContext context) {
    final outer = Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
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
      child: avatarUrl != null
          ? Avatar(
              mxContent: avatarUrl,
              name: displayName,
              size: 180,
            )
          : _CyberpunkFallback(seed: displayName),
    );
    return outer;
  }
}

/// Fallback when no avatar is set: cyberpunk-ish radial gradient + the
/// caller initial in a glowing serif-like font.
class _CyberpunkFallback extends StatelessWidget {
  final String seed;

  const _CyberpunkFallback({required this.seed});

  int _seedIndex() {
    var hash = 0;
    for (final code in seed.runes) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return hash % _CallerAvatar._palettes.length;
  }

  @override
  Widget build(BuildContext context) {
    final palette = _CallerAvatar._palettes[_seedIndex()];
    final initial = seed.runes.isEmpty
        ? '?'
        : String.fromCharCode(seed.runes.first).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 1.1,
          colors: [palette[0], palette[1], const Color(0xFF0F0A1E)],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Subtle scanline overlay for neon vibe.
          const Opacity(
            opacity: 0.08,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.white, Colors.transparent],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
          Text(
            initial,
            style: TextStyle(
              color: Colors.white,
              fontSize: 96,
              fontWeight: FontWeight.w800,
              letterSpacing: -2,
              shadows: [
                Shadow(
                  color: palette[1].withValues(alpha: 0.8),
                  blurRadius: 24,
                ),
                Shadow(
                  color: palette[0].withValues(alpha: 0.6),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyTemplatesRow extends StatelessWidget {
  final Future<void> Function(String message) onPick;
  final VoidCallback onCustom;

  const _ReplyTemplatesRow({required this.onPick, required this.onCustom});

  static const List<_ReplyTemplate> _templates = [
    _ReplyTemplate(
      icon: Icons.access_time,
      label: 'Je te rappelle',
      message: 'Pas dispo là, je te rappelle dès que possible.',
    ),
    _ReplyTemplate(
      icon: Icons.event_busy,
      label: 'En réunion',
      message: 'En réunion, je te recontacte plus tard.',
    ),
    _ReplyTemplate(
      icon: Icons.directions_car,
      label: 'Au volant',
      message: 'Au volant, je te rappelle dès que je peux.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final t in _templates) ...[
            _ReplyChip(
              icon: t.icon,
              label: t.label,
              onTap: () => onPick(t.message),
            ),
            const SizedBox(width: 8),
          ],
          _ReplyChip(
            icon: Icons.edit_outlined,
            label: 'Custom…',
            onTap: onCustom,
          ),
        ],
      ),
    );
  }
}

class _ReplyTemplate {
  final IconData icon;
  final String label;
  final String message;

  const _ReplyTemplate({
    required this.icon,
    required this.label,
    required this.message,
  });
}

class _ReplyChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ReplyChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: Colors.white.withValues(alpha: 0.1),
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 0.5,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
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
