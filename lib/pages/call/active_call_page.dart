import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/pages/call/call_theme.dart';
import 'package:flutter/material.dart';

/// Ce que [ActiveCallPage] a besoin de savoir d'une session d'appel.
///
/// `CallSession` du SDK est câblé au WebRTC et à la matrice : impossible à
/// instancier dans un test. Cette interface est le seul contrat entre la page et
/// la session réelle (`VoipCallController` l'implémente), ce qui rend l'UI
/// testable et la session remplaçable.
abstract class CallController extends ChangeNotifier {
  String get remoteName;
  bool get isVideo;
  bool get micMuted;
  bool get cameraOff;
  bool get speakerOn;
  bool get reconnecting;

  void toggleMic();
  void toggleCamera();
  void flipCamera();
  void toggleSpeaker();
  void hangup();
}

/// Écran d'appel en cours, plein écran.
///
/// Le rendu vidéo est fourni par l'appelant (`remoteVideo` / `localVideo`) plutôt
/// que construit ici : c'est le `RTCVideoRenderer` qui a la durée de vie, et il
/// belongs au `CallSession`.
class ActiveCallPage extends StatelessWidget {
  const ActiveCallPage({
    required this.controller,
    this.remoteVideo,
    this.localVideo,
    super.key,
  });

  final CallController controller;
  final Widget? remoteVideo;
  final Widget? localVideo;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: CallTheme.background,
          body: SafeArea(
            child: Column(
              children: [
                _TopBar(controller: controller),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: controller.isVideo
                            ? (remoteVideo ?? _NoVideoPlaceholder(cyber: cyber))
                            : Center(
                                child: _CallerBadge(name: controller.remoteName),
                              ),
                      ),
                      if (controller.isVideo)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _Pip(child: localVideo),
                        ),
                    ],
                  ),
                ),
                if (controller.reconnecting) const _ReconnectingBanner(),
                _Controls(controller: controller),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Text(
            controller.remoteName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: controller.micMuted
                  ? CallTheme.decline
                  : cyber.success,
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        border: Border(
          top: BorderSide(
            color: CallTheme.of(context).glassBorder.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Control(
            key: const Key('call-toggle-mic'),
            icon: controller.micMuted ? Icons.mic_off : Icons.mic,
            label: controller.micMuted ? 'Micro coupé' : 'Couper le micro',
            active: controller.micMuted,
            onTap: controller.toggleMic,
          ),
          if (controller.isVideo)
            _Control(
              key: const Key('call-toggle-camera'),
              icon: controller.cameraOff
                  ? Icons.videocam_off
                  : Icons.videocam,
              label: controller.cameraOff ? 'Caméra off' : 'Caméra',
              active: controller.cameraOff,
              onTap: controller.toggleCamera,
            ),
          if (controller.isVideo)
            _Control(
              key: const Key('call-flip-camera'),
              icon: Icons.cameraswitch_outlined,
              label: 'Retourner la caméra',
              onTap: controller.flipCamera,
            ),
          _Control(
            key: const Key('call-toggle-speaker'),
            icon: controller.speakerOn
                ? Icons.volume_up
                : Icons.volume_down,
            label: 'Haut-parleur',
            active: controller.speakerOn,
            onTap: controller.toggleSpeaker,
          ),
          _Control(
            key: const Key('call-hangup'),
            icon: Icons.call_end,
            label: 'Raccrocher',
            danger: true,
            onTap: controller.hangup,
          ),
        ],
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);
    final color = danger
        ? CallTheme.decline
        : (active ? cyber.cyan : Colors.white);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: CallTheme.controlSurface(cyber, active: active),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: CallTheme.controlRadius * 1.7,
                height: CallTheme.controlRadius * 1.7,
                child: Icon(icon, color: color, size: 26),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 74,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ],
    );
  }
}

/// Bandeau affiché quand la négociation ICE refait surface (changement de réseau,
/// sortie de veille). Review Focus n°4 : l'utilisateur doit comprendre l'attente.
class _ReconnectingBanner extends StatelessWidget {
  const _ReconnectingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: CallTheme.of(context).warn.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            'Connexion perdue — reconnexion…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: CallTheme.of(context).warn,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pip extends StatelessWidget {
  const _Pip({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 128,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CallTheme.of(context).glassBorder.withValues(alpha: 0.5),
        ),
        color: Colors.black,
      ),
      clipBehavior: Clip.antiAlias,
      child: child ?? const SizedBox.shrink(),
    );
  }
}

class _NoVideoPlaceholder extends StatelessWidget {
  const _NoVideoPlaceholder({required this.cyber});

  final CyberpunkTheme cyber;

  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      Icons.videocam_off_outlined,
      size: 64,
      color: cyber.glassBorder,
    ),
  );
}

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