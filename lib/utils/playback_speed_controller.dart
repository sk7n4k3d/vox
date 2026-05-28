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
    final disposed = <AudioPlayer>[];
    for (final player in _attachedPlayers.toList(growable: false)) {
      try {
        unawaited(
          player.setSpeed(clamped).catchError((_) {
            disposed.add(player);
          }),
        );
      } catch (_) {
        disposed.add(player);
      }
    }
    _attachedPlayers.removeAll(disposed);
    notifyListeners();
  }

  Future<void> cycle() async {
    final indexExact = cyclePresets.indexOf(_speed);
    final double next;
    if (indexExact >= 0) {
      // On est pile sur un preset du cycle : on avance au suivant (wrap).
      next = cyclePresets[(indexExact + 1) % cyclePresets.length];
    } else {
      // Vitesse intermédiaire réglée via le bottom-sheet (ex. 1.25) : on avance
      // au premier preset strictement supérieur, sinon on wrap au premier.
      next = cyclePresets.firstWhere(
        (p) => p > _speed,
        orElse: () => cyclePresets.first,
      );
    }
    await setSpeed(next);
  }

  VoidCallback attachPlayer(AudioPlayer player) {
    _attachedPlayers.add(player);
    unawaited(player.setSpeed(_speed).catchError((_) {}));
    return () => _attachedPlayers.remove(player);
  }
}

final playbackSpeedController = PlaybackSpeedController();
