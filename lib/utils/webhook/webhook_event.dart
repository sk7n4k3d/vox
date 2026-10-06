/// Source d'un événement poussé au webhook.
enum WebhookSource { sms, mms, matrix }

/// Métadonnée d'une pièce jointe. Volontairement **sans octets** : v1 n'envoie
/// pas les images, seulement de quoi les identifier (type, nom, taille).
class WebhookMedia {
  const WebhookMedia({
    required this.mimeType,
    this.fileName,
    required this.size,
  });

  final String mimeType;
  final String? fileName;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
        'mime': mimeType,
        'filename': fileName,
        'size': size,
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

/// Comparaison de numéros tolérante : le même contact peut s'écrire
/// `+33 6 50 73 02 02`, `+33650730202` ou `06.50.73.02.02` selon la source.
String normalizeSmsAddress(String raw) =>
    raw.replaceAll(RegExp(r'[\s\-.()]'), '');

/// Un envoi sortant ne porte que le numéro : on retrouve le fil dans [threads]
/// (couples threadId + adresse issus du pont SMS) puis on applique la règle.
bool isSmsAddressAllowed(
  Iterable<({String threadId, String address})> threads,
  Set<String> allowedThreads,
  String address, {
  bool all = false,
  bool newDefault = false,
  Set<String> excluded = const <String>{},
}) {
  if (all) return true;
  final target = normalizeSmsAddress(address);
  for (final thread in threads) {
    if (normalizeSmsAddress(thread.address) != target) continue;
    if (allowedThreads.contains(thread.threadId)) return true;
    if (excluded.contains(thread.threadId)) return false;
  }
  return newDefault;
}
