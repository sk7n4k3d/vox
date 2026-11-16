import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the bundled call ringtone (`assets/sounds/phone.ogg`) through the
/// Android ringtone stream so the volume follows the phone-call slider
/// instead of the (much quieter) media or notification streams. Loops
/// until [stopRingingTone] is called.
class UserMediaManager {
  factory UserMediaManager() => _instance;
  UserMediaManager._internal();
  static final UserMediaManager _instance = UserMediaManager._internal();

  AudioPlayer? _player;

  /// Incrémenté à chaque stopRingingTone() : permet à _startRingingToneAsync
  /// d'annuler la sonnerie si un stop est arrivé PENDANT la config audio
  /// (avant que le player n'existe — sinon le ringtone démarre « après coup »
  /// et boucle sans fin, audit ultracode #13).
  int _generation = 0;

  /// Non-blocking: fires the ringtone setup on the background queue so the
  /// caller (VoIP.onCallInvite) can immediately move on to handleNewCall
  /// and render the incoming-call overlay without waiting for audio_session
  /// to finish configuring (which can take 500-2000ms on cold start).
  Future<void> startRingingTone() async {
    unawaited(_startRingingToneAsync());
  }

  Future<void> _startRingingToneAsync() async {
    await stopRingingTone();
    // Capturé APRÈS le stop initial pour ne pas s'auto-invalider.
    final generation = _generation;
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.sonification,
            usage: AndroidAudioUsage.notificationRingtone,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
          androidWillPauseWhenDucked: false,
        ),
      );
      await session.setActive(true);
    } catch (_) {
      // Audio session config can fail on some OEMs; fall through to a
      // default player so the user still hears something.
    }
    if (_generation != generation) {
      // Un stopRingingTone() est arrivé pendant la config audio : l'appel est
      // déjà terminé, ne pas démarrer la sonnerie après coup.
      return;
    }
    final player = _player = AudioPlayer();
    try {
      await player.setAsset('assets/sounds/phone.ogg');
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(1.0);
      await player.play();
    } catch (_) {
      // Swallow errors so the call flow continues even if the ringtone
      // can't start (audio focus denied, codec missing, etc.).
    }
  }

  Future<void> stopRingingTone() async {
    _generation++;
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (_) {}
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }
}
