/// Source d'un événement poussé au webhook.
enum WebhookSource { sms, mms, matrix, call }

/// Sens webhook d'un appel du journal Android : **seul un appel sortant** compte
/// comme réponse. Un entrant, un manqué ou un rejeté reste `in`.
bool callIsOutgoing(int type) => type == 2;

/// Date de début d'un enregistrement d'appel, d'après son nom
/// `CallRecord_20261006-121813_<numéro>.m4a` (heure locale de l'appareil).
/// Null si le nom ne suit pas le schéma.
DateTime? callRecordingStarted(String name) {
  final m = RegExp(r'CallRecord_(\d{8})-(\d{6})_').firstMatch(name);
  if (m == null) return null;
  final d = m.group(1)!;
  final t = m.group(2)!;
  try {
    return DateTime(
      int.parse(d.substring(0, 4)),
      int.parse(d.substring(4, 6)),
      int.parse(d.substring(6, 8)),
      int.parse(t.substring(0, 2)),
      int.parse(t.substring(2, 4)),
      int.parse(t.substring(4, 6)),
    );
  } catch (_) {
    return null;
  }
}

/// Numéro porté par le nom d'un enregistrement d'appel (forme nationale ou
/// internationale selon l'appel), ou null.
String? callRecordingNumber(String name) {
  final m = RegExp(r'CallRecord_\d{8}-\d{6}_(.+)\.m4a$').firstMatch(name);
  final raw = m?.group(1);
  return (raw == null || raw.isEmpty) ? null : raw;
}

/// Libellé lisible d'un appel (corps de l'événement). [durationSeconds] = 0 pour
/// un appel manqué/inexistant.
String callLabel(int type, int durationSeconds) {
  final kind = switch (type) {
    1 => 'Appel entrant',
    2 => 'Appel sortant',
    3 => 'Appel manqué',
    4 => 'Message vocal',
    5 => 'Appel rejeté',
    6 => 'Appel bloqué',
    7 => 'Appel pris ailleurs',
    _ => 'Appel',
  };
  if (durationSeconds <= 0) return kind;
  final minutes = durationSeconds ~/ 60;
  final seconds = durationSeconds % 60;
  return minutes > 0 ? '$kind · $minutes min $seconds s' : '$kind · $seconds s';
}

/// Plafond d'un média poussé au webhook : 16 Mo de binaire (~21,3 Mo une fois
/// encodé en base64, d'où le `client_max_body_size 32m` côté Hermes). Au-delà,
/// seules les métadonnées partent, avec un [WebhookMedia.reason].
const int maxWebhookMediaBytes = 16 * 1024 * 1024;

/// Une pièce jointe. Les octets voyagent en base64 dans [dataB64] ; au-delà du
/// plafond (ou si la lecture échoue) ils sont remplacés par [reason] et Hermes
/// n'archive que la métadonnée.
class WebhookMedia {
  const WebhookMedia({
    required this.mimeType,
    this.fileName,
    required this.size,
    this.dataB64,
    this.reason,
  });

  final String mimeType;
  final String? fileName;
  final int size;
  final String? dataB64;
  final String? reason;

  bool get skipped => dataB64 == null;

  Map<String, Object?> toJson() => <String, Object?>{
        'mime': mimeType,
        'filename': fileName,
        'size': size,
        if (dataB64 != null) 'data_b64': dataB64,
        if (reason != null) 'reason': reason,
      };
}

/// Un message à pousser au webhook.
///
/// Pur : aucune I/O ici, la construction du JSON est donc testable seule. Le
/// contrat de forme est libre côté Hermes — c'est le template `prompt` de la
/// route `platforms.webhook.extra.routes` qui lit ces champs.
class WebhookEvent {
  const WebhookEvent({
    required this.source,
    required this.eventId,
    required this.outgoing,
    required this.timestamp,
    required this.sender,
    this.senderName,
    this.body,
    this.hideBody = false,
    this.threadId,
    this.roomId,
    this.roomName,
    this.media = const <WebhookMedia>[],
  });

  final WebhookSource source;
  final String eventId;
  final bool outgoing;
  final DateTime timestamp;

  /// Numéro de téléphone (SMS/MMS) ou identifiant Matrix (`@user:serveur`).
  final String sender;

  /// Nom du contact résolu, quand on en a un.
  final String? senderName;

  /// Texte du message. Omis quand [hideBody] est vrai (« cache conversation »).
  final String? body;

