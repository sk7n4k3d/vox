import 'dart:convert' show jsonEncode;
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Sondes de performance VoxOne — instrumentation de profiling, inactive en
/// release : `kReleaseMode` est une constante de compilation, chaque lecture
/// et l'enregistrement des extensions sont éliminés par l'arbre d'expression.
///
/// Trois interrupteurs, lisibles et modifiables en debug/profile via le
/// service protocol (`ext.vox.perf.*`), pour isoler la contribution de chaque
/// sous-système pendant une mesure sur appareil (flip depuis la liste, puis
/// re-entrée dans la conversation pour que le drapeau soit lu au build) :
///  - [emojiAnim]      : les emojis Lottie visibles (réactions + jumbo)
///                       s'animent.
///  - [screenBackdrop] : le fond animé derrière la timeline (aurora/starlink).
///  - [glassBlur]      : les BackdropFilter de la conversation (composer,
///                       séparateurs de date).
class VoxPerfProbe {
  static bool get enabled => !kReleaseMode;

  static bool emojiAnim = true;
  static bool screenBackdrop = true;
  static bool glassBlur = true;

  static bool _registered = false;

  static void ensureRegistered() {
    if (!enabled || _registered) return;
    _registered = true;
    _registerBool(
      'ext.vox.perf.emojiAnim',
      () => emojiAnim,
      (v) => emojiAnim = v,
    );
    _registerBool(
      'ext.vox.perf.screenBackdrop',
      () => screenBackdrop,
      (v) => screenBackdrop = v,
    );
    _registerBool(
      'ext.vox.perf.glassBlur',
      () => glassBlur,
      (v) => glassBlur = v,
    );
  }

  static void _registerBool(
    String method,
    bool Function() get,
    void Function(bool) set,
  ) {
    developer.registerExtension(method, (m, params) async {
      final raw = params['set'];
      if (raw == 'true') set(true);
      if (raw == 'false') set(false);
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'name': m, 'value': get()}),
      );
    });
  }

  /// Trace de navigation pour vérifier l'état de l'app depuis logcat sans
  /// capture d'écran (jamais compilé en release).
  static void logRoom(String roomId) {
    if (!enabled) return;
    // ignore: avoid_print
    print('[VOX-PERF] room open: $roomId');
  }
}
