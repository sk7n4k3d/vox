import 'package:fluffychat/pages/call/call_theme.dart';
import 'package:flutter/material.dart';

/// Écran d'appel entrant, plein écran.
///
/// Le bouton « répondre » se verrouille au premier appui : un double-tap ne doit
/// jamais démarrer deux sessions WebRTC pour le même `callId` (Review Focus n°1).
/// Même verrou sur « raccrocher », pour le double-tap inverse.
class IncomingCallPage extends StatefulWidget {
  const IncomingCallPage({
    required this.callId,
    required this.roomId,
    required this.callerName,
    required this.video,
    required this.onAnswer,
    required this.onDecline,
    super.key,
  });

  final String callId;
  final String roomId;
  final String callerName;
  final bool video;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage> {
  bool _handled = false;

  void _handle(VoidCallback action) {
    if (_handled) return;
    setState(() => _handled = true);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);

    return Scaffold(
      backgroundColor: CallTheme.background,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.4,
            colors: [
              cyber.cyan.withValues(alpha: 0.18),
              CallTheme.background,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              _CallerBadge(
                name: widget.callerName,
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  widget.callerName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.video ? Icons.videocam_outlined : Icons.mic_outlined,
                    size: 16,
                    color: cyber.glassBorder,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.video ? 'Appel vidéo entrant' : 'Appel vocal entrant',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cyber.glassBorder,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 56),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleAction(
                      key: const Key('incoming-decline'),
                      icon: Icons.call_end,
                      color: CallTheme.decline,
                      label: 'Refuser',
                      onPressed: _handled ? null : () => _handle(widget.onDecline),
                    ),
                    _CircleAction(
                      key: const Key('incoming-answer'),
                      icon: Icons.call,
                      color: CallTheme.answer,
                      label: 'Répondre',
                      onPressed: _handled ? null : () => _handle(widget.onAnswer),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pastille d'initiales à la place de l'avatar Matrix.
///
/// `Avatar` exige un `Provider<MatrixState>` ; l'écran d'appel est posé en overlay
/// racine et doit rester montable même si la matrice n'est pas prête. On dégrade donc
/// proprement au lieu de planter.
class _CallerBadge extends StatelessWidget {
  const _CallerBadge({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);
    final initials = name
        .trim()
        .split(RegExp(r'[\s@:._-]+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();

    return Container(
      width: 132,
      height: 132,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            cyber.cyan.withValues(alpha: 0.35),
            cyber.magenta.withValues(alpha: 0.35),
          ],
        ),
        border: Border.all(color: cyber.glassBorder),
      ),
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: color.withValues(alpha: 0.16),
            shape: CircleBorder(
              side: BorderSide(color: color),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: CallTheme.controlRadius * 2,
                height: CallTheme.controlRadius * 2,
                child: Icon(icon, color: color, size: 32),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}