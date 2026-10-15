import 'dart:convert';
import 'dart:math';

import 'rtc_sfu_client.dart';

/// Type d'event de présence MSC3401 publié par Element (vérifié dans les logs
/// VOX du 15/10).
const rtcMembershipEventType = 'org.matrix.msc3401.call.member';

/// Format sticky MSC4143 — toléré en lecture (ignoré proprement), non produit.
const rtcStickyMembershipEventType = 'org.matrix.msc4143.rtc.member';

/// Durée de vie par défaut quand `expires` est absent (alignée js-sdk : 4 h).
const defaultMembershipExpiryMs = 1000 * 60 * 60 * 4;

/// Une session (user+device) présente dans un appel.
class RtcSessionMembership {
  final String userId;
  final String deviceId;

  /// Chaîne vide pour l'appel implicite de DM (cas 1:1).
  final String callId;
  final String application;

  /// DURÉE relative en ms à partir de [originServerTs] (pas un timestamp !).
  final int expiresMs;
  final String membershipId;
  final DateTime originServerTs;
  final List<RtcFocus> fociPreferred;

  const RtcSessionMembership({
    required this.userId,
    required this.deviceId,
    required this.callId,
    required this.application,
    required this.expiresMs,
    required this.membershipId,
    required this.originServerTs,
    required this.fociPreferred,
  });

  bool isExpiredAt(DateTime now) =>
      !now.isBefore(
        originServerTs.add(Duration(milliseconds: expiresMs)),
      );

  bool get isImplicitRoomCall =>
      callId.isEmpty && application == 'm.call';
}

/// Extrait les sessions d'un event de membership, formes `{"calls":[…]}` et
/// plate. Tout contenu invalide ou incomplet → liste vide : cet event peut
/// venir de n'importe qui dans la room, il ne doit JAMAIS crasher l'app.
List<RtcSessionMembership> parseMembershipEvent(
  Map<String, Object?> content,
  String sender,
  DateTime originServerTs,
) {
  final rawCalls = content['calls'];
  final List<Object?> entries;
  if (rawCalls is List) {
    entries = rawCalls;
  } else if (rawCalls == null &&
      content['application'] is String &&
      content['device_id'] is String) {
    entries = [content];
  } else {
    return const [];
  }
  return entries
      .whereType<Map<Object?, Object?>>()
      .map((e) => _memberFromEntry(e, sender, originServerTs))
      .nonNulls
      .toList();
}

RtcSessionMembership? _memberFromEntry(
  Map<Object?, Object?> entry,
  String userId,
  DateTime originServerTs,
) {
  final application = entry['application'];
  final deviceId = entry['device_id'];
  if (application is! String || deviceId is! String) return null;
  final expires = entry['expires'];
  return RtcSessionMembership(
    userId: userId,
    deviceId: deviceId,
    callId: entry['call_id'] is String ? entry['call_id']! as String : '',
    application: application,
    expiresMs: expires is int && expires > 0
        ? expires
        : defaultMembershipExpiryMs,
    membershipId: entry['membershipID'] is String
        ? entry['membershipID']! as String
        : '',
    originServerTs: originServerTs,
    fociPreferred: _livekitFoci(entry['foci_preferred']),
  );
}

List<RtcFocus> _livekitFoci(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map<Object?, Object?>>().map((f) {
    return RtcFocus(
      type: f['type'] as String? ?? '',
      livekitServiceUrl: f['livekit_service_url'] as String? ?? '',
    );
  }).where((f) => f.type == 'livekit' && f.livekitServiceUrl.isNotEmpty)
      .toList();
}

/// Contenu à publier pour NOTRE session ; la forme tableau `calls` est celle
/// qu'Element lit (calibrage M1 sur l'event réel reçu — spec §3.1).
Map<String, Object?> buildMembershipContent(RtcSessionMembership m) => {
  'calls': [
    {
      'application': m.application,
      'scope': 'm.room',
      'call_id': m.callId,
      'device_id': m.deviceId,
      'expires': m.expiresMs,
      'membershipID': _newMembershipId(),
      'foci_preferred': m.fociPreferred
          .map(
            (f) => {
              'type': f.type,
              'livekit_service_url': f.livekitServiceUrl,
            },
          )
          .toList(),
    },
  ],
};

/// Cache-buster : sans changement de contenu, Synapse ne renvoie pas l'event
/// et les pairs croient notre présence expirée.
String _newMembershipId() {
  final bytes = List<int>.generate(12, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
