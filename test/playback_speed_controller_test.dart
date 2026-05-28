import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/playback_speed_controller.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  tearDown(() async {
    await AppSettings.reset(loadWebConfigFile: false);
  });

  group('PlaybackSpeedController', () {
    test('default value is 1.0', () {
      final controller = PlaybackSpeedController();
      expect(controller.value, 1.0);
    });

    test('cycle wraparound 1.0 -> 1.5 -> 2.0 -> 1.0', () async {
      final controller = PlaybackSpeedController();
      expect(controller.value, 1.0);
      await controller.cycle();
      expect(controller.value, 1.5);
      await controller.cycle();
      expect(controller.value, 2.0);
      await controller.cycle();
      expect(controller.value, 1.0);
    });

    test('persist between instances', () async {
      final controller = PlaybackSpeedController();
      await controller.setSpeed(1.75);
      expect(controller.value, 1.75);
      final next = PlaybackSpeedController();
      expect(next.value, 1.75);
    });

    test('clamp 3.0 -> 2.0', () async {
      final controller = PlaybackSpeedController();
      await controller.setSpeed(3.0);
      expect(controller.value, 2.0);
    });

    test('clamp 0.1 -> 0.5', () async {
      final controller = PlaybackSpeedController();
      await controller.setSpeed(0.1);
      expect(controller.value, 0.5);
    });

    test('corrupted persisted value falls back within clamp range', () async {
      SharedPreferences.setMockInitialValues({
        AppSettings.audioPlaybackSpeed.key: 999.0,
      });
      await AppSettings.reset(loadWebConfigFile: false);
      await AppSettings.audioPlaybackSpeed.setItem(999.0);
      final controller = PlaybackSpeedController();
      expect(controller.value, 2.0);
    });

    test('notifies listeners on setSpeed', () async {
      final controller = PlaybackSpeedController();
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.setSpeed(1.5);
      expect(notified, 1);
      await controller.setSpeed(1.5);
      expect(notified, 1, reason: 'no notify when value unchanged');
      await controller.setSpeed(2.0);
      expect(notified, 2);
    });

    test('cycle from arbitrary intermediate speed advances to next preset',
        () async {
      final controller = PlaybackSpeedController();
      await controller.setSpeed(1.25);
      await controller.cycle();
      // Depuis 1.25 (hors cycle), on avance au premier cyclePreset strictement
      // supérieur, soit 1.5 — pas un saut au max.
      expect(controller.value, 1.5);
    });

    test('cycle from intermediate speed above all presets wraps to first',
        () async {
      final controller = PlaybackSpeedController();
      await controller.setSpeed(1.75);
      await controller.cycle();
      // 1.75 > tous les cyclePresets sauf 2.0 → 2.0 est le suivant.
      expect(controller.value, 2.0);
    });
  });
}
