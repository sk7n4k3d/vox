import 'dart:async';

import 'package:fluffychat/config/cyberpunk_theme_extension.dart';
import 'package:fluffychat/pages/call/call_theme.dart';
import 'package:fluffychat/utils/voip/video_renderer.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide VideoRenderer;
import 'package:matrix/matrix.dart' show WrappedMediaStream;
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

  /// Invitation envoyée, réponse de l'autre côté pas encore reçue.
  bool get connecting;

  /// Vrai quand l'autre côté a décroché et que l'audio circule.
  bool get connected;

  /// Flux vidéo local (ma webcam) et distant (l'interlocuteur).
  WrappedMediaStream? get localStream;
  WrappedMediaStream? get remoteStream;

  /// Identifiant Matrix brut, affiché en petit sous le nom (null = on ne
  /// connaît que le nom d'affichage).
  String? get remoteMxid => null;

  /// Moment où l'appel est passé en connecté (null avant) — base du chrono.
  DateTime? get connectedAt => _connectedAt;
  DateTime? _connectedAt;

  /// À appeler par l'implémentation quand la session annonce `kConnected`.
  void markConnected() => _connectedAt ??= DateTime.now();

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
class ActiveCallPage extends StatefulWidget {
  const ActiveCallPage({
    required this.controller,
    this.remoteVideo,
    this.localVideo,
    super.key,
  });

  final CallController controller;

  /// Rendus fournis par l'appelant (tests) ; sinon la page construit les siens
  /// a partir des flux du contrôleur.
  final Widget? remoteVideo;
  final Widget? localVideo;

  @override
  State<ActiveCallPage> createState() => _ActiveCallPageState();
}

class _ActiveCallPageState extends State<ActiveCallPage> {
  CallController get controller => widget.controller;

  /// Inverse l'image de l'interlocuteur et la mienne. Simple preference
  /// d'affichage : rien ne change côté WebRTC.
  bool _swapped = false;

  void _swap() => setState(() => _swapped = !_swapped);

