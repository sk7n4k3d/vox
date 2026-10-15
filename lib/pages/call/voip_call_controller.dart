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
    _logStreams();
    session.onCallStateChanged.stream.listen((s) {
      // .w et pas .i : en release le SDK matrix coupe les niveaux info/verbose, un
      // log de diagnostic en .i est invisible (perdu des heures sur ça le 2026-10-15).
      Logs().w('[VOIP] état: ${s.name}');
      if (s.name == 'kConnected') {
        markConnected();
        unawaited(_logSdp());
        // Micro coupé pendant la sonnerie : addLocalStream initialise ses
        // drapeaux de lui-même et ignore l'intention déjà posée — la
        // réappliquer dès que les pistes existent.
        if (_micMuted) {
          unawaited(session.setMicrophoneMuted(true));
        }
        if (_cameraOff) {
          unawaited(session.setLocalVideoMuted(true));
        }
      }
      notifyListeners();
    });
    _listenStreams();
  }

  final CallSession session;
  final VoipBridge _bridge;

  /// `facingMode` courant du flux vidéo local. Le SDK ne l'expose pas.
  String _facingMode = 'user';

  /// Le nom que le compte affiche passe avant l'identifiant brut :
  /// « Alice - Appels » se lit, `@alice:matrix.sk7.sh` se copie.
  @override
  String get remoteName {
    final localized = session.room.getLocalizedDisplayname();
    if (localized.trim().isNotEmpty) return localized;
    return session.remoteUserId ?? 'Inconnu';
  }

  @override
  String? get remoteMxid => session.remoteUserId;

  @override
  bool get isVideo => session.type == CallType.kVideo;

  /// État de coupure local, faisant foi. `session.isMicrophoneMuted` renvoie
  /// vrai dès que la liste des pistes du flux est vide côté Dart, micro
  /// réellement actif ou non — le bouton restait bloqué sur « coupé » et ne
  /// revenait plus jamais (appel du 2026-10-15).
  bool _micMuted = false;
  bool _cameraOff = false;

  @override
  bool get micMuted => _micMuted;

  @override
  bool get cameraOff => _cameraOff;

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
    session.onCallStreamsChanged.stream.listen((_) {
      _logStreams();
      notifyListeners();
    });
  }

  /// Etat reel des flux : c'est le point de bascule de toute la partie video et
  /// des boutons micro/camera. Un flux absent = aucun rendu et des boutons inertes.
  /// Contenu video reellement annonce et recu. C'est LA preuve qui manque :
  /// sans elle on devine entre « VOX n'annonce pas de video » et « le distant
  /// n'en envoie pas ». On resume le SDP au lieu de le dumper (des KiB).
  Future<void> _logSdp() async {
    try {
      final pc = session.pc;
      if (pc == null) {
        Logs().w('[VOIP] SDP: pas de peer connection');
        return;
      }
      String summarize(String? sdp, String who) {
        if (sdp == null) return '$who SDP=null';
        final m = RegExp(r'^m=(audio|video).*$', multiLine: true)
            .allMatches(sdp)
            .map((e) => e.group(1))
            .join('+');
        final dir = RegExp(r'^a=(sendrecv|sendonly|recvonly|inactive).*$', multiLine: true)
                .allMatches(sdp)
                .map((e) => e.group(1))
                .toList();
        final codec = RegExp(r'VP8|VP9|H264|AV1')
                .allMatches(sdp.toUpperCase())
                .map((e) => e.group(0))
                .toSet()
                .join('/');
        return '$who media=[$m] directions=[${dir.join(",")}] codecs=[$codec]';
      }

      Logs().w('[VOIP] ' + summarize((await pc.getLocalDescription())?.sdp, 'local'));
      Logs().w('[VOIP] ' + summarize((await pc.getRemoteDescription())?.sdp, 'distant'));
      final receivers = await pc.getReceivers();
      Logs().w(
        '[VOIP] tracks distants=${receivers.where((r) => r.track != null).length} '
        'types=${receivers.map((r) => r.track?.kind ?? "?").toSet().join(",")}',
      );
    } catch (e) {
      Logs().w('[VOIP] SDP illisible: $e');
    }
  }

  void _logStreams() {
    final local = session.localUserMediaStream;
    final remote = session.remoteUserMediaStream;
    Logs().w(
      '[VOIP] flux local=${local != null} '
      'mediaStream=${local?.stream != null} videoMuted=${local?.isVideoMuted()} | '
      'distant=${remote != null} mediaStream=${remote?.stream != null}',
    );
  }

  @override
  void toggleMic() {
    _micMuted = !_micMuted;
    notifyListeners();
    unawaited(_applyMicMute());
  }

  /// `session.setMicrophoneMuted` est le seul chemin qui coupe vraiment le
  /// micro : il pose le drapeau de mute, désactive les pistes WebRTC via
  /// `updateMuteStatus` et prévient le pair. `WrappedMediaStream.setAudioMuted`
  /// ne posait qu'un booléen — bouton rouge, micro toujours ouvert aux oreilles
  /// de l'interlocuteur (bug du 2026-10-15).
  Future<void> _applyMicMute() async {
    try {
      await session.setMicrophoneMuted(_micMuted);
    } catch (e) {
      Logs().w('[VOIP] setMicrophoneMuted a échoué: $e');
    }
    _logMuteState('micro=${_micMuted ? "coupé" : "actif"}');
  }

  @override
  void toggleCamera() {
    if (!isVideo) return;
    _cameraOff = !_cameraOff;
    notifyListeners();
    unawaited(_applyCameraMute());
  }

  Future<void> _applyCameraMute() async {
    try {
      await session.setLocalVideoMuted(_cameraOff);
    } catch (e) {
      Logs().w('[VOIP] setLocalVideoMuted a échoué: $e');
    }
    _logMuteState('camera=${_cameraOff ? "off" : "on"}');
  }

  /// Ce que le SDK voit des pistes locales : audio=0 pendant que le micro
  /// émet = liste de pistes désynchronisée, le mutisme réel ne peut alors
  /// passer que par les pistes des senders (durcissement côté SDK).
  void _logMuteState(String why) {
    final local = session.localUserMediaStream?.stream;
    Logs().w(
      '[VOIP] mute ($why) pistes locales '
      'audio=${local?.getAudioTracks().length ?? -1} '
      'video=${local?.getVideoTracks().length ?? -1}',
    );
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