import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class PlaybackSpeedController extends ChangeNotifier
    implements ValueListenable<double> {
  static const List<double> cyclePresets = [1.0, 1.5, 2.0];
  static const List<double> presets = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];
  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;

  double _speed;
  final Set<AudioPlayer> _attachedPlayers = <AudioPlayer>{};

  PlaybackSpeedController()
    : _speed = AppSettings.audioPlaybackSpeed.value.clamp(minSpeed, maxSpeed);

  @override
  double get value => _speed;

  Future<void> setSpeed(double newSpeed) async {
    final clamped = newSpeed.clamp(minSpeed, maxSpeed);
    if (clamped == _speed) return;
    _speed = clamped;
    unawaited(AppSettings.audioPlaybackSpeed.setItem(clamped));
    for (final player in _attachedPlayers) {
      unawaited(player.setSpeed(clamped));
    }
    notifyListeners();
  }

  Future<void> cycle() async {
    final currentIndex = cyclePresets.indexWhere((s) => s >= _speed);
    final nextIndex = currentIndex < 0 || currentIndex >= cyclePresets.length - 1
        ? 0
        : currentIndex + 1;
    await setSpeed(cyclePresets[nextIndex]);
  }

  VoidCallback attachPlayer(AudioPlayer player) {
    _attachedPlayers.add(player);
    unawaited(player.setSpeed(_speed));
    return () => _attachedPlayers.remove(player);
  }
}

final playbackSpeedController = PlaybackSpeedController();