  /// Ne pas transmettre le contenu : seules les métadonnées partent.
  final bool hideBody;

  /// Fil SMS/MMS.
  final String? threadId;

  /// Room Matrix (id + nom d'affichage).
  final String? roomId;
  final String? roomName;

  final List<WebhookMedia> media;

  Map<String, Object?> toJson({bool? hideBody}) {
    final hide = hideBody ?? this.hideBody;
    final utc = timestamp.toUtc();
    return <String, Object?>{
      'source': source.name,
      'event_id': eventId,
      'direction': outgoing ? 'out' : 'in',
      'timestamp': utc.toIso8601String(),
      'timestamp_ms': utc.millisecondsSinceEpoch,
      'sender': sender,
      if (senderName != null) 'sender_name': senderName,
      if (threadId != null) 'thread_id': threadId,
      if (roomId != null) 'room_id': roomId,
      if (roomName != null) 'room_name': roomName,
      'body': hide ? null : body,
      'body_hidden': hide,
      'media': media.map((m) => m.toJson()).toList(),
    };
  }
}

/// Règle de filtrage, commune aux SMS/MMS et aux rooms Matrix.
///
/// Une conversation part si :
/// - [all] est vrai (l'interrupteur « tout envoyer » court-circuite tout), ou
/// - elle est cochée ([allowed]), ou
/// - elle n'a jamais été décidée et [newDefault] est vrai (nouveau contact ou
///   nouveau salon envoyé par défaut).
///
/// Une conversation explicitement décochée ([excluded]) ne part pas, même si
/// [newDefault] est vrai : sans cela le défaut la renverrait sans fin.
bool _isAllowed(
  Set<String> allowed,
  String id, {
  required bool all,
  required bool newDefault,
  required Set<String> excluded,
}) {
  if (all) return true;
  if (allowed.contains(id)) return true;
  if (excluded.contains(id)) return false;
  return newDefault;
}

/// Une room Matrix part si elle est cochée, si elle est nouvelle et que le
/// défaut est actif, ou si [all].
bool isRoomAllowed(
  Set<String> allowedRooms,
  String roomId, {
  bool all = false,
  bool newDefault = false,
  Set<String> excluded = const <String>{},
}) =>
    _isAllowed(
      allowedRooms,
      roomId,
      all: all,
      newDefault: newDefault,
      excluded: excluded,
    );

/// Un fil SMS/MMS suit exactement la même règle que les rooms Matrix.
bool isSmsThreadAllowed(
  Set<String> allowedThreads,
  String threadId, {
  bool all = false,
  bool newDefault = false,
  Set<String> excluded = const <String>{},
}) =>
    _isAllowed(
      allowedThreads,
      threadId,
      all: all,
      newDefault: newDefault,
      excluded: excluded,
    );

/// Comparaison de numéros tolérante : le même contact s'écrit `+33 6 50 73 02 02`,
/// `+33650730202`, `06.50.73.02.02` ou `0769558524` selon la source.
///
/// Le **journal d'appels** stocke souvent la forme nationale (`07 69 55 85 24`)
/// là où les SMS stockent l'international (`+33769558524`) : sans replier l'un
/// sur l'autre, un appel ne retombait pas dans le fil du SMS et ne comptait donc
/// jamais comme réponse. On assume ici le plan de numérotation français (le
/// téléphone est en France) : `0XXXXXXXXX` → `+33XXXXXXXXX`.
String normalizeSmsAddress(String raw) {
  final s = raw.replaceAll(RegExp(r'[\s\-.()]'), '');
  if (s.isEmpty) return s;
  if (s.startsWith('00')) return '+${s.substring(2)}';
  if (!s.startsWith('+') && s.startsWith('0') && s.length == 10) {
    return '+33${s.substring(1)}';
  }
  return s;
}

/// Fil (threadId) d'un numéro, à partir des conversations du pont SMS. Pur :
/// c'est la règle de résolution utilisée pour les envois sortants, dont le
/// callback ne porte que le numéro. Null si aucune conversation ne correspond.
String? smsThreadIdForAddress(
  Iterable<({String threadId, String address})> conversations,
  String address,
) {
  final target = normalizeSmsAddress(address);
  for (final conversation in conversations) {
    if (normalizeSmsAddress(conversation.address) == target) {
      return conversation.threadId;
    }
  }
  return null;
}
