import 'dart:async';

import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:fluffychat/pages/call/voip_bridge.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide VideoRenderer;
import 'package:matrix/matrix.dart';

/// Implémente [CallController] au-dessus d'une vraie [CallSession] du SDK.
///
/// C'est le seul endroit qui parle au SDK VoIP : l'UI ne connaît que l'interface,
/// donc [ActiveCallPage] reste testable sans WebRTC.
class VoipCallController extends CallController {
  VoipCallController(this.session, {VoipBridge? bridge})
    : _bridge = bridge ?? VoipBridge() {
    session.onCallStateChanged.stream.listen((_) => notifyListeners());
    _listenStreams();
  }

  final CallSession session;
  final VoipBridge _bridge;

  /// `facingMode` courant du flux vidéo local. Le SDK ne l'expose pas.
  String _facingMode = 'user';

  @override
  String get remoteName =>
      session.remoteUserId ?? session.room.getLocalizedDisplayname();

  @override
  bool get isVideo => session.type == CallType.kVideo;

  @override
  bool get micMuted => session.isMicrophoneMuted;

  @override
  bool get cameraOff => session.isLocalVideoMuted;

  @override
  bool get speakerOn => _speakerOn;

  bool _speakerOn = true;

  @override
  bool get reconnecting =>
      session.pc?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;

  /// Invitation envoyée ou reçue, flux WebRTC pas encore établi.
  @override
  bool get connecting =>
      session.state == CallState.kInviteSent ||
      session.state == CallState.kWaitLocalMedia ||
      session.state == CallState.kCreateOffer ||
      session.state == CallState.kCreateAnswer ||
      session.state == CallState.kConnecting;

  @override
  bool get connected => session.state == CallState.kConnected;

  /// Flux vidéo local (ma webcam). Expose tel quel : [VideoRenderer] sait lire un
  /// WrappedMediaStream et suivre ses changements.
  WrappedMediaStream? get localStream => session.localUserMediaStream;

  /// Flux vidéo distant (l'autre interlocuteur).
  WrappedMediaStream? get remoteStream => session.remoteUserMediaStream;

  /// Recalcule l'UI quand un flux apparrive ou disparait — c'est le cas typique
  /// quand l'autre active sa caméra en plein appel.
  void _listenStreams() {
    session.onCallStreamsChanged.stream.listen((_) => notifyListeners());
  }

  @override
  void toggleMic() {
    final stream = session.localUserMediaStream;
    if (stream == null) {
      Logs().w('[VOIP] toggleMic sans flux local');
      return;
    }
    stream.setAudioMuted(!session.isMicrophoneMuted);
    notifyListeners();
  }

  @override
  void toggleCamera() {
    if (!isVideo) return;
    final stream = session.localUserMediaStream;
    if (stream == null) {
      Logs().w('[VOIP] toggleCamera sans flux local');
      return;
    }
    stream.setVideoMuted(!session.isLocalVideoMuted);
    notifyListeners();
  }

  @override
  void flipCamera() {
    if (!isVideo) return;
    unawaited(_flipCamera());
  }

  /// Rebascule la caméra avant/arrière.
  ///
  /// Le SDK n'expose pas de `switchCamera` : on récupère un nouveau flux avec le
  /// `facingMode` opposé et on l'injecte via [WrappedMediaStream.setNewStream],
  /// qui met à jour la transceiver en place (c'est le mécanisme utilisé par le SDK
  /// lui-même lors d'un changement de périphérique).
  Future<void> _flipCamera() async {
    final next = _facingMode == 'user' ? 'environment' : 'user';
    try {
      final stream = await session.voip.delegate.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'width': 1280,
          'height': 720,
          'facingMode': next,
        },
      });
      _facingMode = next;
      session.localUserMediaStream?.setNewStream(stream);
      notifyListeners();
    } catch (e) {
      Logs().w('[VOIP] flipCamera a échoué: $e');
    }
  }

  @override
  void toggleSpeaker() {
    _speakerOn = !_speakerOn;
    // Haut-parleur <-> contre-oreille : seule alternative reelle sans filaire.
    // Passer par "wired" trouvait aucun device et retombait en silence sur le
    // speaker, d'oie le haut-parleur obligatoire (bug 2026-10-14).
    // En Bluetooth le mode téléphone est le défaut ; le haut-parleur est un choix.
    unawaited(
      _bridge.setAudioRoute(
        _speakerOn ? AudioRoute.speaker : AudioRoute.earpiece,
      ),
    );
    notifyListeners();
  }

  @override
  void hangup() {
    unawaited(session.hangup(reason: CallErrorCode.userHangup));
  }

  /// Route forcée par le natif (casque Bluetooth connecté ou déconnecté en plein
  /// appel) — l'UI doit refléter l'audio réel, pas l'intention initiale.
  void onNativeRouteChanged(String route) {
    final wasSpeaker = _speakerOn;
    _speakerOn = route == 'speaker';
    if (wasSpeaker != _speakerOn) notifyListeners();
  }
}