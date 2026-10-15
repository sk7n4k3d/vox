import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Type wire des messages de clés média (matrix-rust-rtc `wire.rs`, 15/10) :
/// Olm-chiffré, envoyé device par device aux membres de la session.
const rtcEncryptionKeyEventType = 'org.matrix.msc4143.rtc.encryption_key';

/// Type legacy (generations Element Call / Element X Sticky2025) — c'est
/// celui que le client de Noemie emploie reellement (terrain 15/10 18:42).
const rtcLegacyKeyEventType = 'io.element.call.encryption_keys';

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

  /// Type sous lequel NOUS envoyons : le dialecte du terrain (legacy).
  static const keyEventType = rtcLegacyKeyEventType;

  /// Notre clé, encodée latin1 pour le KeyProvider LiveKit.
  String get ownKeyLatin1 => latin1.decode(_keyBytes);
  int get ownIndex => 0;

  /// Contenu à envoyer, DANS LE DIALECTE DU PAIR : le rust Sticky2025
  /// (Element X 2025, terrain 15/10 18:42) ne lit que la forme legacy
  /// `{room_id, device_id, keys}` ; le core rust accepte les deux longueurs
  /// de clé (16 chez lui, 32 chez MSC4143), rien ne convertit.
  Map<String, Object?> buildKeyMessage() => {
    'room_id': roomId,
    'device_id': deviceId,
    'keys': {'index': ownIndex, 'key': base64Encode(_keyBytes)},
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
  /// Types acceptés en réception : le nom moderne et le nom legacy — un event
  /// to-device n'a qu'un type, la génération de l'émetteur décide (rust
  /// compat/sticky_2025.rs, table ligne 23).
  static const parseEventTypes = [
    rtcEncryptionKeyEventType,
    rtcLegacyKeyEventType,
  ];

  /// Parse indifféremment MSC4143 (`media_key`) et legacy (`keys`) — les deux
  /// générations de clients coexistent sur le réseau ce soir. Défensif comme
  /// le reste : rien d'exploitable ici ne doit pouvoir lever.
  static RtcInboundKey? parse(
    Map<String, Object?> content, {
    required String roomId,
    required String senderUserId,
    String? senderDeviceId,
  }) {
    if (senderDeviceId == null || senderDeviceId.isEmpty) return null;
    if (content['room_id'] != roomId) return null;
    final Object? rawKey;
    final Object? rawIndex;
    final String memberId;
    final mediaKey = content['media_key'];
    if (mediaKey is Map) {
      if (content['format'] != 0) return null;
      rawKey = mediaKey['key'];
      rawIndex = mediaKey['index'];
      memberId = '$senderUserId:$senderDeviceId';
    } else {
      final legacy = _pickHighestKey(content['keys']);
      if (legacy == null) return null;
      rawKey = legacy['key'];
      rawIndex = legacy['index'];
      // member.id quand le dialecte le porte ; sinon l identité est fixée par
      // le device authentifié Olm, jamais par ce que le contenu affirme.
      memberId = '$senderUserId:$senderDeviceId';
    }
    if (rawKey is! String || rawIndex is! int) return null;
    late final Uint8List bytes;
    try {
      bytes = base64Decode(rawKey);
    } on FormatException {
      return null;
    }
    // 16 octets pour la génération legacy, 32 pour MSC4143 ; les deux
    // arrivent telles quelles au HKDF LiveKit (source rust : agree on bytes).
    if (bytes.length != 16 && bytes.length != 32) return null;
    if (rawIndex < 0 || rawIndex > 255) return null;
    return RtcInboundKey(memberId, latin1.decode(bytes), rawIndex);
  }

  /// `keys` legacy : objet unique (2025) ou tableau (pré-sticky) — c'est le
  /// plus haut index qui gagne, règle recopiée de `parse_key_message` rust.
  static Map<Object?, Object?>? _pickHighestKey(Object? keys) {
    if (keys is Map && keys is! List) {
      return keys.containsKey('key') ? keys.cast<Object?, Object?>() : null;
    }
    if (keys is! List) return null;
    Map<Object?, Object?>? best;
    var bestIndex = -1;
    for (final entry in keys.whereType<Map<Object?, Object?>>()) {
      if (entry['key'] is! String) continue;
      final index = entry['index'];
      final i = index is int ? index : -1;
      if (i > bestIndex) {
        best = entry;
        bestIndex = i;
      }
    }
    return best;
  }

  static Uint8List _newKey() {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  }
}
