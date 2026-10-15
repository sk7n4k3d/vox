import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' show Logs;

import 'rtc_call.dart';
import 'rtc_sfu_client.dart';

/// Passerelle média LiveKit derrière [RtcMediaGateway] (la vraie, task 5).
///
/// Le mute passe par `publication.mute()/unmute()` : LiveKit propage l'état au
/// pair (le legacy `m.call` ne le faisait pas, d'où le bug de confiance du
/// 15/10). Les rendus vidéo sont exposés en [tracks] pour la page d'appel.
class LiveKitGateway implements RtcMediaGateway {
  final _remote = StreamController<RtcRemoteEvent>.broadcast();
  final _tracks = StreamController<LiveKitTracks>.broadcast();

  lk.Room? _room;
  Future<void> Function()? _eventCancel;
  LiveKitTracks _current = const LiveKitTracks();

  @override
  Stream<RtcRemoteEvent> get remoteEvents => _remote.stream;
  Stream<LiveKitTracks> get tracks => _tracks.stream;
  LiveKitTracks get currentTracks => _current;
  bool get e2eeActive => _room?.e2eeManager != null;

  /// Du média distant a déjà été souscrit au moins une fois : sert à rattraper
  /// un `mediaReady` émis AVANT que la machine à états ne s'abonne (course
  /// connect→publie→abonnement, qui laissait l'écran bloqué sur « connexion »,
  /// terrain 15/10 16:00).
  bool _remoteMediaSeen = false;
  @override
  bool get hasRemoteMedia => _remoteMediaSeen;

  lk.BaseKeyProvider? _keyProvider;
  final List<(String, int)> _pendingRemoteKeys = [];

