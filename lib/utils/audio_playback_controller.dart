import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:matrix/matrix.dart';

/// Single source of truth for the currently playing voice message.
///
/// Tracks which event is being played (or has been played and is still
/// loaded), the underlying [AudioPlayer], and metadata required by the
/// sticky [MiniAudioPlayer] (sender display name, avatar, room).
///
/// The controller does NOT own the [AudioPlayer] lifecycle: the player is
/// created and disposed by the bubble widget so that the existing speed
/// playback integration ([playbackSpeedController.attachPlayer]) keeps
/// working. The controller only mirrors the state for the UI.
class AudioPlaybackController extends ChangeNotifier {
  AudioPlayer? _player;
  String? _eventId;
  String? _roomId;
  String? _senderId;
  String? _senderDisplayName;
  Uri? _senderAvatarUrl;
  bool _sourceVisible = true;

  StreamSubscription<PlayerState>? _playerStateSub;

  AudioPlayer? get player => _player;
  String? get eventId => _eventId;
  String? get roomId => _roomId;
  String? get senderId => _senderId;
  String? get senderDisplayName => _senderDisplayName;
  Uri? get senderAvatarUrl => _senderAvatarUrl;
  bool get sourceVisible => _sourceVisible;

  bool get hasActiveTrack => _eventId != null;

  /// Publish a new track. Replaces any previous track. The caller is
  /// responsible for actually starting playback on [player]; this method
  /// only records the metadata and subscribes to player state changes so
  /// the UI can rebuild.
  ///
  /// [player] is nullable so unit tests can drive the controller without
  /// instantiating a real [AudioPlayer] (which requires platform bindings).
  void play({
    required Event event,
    required Room room,
    AudioPlayer? player,
  }) {
    _detachPlayerStateSub();
    _player = player;
    _eventId = event.eventId;
    _roomId = room.id;
    final sender = event.senderFromMemoryOrFallback;
    _senderId = sender.id;
    _senderDisplayName = sender.calcDisplayname();
    _senderAvatarUrl = sender.avatarUrl;
    // New track => assume source bubble visible until told otherwise.
    _sourceVisible = true;
    if (player != null) {
      _playerStateSub = player.playerStateStream.listen(
        (_) => notifyListeners(),
        onError: (_) {},
      );
    }
    notifyListeners();
  }

  /// Pause the current track (no-op when nothing is playing).
  Future<void> pause() async {
    final p = _player;
    if (p == null) return;
    await p.pause();
    notifyListeners();
  }

  /// Resume / start playback (no-op when nothing is loaded).
  Future<void> resume() async {
    final p = _player;
    if (p == null) return;
    await p.play();
    notifyListeners();
  }

  /// Stop and clear the current track. Does NOT dispose the [AudioPlayer]:
  /// the bubble widget owns the lifecycle.
  void stop() {
    _detachPlayerStateSub();
    _player = null;
    _eventId = null;
    _roomId = null;
    _senderId = null;
    _senderDisplayName = null;
    _senderAvatarUrl = null;
    _sourceVisible = true;
    notifyListeners();
  }

  /// Seek the current player. Silently ignored when nothing is loaded.
  Future<void> seek(Duration position) async {
    final p = _player;
    if (p == null) return;
    await p.seek(position);
  }

  /// Report the visibility of the source bubble. Only mutates state when
  /// [forEventId] matches the currently active track to avoid stale
  /// visibility reports clobbering the controller after the user moved on.
  void setSourceVisible(bool visible, String forEventId) {
    if (_eventId == null || _eventId != forEventId) return;
    if (_sourceVisible == visible) return;
    _sourceVisible = visible;
    notifyListeners();
  }

  void _detachPlayerStateSub() {
    _playerStateSub?.cancel();
    _playerStateSub = null;
  }

  @override
  void dispose() {
    _detachPlayerStateSub();
    super.dispose();
  }
}
