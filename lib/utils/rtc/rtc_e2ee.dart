import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Type wire des messages de clés média (matrix-rust-rtc `wire.rs`, 15/10) :
/// Olm-chiffré, envoyé device par device aux membres de la session.
const rtcEncryptionKeyEventType = 'org.matrix.msc4143.rtc.encryption_key';

/// Clé média entrante validée, prête pour le KeyProvider LiveKit.
class RtcInboundKey {
  /// `member_id` de l'expéditeur (`user:device`, comme la membershipID
  /// legacy) ; sert à retrouver l'identité LiveKit du pair.
  final String memberId;

  /// 32 octets brute encodés latin1, forme attendue par BaseKeyProvider.
  final String keyLatin1;
  final int index;

  const RtcInboundKey(this.memberId, this.keyLatin1, this.index);
}

/// Envoi du contenu brut vers un device précis (chiffrement Olm géré par le
/// port ; le device destinataire est celui qui a publié la membership).
typedef RtcKeySender =
    Future<void> Function(String userId, String deviceId, Object? content);

/// Une direction de la conversation e2ee : notre clé + le parse/validation des
/// clés reçues, au schéma exact de matrix-rust-rtc (media_key.index/key,
/// format 0 = base64 non paddé, room_id, member_id).
class RtcE2ee {
  RtcE2ee({
    required this.roomId,
    required this.userId,
    required this.deviceId,
    RtcKeySender? sendKey,
  }) : _sendKey = sendKey,
       _keyBytes = _newKey();

  final String roomId;
  final String userId;
  final String deviceId;
  final RtcKeySender? _sendKey;
  final Uint8List _keyBytes;
  final Set<String> _sharedWith = {};

  String get memberId => '$userId:$deviceId';

  /// Notre clé, encodée latin1 pour le KeyProvider LiveKit.
  String get ownKeyLatin1 => latin1.decode(_keyBytes);
  int get ownIndex => 0;

  /// Contenu MSC4143 à envoyer à un pair (member_id = NOTRE session ; le
  /// receveur vérifie qu'il nomme bien notre event de membership).
  Map<String, Object?> buildKeyMessage() => {
    'room_id': roomId,
    'member_id': memberId,
    'media_key': {'index': ownIndex, 'key': base64Encode(_keyBytes)},
    'format': 0,
  };

  /// Partage notre clé avec une session (user+device tirés de sa membership),
  /// une seule fois par device.
  Future<void> shareWith(String peerUserId, String peerDeviceId) async {
    final sender = _sendKey;
    if (sender == null) return;
    if (peerDeviceId.isEmpty || !_sharedWith.add(peerDeviceId)) return;
    await sender(peerUserId, peerDeviceId, buildKeyMessage());
  }

  /// Parse une clé reçue. Défensif comme le reste du module : contenu
  /// inattendu, format inconnu ou room_id étranger -> null, jamais une
  /// exception. `senderDeviceId` vient de la session Olm (device authentifié)
  /// ; sans lui on ne peut pas prouver l'origine — MSC4143 jette.
  static RtcInboundKey? parse(
    Map<String, Object?> content, {
    required String roomId,
    required String senderUserId,
    String? senderDeviceId,
  }) {
    if (senderDeviceId == null || senderDeviceId.isEmpty) return null;
    if (content['room_id'] != roomId) return null;
    if (content['format'] != 0) return null;
    final mediaKey = content['media_key'];
    if (mediaKey is! Map) return null;
    final key = mediaKey['key'];
    final index = mediaKey['index'];
    if (key is! String || index is! int) return null;
    late final Uint8List bytes;
    try {
      bytes = base64Decode(key);
    } on FormatException {
      return null;
    }
    if (bytes.length != 32) return null;
    return RtcInboundKey(
      '$senderUserId:$senderDeviceId',
      latin1.decode(bytes),
      index,
    );
  }

  static Uint8List _newKey() {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  }
}