  @override
  Future<void> connect(SfuCredentials credentials) async {
    final keyProvider = _keyProvider = await lk.BaseKeyProvider.create();
    final room = _room = lk.Room(
      roomOptions: lk.RoomOptions(
        adaptiveStream: true,
        dynacast: false,
        encryption: lk.E2EEOptions(keyProvider: keyProvider),
      ),
    );
    _eventCancel = room.events.listen(_onRoomEvent);
    await room.connect(credentials.livekitUrl, credentials.jwt);
    Logs().w('[RTC] connecté au SFU (participants: '
        '${room.remoteParticipants.length})');
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) =>
        unawaited(_logRemoteAudioStats()));
  }

  Timer? _statsTimer;

  /// Sonde du grésillement descendant (terrain 15/10) : `concealedSamples`
  /// compte les échantillons fabriqués par le masque-perte — ce sont
  /// littéralement les craquements entendus. Jitter/pertes élevés = réseau ;
  /// concealed à 0 et son pourri = pipeline audio local.
  @override
  Future<void> installOutboundKey(String keyLatin1, int index) async {
    final local = _room?.localParticipant;
    final kp = _keyProvider;
    if (local == null || kp == null) return;
    await kp.setKey(keyLatin1, participantId: local.sid, keyIndex: index);
  }

  @override
  Future<void> installRemoteKey(String keyLatin1, int index) async {
    final kp = _keyProvider;
    if (kp == null) return;
    final identity = _remoteIdentity();
    if (identity == null) {
      // la clé Olm peut précéder la connexion LiveKit du pair : on la garde,
      // [ParticipantConnectedEvent] la réinstallera.
      _pendingRemoteKeys.add((keyLatin1, index));
      return;
    }
    await kp.setKey(keyLatin1, participantId: identity, keyIndex: index);
  }

  /// 1:1 : la conversation n'a qu'un seul pair ; la clé d'un event de
  /// membership pair a donc une destination sans ambiguïté.
  String? _remoteIdentity() {
    final remoteParticipants = _room?.remoteParticipants.values;
    if (remoteParticipants == null) return null;
    for (final p in remoteParticipants) {
      if (p.identity.isNotEmpty) return p.identity;
    }
    return null;
  }

  Future<void> _flushPendingRemoteKeys() async {
    final pending = List.of(_pendingRemoteKeys);
    _pendingRemoteKeys.clear();
    for (final (key, index) in pending) {
      await installRemoteKey(key, index);
    }
  }

  Future<void> _logRemoteAudioStats() async {
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is! lk.RemoteAudioTrack) continue;
        try {
          final st = await t.getReceiverStats();
          if (st == null) continue;
          Logs().w('[RTC] stats audio entrant (${p.identity}): '
              'paquets=${st.packetsReceived} perdus=${st.packetsLost} '
              'jitter=${st.jitter?.toStringAsFixed(3)} '
              'masqués=${st.concealedSamples} events=${st.concealmentEvents} '
              'énergie=${st.totalAudioEnergy?.toStringAsFixed(2)}/'
              '${st.totalSamplesDuration?.toStringAsFixed(1)}s '
              '${st.mimeType} ${st.clockRate?.toInt()}Hz '
              'canaux=${st.channels?.toInt()}');
        } catch (e) {
          Logs().w('[RTC] stats audio indisponibles: $e');
        }
      }
    }
  }

  void _onRoomEvent(lk.RoomEvent event) {
    final room = _room;
    if (room == null) return;
    final detail = switch (event) {
      lk.ParticipantConnectionQualityUpdatedEvent() =>
        ' (qualité ${event.connectionQuality.name}, pair '
        '${event.participant.identity})',
      lk.TrackE2EEStateEvent() =>
        ' (déchiffrement pair ${event.participant.identity} : '
        '${event.state.name})',
      _ => '',
    };
    Logs().w('[RTC] event LiveKit: ${event.runtimeType}$detail');
    if (event is lk.ParticipantConnectedEvent) {
      unawaited(_flushPendingRemoteKeys());
    }
    if (event is lk.TrackSubscribedEvent) {
      _publishTracks();
      if (event.track is lk.VideoTrack || event.track is lk.AudioTrack) {
        _remoteMediaSeen = true;
        _remote.add(RtcRemoteEvent.mediaReady);
      }
    } else if (event is lk.TrackUnsubscribedEvent) {
      _publishTracks();
    } else if (event is lk.ParticipantDisconnectedEvent) {
      if (room.remoteParticipants.isEmpty) {
        _remote.add(RtcRemoteEvent.peerLeft);
      }
    }
  }

  @override
  Future<void> startMedia({required bool audio, required bool video}) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    if (audio) {
      await local.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const lk.AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        ),
      );
    }
    if (video) {
      await local.setCameraEnabled(
        true,
        cameraCaptureOptions: const lk.CameraCaptureOptions(
          cameraPosition: lk.CameraPosition.front,
        ),
      );
    }
    _publishTracks();
  }

  @override
  Future<void> publish() async {
    // La publication des pistes se fait par setMicrophone/CameraEnabled
    // (LiveKit publie à l'activation) : rien de séparé à faire ici.
  }

  @override
  Future<void> setAudioMuted(bool muted) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    for (final pub in local.audioTrackPublications) {
      if (muted) {
        await pub.mute(stopOnMute: false);
      } else {
        await pub.unmute(stopOnMute: false);
      }
    }
  }

  @override
  Future<void> setCameraMuted(bool muted) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    for (final pub in local.videoTrackPublications) {
      if (muted) {
        await pub.mute(stopOnMute: false);
      } else {
        await pub.unmute(stopOnMute: false);
      }
    }
  }

  @override
  Future<void> flipCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final track = local.videoTrackPublications.isNotEmpty
        ? local.videoTrackPublications.first.track
        : null;
    if (track == null) return;
    await rtc.Helper.switchCamera(track.mediaStreamTrack);
    _publishTracks();
  }

  void _publishTracks() {
    final room = _room;
    if (room == null) return;
    lk.VideoTrack? remoteVideo;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t is lk.VideoTrack) {
          remoteVideo = t;
          break;
        }
      }
      if (remoteVideo != null) break;
    }
    lk.VideoTrack? localVideo;
    for (final pub in room.localParticipant?.videoTrackPublications ?? []) {
      final t = pub.track;
      if (t is lk.VideoTrack) {
        localVideo = t;
        break;
      }
    }
    _current = LiveKitTracks(remoteVideo: remoteVideo, localVideo: localVideo);
    _tracks.add(_current);
  }

  @override
  Future<void> dispose() async {
    _statsTimer?.cancel();
    _pendingRemoteKeys.clear();
    _keyProvider = null;
    await _eventCancel?.call();
    _eventCancel = null;
    final room = _room;
    _room = null;
    await room?.disconnect();
    await _remote.close();
    await _tracks.close();
  }
}

/// Piste vidéo à l'écran (distante et/ou locale), émise à chaque changement.
class LiveKitTracks {
  final lk.VideoTrack? remoteVideo;
  final lk.VideoTrack? localVideo;

  const LiveKitTracks({this.remoteVideo, this.localVideo});
}