  /// Le chrono tique une fois la seconde tant que l'appel est connecté.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ActiveCallPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick = controller.connectedAt != null;
    final ticking = _ticker != null;
    if (shouldTick && !ticking) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!shouldTick && ticking) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _elapsed() {
    final since = controller.connectedAt;
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // connectedAt peut apparaitre pendant l'appel : le ticker se branche ici,
        // pas seulement dans initState/didUpdateWidget.
        _syncTicker();
        // L'image de l'interlocuteur est principale par defaut. Le mirror
        // (retournement horizontal) n'est mis que sur MA vue, sinon celle de
        // l'autre sortirait inversée.
        final mainStream =
            _swapped ? controller.localStream : controller.remoteStream;
        final pipStream =
            _swapped ? controller.remoteStream : controller.localStream;

        final mainVideo =
            widget.remoteVideo ??
            VideoRenderer(
              mainStream,
              mirror: _swapped,
              fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            );
        final pipVideo =
            widget.localVideo ?? VideoRenderer(pipStream, mirror: !_swapped);

        final noVideoAtAll =
            controller.remoteStream == null && controller.localStream == null;

        // Ce que remplit l'écran sous les voiles : l'image principale quand elle
        // existe, sinon un fond vivant avec l'avatar de l'interlocuteur — plus
        // jamais le rectangle gris mort de l'ancien appel vidéo.
        final Widget stage;
        if (!controller.isVideo) {
          stage = _EmptyStage(
            cyber: cyber,
            child: _CallerBadge(name: controller.remoteName),
          );
        } else if (mainStream != null ||
            widget.remoteVideo != null ||
            (controller.localStream != null && _swapped)) {
          stage = mainVideo;
        } else {
          stage = _EmptyStage(
            cyber: cyber,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CallerBadge(name: controller.remoteName),
                const SizedBox(height: 20),
                Text(
                  controller.connecting
                      ? 'Connexion…'
                      : 'En attente de l\'image',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: CallTheme.background,
          body: Stack(
            fit: StackFit.expand,
            children: [
              stage,
              // Voiles haut/bas : sans eux, les textes blancs disparaissent
              // dès que la vidéo est claire.
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 150,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xB3000000), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 210,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _TopBar(controller: controller, elapsed: _elapsed()),
                    const Spacer(),
                    if (controller.reconnecting) const _ReconnectingBanner(),
                    _Controls(
                      controller: controller,
                      onSwap: controller.isVideo ? _swap : null,
                    ),
                  ],
                ),
              ),
              if (controller.isVideo && !noVideoAtAll)
                Positioned(
                  right: 14,
                  bottom: 150,
                  child: GestureDetector(
                    onTap: _swap,
                    child: _Pip(
                      cyber: cyber,
                      hint: _swapped ? 'vue normale' : 'inverser',
                      child: pipVideo,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Fond des situations sans image : noir profond + halo cyan/magenta très lent
/// (30 s par aller-retour — la règle du contrat d'animation : rien de clinquant
/// pendant que la sonnerie ou l'audio tournent).
class _EmptyStage extends StatelessWidget {
  const _EmptyStage({required this.cyber, required this.child});

  final CyberpunkTheme cyber;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _SlowGlow(
      duration: const Duration(seconds: 30),
      builder: (context, phase) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6 + 1.2 * phase, -0.5),
            radius: 1.1,
            colors: [
              cyber.cyan.withValues(alpha: 0.10),
              cyber.magenta.withValues(alpha: 0.06),
              Colors.transparent,
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// Aller-retour 0 → 1 → 0 sans TickProvider : borné, testable, zéro ticker.
class _SlowGlow extends StatefulWidget {
  const _SlowGlow({required this.duration, required this.builder});

  final Duration duration;
  final Widget Function(BuildContext context, double phase) builder;

  @override
  State<_SlowGlow> createState() => _SlowGlowState();
}

class _SlowGlowState extends State<_SlowGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) =>
        widget.builder(context, Curves.easeInOut.transform(_controller.value)),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, this.elapsed = ''});

  final CallController controller;
  final String elapsed;

  String get _status {
    if (controller.reconnecting) return 'Connexion perdue…';
    if (controller.connecting) return 'Sonnerie…';
    return 'Connecté';
  }

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);
    final statusColor = controller.reconnecting
        ? cyber.warn
        : controller.connecting
        ? cyber.cyan
        : cyber.success;
    final mxid = controller.remoteMxid;
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
            ).textTheme.titleLarge?.copyWith(color: Colors.white),
          ),
          if (mxid != null && mxid != controller.remoteName) ...[
            const SizedBox(height: 2),
            Text(
              mxid,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white38,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withValues(alpha: 0.7),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _status,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: statusColor,
                ),
              ),
              if (elapsed.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  elapsed,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, this.onSwap});

  final CallController controller;

  /// Inverse les deux images d'un appel vidéo. Absent en appel vocal.
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    // Six controles en video : libelles de 74 dp sous chaque bouton, soit ~490 dp
    // de contenu pour 312 dp disponibles sur un phone. Le raccrocher (a droite)
    // sortait entierement de l'ecran : mesure 394..468 sur 360 dp.
    final compact = controller.isVideo;
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 12, 8, 24)
          : const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Control(
            compact: compact,
            key: const Key('call-toggle-mic'),
            icon: controller.micMuted ? Icons.mic_off : Icons.mic,
            label: controller.micMuted ? 'Micro coupé' : 'Couper le micro',
            active: controller.micMuted,
            mutedState: controller.micMuted,
            onTap: controller.toggleMic,
          ),
          if (controller.isVideo)
            _Control(
              compact: compact,
              key: const Key('call-toggle-camera'),
              icon: controller.cameraOff
                  ? Icons.videocam_off
                  : Icons.videocam,
              label: controller.cameraOff ? 'Caméra off' : 'Caméra',
              active: controller.cameraOff,
              mutedState: controller.cameraOff,
              onTap: controller.toggleCamera,
            ),
          if (controller.isVideo)
            _Control(
              compact: compact,
              key: const Key('call-flip-camera'),
              icon: Icons.cameraswitch_outlined,
              label: 'Retourner la caméra',
              onTap: controller.flipCamera,
            ),
          if (onSwap != null)
            _Control(
              compact: compact,
              key: const Key('call-swap-video'),
              icon: Icons.swap_horiz_rounded,
              label: 'Inverser les vues',
              onTap: onSwap!,
            ),
          _Control(
            compact: compact,
            key: const Key('call-toggle-speaker'),
            icon: controller.speakerOn
                ? Icons.volume_up
                : Icons.volume_down,
            label: 'Haut-parleur',
            active: controller.speakerOn,
            onTap: controller.toggleSpeaker,
          ),
          _Control(
            compact: compact,
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
    this.mutedState = false,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool danger;

  /// Vrai quand ce bouton représente une coupure (micro ou caméra hors service)
  /// : le rouge remplace le cyan, pour que « coupé » se voie de loin.
  final bool mutedState;

  /// Mode video : six controles sur un ecran de phone ne tiennent pas avec un
  /// libelle de 74 dp sous chaque bouton — le raccrocher, a droite, sortait
  /// completement de l'ecran (mesure: left=394 sur un 360 dp).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cyber = CallTheme.of(context);
    final color = danger
        ? Colors.white
        : (mutedState ? CallTheme.decline : (active ? cyber.cyan : Colors.white));
    final surface = danger
        ? CallTheme.decline
        : mutedState
        ? cyber.glassBorder.withValues(alpha: 0.9)
        : CallTheme.controlSurface(cyber, active: active);
    final size = compact
        ? (danger ? CallTheme.controlRadius * 1.4 : CallTheme.controlRadius * 1.2)
        : CallTheme.controlRadius * 1.7;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: surface,
            shape: const CircleBorder(),
            // Le raccrocher porte un halo rouge : c'est LE bouton qu'on doit
            // trouver sans réfléchir, même à une main dans le noir.
            child: Ink(
              decoration: danger
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: CallTheme.decline.withValues(alpha: 0.45),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                      ],
                    )
                  : null,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Icon(icon, color: color, size: compact ? 24 : 26),
                ),
              ),
            ),
          ),
        ),
        if (!compact) ...[
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
  const _Pip({required this.cyber, this.hint, this.child});

  final CyberpunkTheme cyber;
  final String? hint;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 146,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cyber.cyan.withValues(alpha: 0.55), width: 1.4),
        color: Colors.black,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child ?? const SizedBox.shrink(),
          if (hint != null)
            Positioned(
              left: 5,
              bottom: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.swap_horiz_rounded,
                    size: 14,
                    color: cyber.cyan.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
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
        border: Border.all(color: cyber.cyan.withValues(alpha: 0.6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: cyber.cyan.withValues(alpha: 0.25),
            blurRadius: 24,
          ),
        ],
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
