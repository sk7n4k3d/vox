import 'rtc_sfu_client.dart';

/// Type d'event de présence MSC3401 publié par Element (vérifié dans les logs
/// VOX du 15/10).
const rtcMembershipEventType = 'org.matrix.msc3401.call.member';

/// Format sticky MSC4143 — toléré en lecture (ignoré proprement), non produit.
const rtcStickyMembershipEventType = 'org.matrix.msc4143.rtc.member';

/// Clé d'état de NOTRE presence legacy : Element X (matrix-rust-sdk) indexe
/// les sessions sur `_user_device_m.call` (le prefixe `_` est la convention
/// des rooms < 3757/3779, cf. js-sdk makeMembershipStateKey). Preuve serveur
/// 15/10 : les events de Noemie portent `_@nanagum:matrix.org_VAY14m8QBP_m.call`
/// ; sous cle vide nos events etaient ignores (« evenement non pris en charge »).
String legacyMembershipStateKey(String userId, String deviceId) =>
    '_${userId}_${deviceId}_m.call';

/// Durée de vie par défaut quand `expires` est absent (alignée js-sdk : 4 h).
const defaultMembershipExpiryMs = 1000 * 60 * 60 * 4;

/// Event de sonnerie MSC4075 (notification d'appel). Element X ne fait pas
/// sonner son utilisateur sans cet event : la présence seule ne « convoque »
/// personne (calibrage rust matrix-rust-rtc, source 15/10).
const rtcNotificationEventType = 'org.matrix.msc4075.rtc.notification';

/// Contenu de la sonnerie, miroir EXACT de `build_notification_content` de
/// matrix-rust-rtc (element-hq/matrix-rust-rtc) : les champs sont écrits à la
/// fois dans `application` (forme de la MSC) et au niveau racine (forme que
/// tous les clients déployés lisent réellement).
Map<String, Object?> buildNotificationContent({
  required String senderUserId,
  required String deviceId,
  required String memberEventId,
  required int senderTsMs,
  required String intent,
  int lifetimeMs = 90000,
}) => {
  'application': {
    'type': 'm.call',
    'notification_type': 'ring',
    'sender_ts': senderTsMs,
    'lifetime': lifetimeMs,
    'device_id': deviceId,
    'm.call.intent': intent,
  },
  'notification_type': 'ring',
  'sender_ts': senderTsMs,
  'lifetime': lifetimeMs,
  'm.call.intent': intent,
  'm.text': [
    {'body': 'Session started by $senderUserId'},
  ],
  'm.mentions': {'user_ids': <String>[], 'room': true},
  'm.relates_to': {'rel_type': 'm.reference', 'event_id': memberEventId},
};

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

  /// `m.call.intent` : « audio » ou « video » (Element s'en sert pour router
  /// l'event comme appel — absent chez nous il affichait « événement non
  /// pris en charge », terrain 15/10).
  final String? intent;

  /// `created_ts` (ms epoch) du contenu ; sert de rafraîchissement à chaque
  /// republi (l'event est autrement identique et Synapse le dédoublonne).
  final int? createdTs;

  const RtcSessionMembership({
    required this.userId,
    required this.deviceId,
    required this.callId,
    required this.application,
    required this.expiresMs,
    required this.membershipId,
    required this.originServerTs,
    required this.fociPreferred,
    this.intent,
    this.createdTs,
  });

  bool isExpiredAt(DateTime now) =>
      !now.isBefore(
        originServerTs.add(Duration(milliseconds: expiresMs)),
      );

  bool get isImplicitRoomCall => callId.isEmpty && application == 'm.call';
}

/// Extrait les sessions d'un event de présence, formes plate (Element X,
/// calibrage 15/10) et `{"calls":[…]}` (anciens clients). Tout contenu
/// invalide ou incomplet → liste vide : cet event peut venir de n'importe qui
/// dans la room, il ne doit JAMAIS crasher l'app.
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
  final createdTs = entry['created_ts'];
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
    intent: entry['m.call.intent'] is String
        ? entry['m.call.intent']! as String
        : null,
    createdTs: createdTs is int ? createdTs : null,
  );
}

List<RtcFocus> _livekitFoci(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map<Object?, Object?>>().map((f) {
    return RtcFocus(
      type: f['type'] as String? ?? '',
      livekitServiceUrl: f['livekit_service_url'] as String? ?? '',
      livekitAlias: f['livekit_alias'] is String
          ? f['livekit_alias']! as String
          : null,
    );
  }).where((f) => f.type == 'livekit' && f.livekitServiceUrl.isNotEmpty)
      .toList();
}

/// Contenu à publier pour NOTRE session : la forme PLATE SessionMembershipData
/// exacte publiée par Element X (fixture réelle du 15/10, spec §10). L'ancien
/// tableau `calls[]` n'est plus reconnu par les clients récents.
Map<String, Object?> buildMembershipContent(RtcSessionMembership m) => {
  'application': m.application,
  'call_id': m.callId,
  'device_id': m.deviceId,
  'created_ts': m.createdTs ?? m.originServerTs.millisecondsSinceEpoch,
  'expires': m.expiresMs,
  'foci_preferred': m.fociPreferred
      .map(
        (f) => {
          'type': f.type,
          'livekit_service_url': f.livekitServiceUrl,
          if (f.livekitAlias != null && f.livekitAlias!.isNotEmpty)
            'livekit_alias': f.livekitAlias,
        },
      )
      .toList(),
  'focus_active': {'focus_selection': 'multi_sfu', 'type': 'livekit'},
  'm.call.intent': m.intent ?? 'audio',
  'membershipID': '${m.userId}:${m.deviceId}',
  'scope': 'm.room',
};
