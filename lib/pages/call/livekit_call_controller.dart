import 'dart:async';

import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:fluffychat/utils/rtc/livekit_gateway.dart';
import 'package:fluffychat/utils/rtc/rtc_call.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' show Logs, WrappedMediaStream;

/// Pilote RTC de l'écran d'appel : implémente l'interface déjà utilisée par
/// la page (et ses tests), posée sur [RtcCall] + [RtcMediaGateway].
///
/// Comme pour le legacy après le fix du 15/10, l'état des boutons est local et
/// faisant foi ; la gateway propage l'intention (et LiveKit la signale au
/// pair, ce que le legacy ne faisait pas).
class LiveKitCallController extends CallController {
  LiveKitCallController({
    required RtcCall call,
    required RtcMediaGateway gateway,
    required this.remoteName,
    required this.remoteMxid,
  }) : _call = call,
       _gateway = gateway {
    _stateSub = _call.onStateChanged.listen((s) {
      if (s == CallState.active) markConnected();
      notifyListeners();
    });
  }

  final RtcCall _call;
  final RtcMediaGateway _gateway;

  @override
  final String remoteName;
  @override
  final String? remoteMxid;

  StreamSubscription<CallState>? _stateSub;

  bool _micMuted = false;
  bool _cameraOff = false;
  bool _speakerOn = true;

  CallState get callState => _call.state;

  @override
  bool get isVideo => _call.wantVideo;

  @override
  bool get micMuted => _micMuted;

  @override
  bool get cameraOff => _cameraOff;

  @override
  bool get speakerOn => _speakerOn;

  @override
  bool get reconnecting => false; // LiveKit se reconnecte seul (v1)

  @override
  bool get connecting =>
      _call.state == CallState.connecting ||
      _call.state == CallState.ringingOut ||
      _call.state == CallState.ringingIn;

  @override
  bool get connected => _call.state == CallState.active;

  /// Non utilisés côté RTC : la page reçoit des widgets `VideoTrackRenderer`
  /// fournis par [tracks] (voir [LiveKitTracks]).
  @override
  WrappedMediaStream? get localStream => null;

  @override
  WrappedMediaStream? get remoteStream => null;

  /// Émissions des pistes à rendre ; vide pour les gateways sans média live.
  Stream<LiveKitTracks> get tracks {
    final gateway = _gateway;
    return gateway is LiveKitGateway ? gateway.tracks : const Stream.empty();
  }

  Future<void> start() => _call.start();

  Future<void> accept() => _call.accept();

  @override
  void toggleMic() {
    _micMuted = !_micMuted;
    notifyListeners();
    unawaited(_apply('micro', _gateway.setAudioMuted(_micMuted)));
  }

  @override
  void toggleCamera() {
    if (!isVideo) return;
    _cameraOff = !_cameraOff;
    notifyListeners();
    unawaited(_apply('camera', _gateway.setCameraMuted(_cameraOff)));
  }

  @override
  void flipCamera() {
    if (!isVideo) return;
    unawaited(_apply('flip caméra', _gateway.flipCamera()));
  }

  /// Le routage audio d'un appel RTC appartient à LiveKit (AudioManager) :
  /// toucher la session depuis le bridge legacy en parallèle créait des
  ///-artefacts ("son moisi", terrain 15/10).
  @override
  void toggleSpeaker() {
    _speakerOn = !_speakerOn;
    notifyListeners();
    unawaited(
      lk.AudioManager.instance.setSpeakerOutputPreferred(_speakerOn),
    );
  }

  @override
  void hangup() {
    unawaited(_call.hangup());
  }

  Future<void> _apply(String what, Future<void> future) async {
    try {
      await future;
    } catch (e) {
      Logs().w('[RTC] $what ignoré: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    super.dispose();
  }
}
