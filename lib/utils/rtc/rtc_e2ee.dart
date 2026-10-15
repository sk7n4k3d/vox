import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Envoi to-device (adapteur `client.sendToDevice(Encrypted)` au task 6).
typedef RtcToDevice =
    Future<void> Function(
      String eventType,
      Map<String, Map<String, Object?>> messagesByUserDevice,
    );

/// Clé des médias LiveKit d'un appel (passkey), partagée via
/// `io.element.call.encryption_keys` — schéma js-sdk, recalibré si M1 observe
/// autre chose (spec §5).
class RtcE2ee {
  RtcE2ee({required this.callId, required RtcToDevice sender})
    : _sender = sender,
      _passkey = _newKey();

  static const encryptionKeysEventType = 'io.element.call.encryption_keys';

  final String callId;
  final RtcToDevice _sender;
  final Uint8List _passkey;
  final StreamController<Uint8List> _onKey =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get onKey => _onKey.stream;

  Uint8List get passkey => _passkey;

  Future<void> shareWithDevice(String userId, String deviceId) async {
    await _sender(encryptionKeysEventType, {
      userId: {
        deviceId: {
          'call_id': callId,
          'keys': [
            {'index': 0, 'key': base64Encode(_passkey)},
          ],
        },
      },
    });
  }

  /// Clés reçues d'un pair ; contenu défensif, jamais d'exception.
  void handleIncomingKeys(Map<String, Object?> content, String fromUserId) {
    if (content['call_id'] != callId) return;
    final keys = content['keys'];
    if (keys is! List) return;
    for (final entry in keys.whereType<Map<Object?, Object?>>()) {
      final key = entry['key'];
      if (key is! String) continue;
      try {
        _onKey.add(base64Decode(key));
      } on FormatException {
        // pas du base64 : contenu invalide, on ignore.
      }
    }
  }

  Future<void> dispose() => _onKey.close();

  static Uint8List _newKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
  }

  @override
  String toString() => 'RtcE2ee(call $callId)';
}
