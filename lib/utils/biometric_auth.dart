import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Thin, defensive wrapper around [LocalAuthentication] for VOX's biometric
/// locks (whole-app lock + per-conversation lock). Every call fails closed:
/// when biometrics are unavailable or an error occurs, [authenticate] returns
/// false so a caller never grants access by accident.
class BiometricAuth {
  BiometricAuth._();
  static final BiometricAuth instance = BiometricAuth._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// True when the device can do biometric (or device-credential) auth.
  Future<bool> get isAvailable async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && (canCheck || await _hasEnrolled());
    } on PlatformException {
      return false;
    }
  }

  Future<bool> _hasEnrolled() async {
    try {
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// Prompts for biometric (fingerprint/face), falling back to device PIN/
  /// pattern. Returns true only on a confirmed successful auth.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // local_auth 3.x: options are named params on authenticate() directly.
        biometricOnly: false, // allow device credential (PIN/pattern) fallback
        persistAcrossBackgrounding: true, // ex-stickyAuth: survive app pause
      );
    } on PlatformException {
      return false;
    }
  }
}
