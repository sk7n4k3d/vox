import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dart side of the native SMS bridge (étape 1). Talks to the Kotlin
/// `SmsBridgePlugin` over the `eu.devlabz.vox/sms` MethodChannel + listens to
/// incoming SMS on the `eu.devlabz.vox/sms_events` EventChannel.
///
/// This is the thin transport layer; the UI / chat-list fusion is built on top
/// in later steps. Kept defensive: every call swallows platform errors and
/// returns a safe default so a missing/denied SMS stack never crashes the app.
class SmsBridge {
  SmsBridge._();
  static final SmsBridge instance = SmsBridge._();

  static const MethodChannel _channel = MethodChannel('eu.devlabz.vox/sms');
  static const EventChannel _events = EventChannel('eu.devlabz.vox/sms_events');

  Stream<SmsIncoming>? _incoming;

  // Archive is local-only: the Telephony provider has no standard "archived"
  // flag for SMS, so VOX keeps the set of archived thread ids in prefs.
  static const String _archiveKey = 'chat.fluffy.sms_archived';
  Set<String> _archived = {};
  bool _archivedLoaded = false;
  final StreamController<void> _archiveChanges =
      StreamController<void>.broadcast();

  Stream<void> get archiveChanges => _archiveChanges.stream;

  Future<void> _ensureArchiveLoaded() async {
    if (_archivedLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _archived = (prefs.getStringList(_archiveKey) ?? const []).toSet();
    _archivedLoaded = true;
  }

  Future<Set<String>> archivedThreadIds() async {
    await _ensureArchiveLoaded();
    return Set.unmodifiable(_archived);
  }

  bool isArchivedSync(String threadId) => _archived.contains(threadId);

  Future<void> setArchived(String threadId, bool archived) async {
    await _ensureArchiveLoaded();
    if (archived) {
      _archived.add(threadId);
    } else {
      _archived.remove(threadId);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_archiveKey, _archived.toList());
    _archiveChanges.add(null);
  }

  /// Raw broadcast of every native event (incoming SMS/MMS + open-conversation
  /// requests from notification taps). Parsed into typed streams below.
  Stream<Map<String, dynamic>> get _rawEvents => _rawEventsStream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .handleError((Object e, StackTrace s) {
        debugPrint('SMS event parse error: $e');
      })
      .asBroadcastStream();
  Stream<Map<String, dynamic>>? _rawEventsStream;

  /// Broadcast stream of incoming SMS/MMS (only fires while VOX is the default
  /// SMS app — that's an Android constraint, not a bug). Excludes
  /// open-conversation events.
  Stream<SmsIncoming> get incoming => _incoming ??= _rawEvents
      .where((m) => m['kind'] != 'open_conversation')
      .map(SmsIncoming.fromMap)
      .asBroadcastStream();

  /// Fires when the user taps an SMS notification (or its Voice action). Carries
  /// the thread/address to open and whether to start voice dictation.
  Stream<SmsOpenRequest> get openRequests => _openRequests ??= _rawEvents
      .where((m) => m['kind'] == 'open_conversation')
      .map(SmsOpenRequest.fromMap)
      .asBroadcastStream();
  Stream<SmsOpenRequest>? _openRequests;

  /// Consumes a pending open-conversation intent captured before Flutter was
  /// listening (cold start from a notification tap). Returns null if none.
  Future<SmsOpenRequest?> takePendingOpenRequest() async {
    try {
      final m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getPendingSmsIntent');
      if (m == null) return null;
      return SmsOpenRequest.fromMap(Map<String, dynamic>.from(m));
    } on PlatformException {
      return null;
    }
  }

  Future<bool> isDefaultSmsApp() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultSmsApp') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Logs [message] through the native layer (Log.i) so it shows up in logcat
  /// even in release builds — Dart's print/developer.log don't reliably reach
  /// logcat in release. Diagnostic helper, safe no-op on failure.
  Future<void> nativeLog(String message) async {
    try {
      await _channel.invokeMethod<void>('nativeLog', {'message': message});
    } catch (_) {}
  }

  /// Launches the system "default SMS app" prompt. Returns true if the intent
  /// was launched (NOT that the user accepted — poll [isDefaultSmsApp] on
  /// resume to confirm).
  Future<bool> requestDefaultSmsRole() async {
    try {
      return await _channel.invokeMethod<bool>('requestDefaultSmsRole') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<SmsConversation>> listConversations() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listConversations',
      );
      return (raw ?? [])
          .map((e) => SmsConversation.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    } on PlatformException {
      return const [];
    }
  }

  /// Phone contacts (name + number) for the "new SMS" screen. Empty if
  /// READ_CONTACTS is denied.
  Future<List<SmsContact>> listContacts() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listContacts');
      return (raw ?? [])
          .map((e) => SmsContact.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    } on PlatformException {
      return const [];
    }
  }

  /// Liste les messages d'un thread, paginé. [limit] = nombre max (0 = tout).
  /// [beforeMs] = ne renvoyer que les messages STRICTEMENT antérieurs à cette
  /// date epoch-ms (0 = les plus récents). Résultat trié ancien → récent.
  Future<List<SmsMessage>> listMessages(
    String threadId, {
    int limit = 0,
    int beforeMs = 0,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listMessages',
        {'threadId': threadId, 'limit': limit, 'beforeMs': beforeMs},
      );
      return (raw ?? [])
          .map((e) => SmsMessage.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    } on PlatformException {
      return const [];
    }
  }

  /// Sends an SMS. Returns the provider row id (or null on failure).
  Future<int?> sendSms(String address, String body) async {
    try {
      return await _channel.invokeMethod<int>('sendSms', {
        'address': address,
        'body': body,
      });
    } on PlatformException {
      return null;
    }
  }

  Future<int> markRead(String threadId) async {
    try {
      return await _channel.invokeMethod<int>('markRead', {
            'threadId': threadId,
          }) ??
          0;
    } on PlatformException {
      return 0;
    }
  }

  /// Removes the rich notification for [threadId] (called when the user opens
  /// or reads the conversation).
  Future<void> cancelNotification(String threadId) async {
    try {
      await _channel.invokeMethod<void>('cancelSmsNotification', {
        'threadId': threadId,
      });
    } on PlatformException {
      // best-effort
    }
  }

  /// Tells the native notifier which thread is currently on screen (or null to
  /// clear) so it won't notify a conversation the user is already looking at.
  Future<void> setActiveThread(String? threadId) async {
    try {
      await _channel.invokeMethod<void>('setActiveSmsThread', {
        'threadId': threadId,
      });
    } on PlatformException {
      // best-effort
    }
  }

  /// Deletes a single SMS or MMS message by its provider id.
  Future<int> deleteMessage(int id, {required bool isMms}) async {
    try {
      return await _channel.invokeMethod<int>('deleteMessage', {
            'id': id,
            'isMms': isMms,
          }) ??
          0;
    } on PlatformException {
      return 0;
    }
  }

  /// Deletes a whole conversation (all SMS + MMS) by thread id.
  Future<int> deleteConversation(String threadId) async {
    // Guard against a non-numeric threadId producing a `0` fallback, which on
    // the native side could match unrelated rows. Send the raw String and let
    // the native longArg() validate it.
    if (int.tryParse(threadId) == null) return 0;
    try {
      return await _channel.invokeMethod<int>('deleteConversation', {
            'threadId': threadId,
          }) ??
          0;
    } on PlatformException {
      return 0;
    }
  }

  /// Extracts an MMS part (image) to a cache file and returns its local path.
  Future<String?> loadMmsPart(int partId) async {
    try {
      return await _channel.invokeMethod<String>('loadMmsPart', {
        'partId': partId,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Sends an MMS (optional text + optional image path). Returns the provider
  /// row id of the outbox entry (or null on failure).
  Future<int?> sendMms(String address, String? body, String? imagePath) async {
    try {
      return await _channel.invokeMethod<int>('sendMms', {
        'address': address,
        'body': body,
        'imagePath': imagePath,
      });
    } on PlatformException {
      return null;
    }
  }
}

class SmsAttachment {
  final int partId;
  final String mimeType;
  final String fileName;

  const SmsAttachment({
    required this.partId,
    required this.mimeType,
    required this.fileName,
  });

  factory SmsAttachment.fromMap(Map<String, dynamic> m) => SmsAttachment(
        partId: (m['partId'] as num?)?.toInt() ?? 0,
        mimeType: '${m['mimeType'] ?? ''}',
        fileName: '${m['fileName'] ?? ''}',
      );

  bool get isImage => mimeType.startsWith('image/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');
  bool get isVcard =>
      mimeType.contains('vcard') || mimeType.contains('x-vcard');

  /// True for media we render visually inline (image or video thumbnail).
  bool get isVisualMedia => isImage || isVideo;
}

class SmsConversation {
  final String threadId;
  final String address;
  final String? displayName;
  final String snippet;
  final int date;
  final int unreadCount;

  /// Local file path of the contact's photo thumbnail (written to cache by the
  /// native layer), or null (no contact / no photo / READ_CONTACTS denied).
  /// A raw content:// URI isn't directly loadable by Flutter, so the native
  /// side extracts the bytes to a file we can show with Image.file.
  final String? photoPath;

  const SmsConversation({
    required this.threadId,
    required this.address,
    required this.displayName,
    required this.snippet,
    required this.date,
    required this.unreadCount,
    this.photoPath,
  });

  factory SmsConversation.fromMap(Map<String, dynamic> m) => SmsConversation(
        threadId: '${m['threadId']}',
        address: '${m['address'] ?? ''}',
        displayName: m['displayName'] as String?,
        snippet: '${m['snippet'] ?? ''}',
        date: (m['date'] as num?)?.toInt() ?? 0,
        unreadCount: (m['unreadCount'] as num?)?.toInt() ?? 0,
        photoPath: m['photoPath'] as String?,
      );

  String get title => displayName?.isNotEmpty == true ? displayName! : address;
}

/// A single phone number of a contact, with a humanised label (Mobile, Travail…).
class SmsContactNumber {
  final String number;
  final String label;

  const SmsContactNumber({required this.number, required this.label});

  factory SmsContactNumber.fromMap(Map<String, dynamic> m) => SmsContactNumber(
        number: '${m['number'] ?? ''}',
        label: '${m['label'] ?? ''}',
      );
}

/// A phone contact (grouped: one entry even with several pro/perso numbers).
class SmsContact {
  final String name;
  final String? photoPath;
  final List<SmsContactNumber> numbers;

  const SmsContact({
    required this.name,
    required this.numbers,
    this.photoPath,
  });

  factory SmsContact.fromMap(Map<String, dynamic> m) => SmsContact(
        name: '${m['name'] ?? ''}',
        photoPath: m['photoPath'] as String?,
        numbers: ((m['numbers'] as List<dynamic>?) ?? [])
            .map((e) => SmsContactNumber.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
      );

  String get display =>
      name.isNotEmpty ? name : (numbers.isNotEmpty ? numbers.first.number : '');
}

class SmsMessage {
  final String id;
  final String address;
  final String body;
  final int date;
  final bool isFromMe;
  final int type;
  final int status;
  final bool read;
  final bool isMms;
  final List<SmsAttachment> attachments;

  const SmsMessage({
    required this.id,
    required this.address,
    required this.body,
    required this.date,
    required this.isFromMe,
    required this.type,
    required this.status,
    required this.read,
    this.isMms = false,
    this.attachments = const [],
  });

  factory SmsMessage.fromMap(Map<String, dynamic> m) => SmsMessage(
        id: '${m['id']}',
        address: '${m['address'] ?? ''}',
        body: '${m['body'] ?? ''}',
        date: (m['date'] as num?)?.toInt() ?? 0,
        isFromMe: m['isFromMe'] == true,
        type: (m['type'] as num?)?.toInt() ?? 0,
        status: (m['status'] as num?)?.toInt() ?? -1,
        read: m['read'] == true,
        isMms: m['isMms'] == true,
        attachments: ((m['attachments'] as List<dynamic>?) ?? [])
            .map((e) => SmsAttachment.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
      );

  List<SmsAttachment> get images =>
      attachments.where((a) => a.isImage).toList();

  List<SmsAttachment> get videos =>
      attachments.where((a) => a.isVideo).toList();

  /// Images + videos, in attachment order — what the bubble renders visually.
  List<SmsAttachment> get visualMedia =>
      attachments.where((a) => a.isVisualMedia).toList();

  /// Non-visual attachments (audio, vCard, anything else) shown as file chips.
  List<SmsAttachment> get otherFiles =>
      attachments.where((a) => !a.isVisualMedia).toList();
}

class SmsIncoming {
  /// 'sms' or 'mms' (the native layer tags each event).
  final String kind;
  final String address;
  final String body;
  final int date;
  final String threadId;

  /// Provider rowId of the just-inserted message, or -1 when unknown (MMS:
  /// the body is downloaded asynchronously by the system, so no id is available
  /// at WAP-push time). Used to arm a disappearing-message expiry on a *received*
  /// SMS.
  final int messageId;

  const SmsIncoming({
    required this.kind,
    required this.address,
    required this.body,
    required this.date,
    required this.threadId,
    this.messageId = -1,
  });

  factory SmsIncoming.fromMap(Map<String, dynamic> m) => SmsIncoming(
        kind: '${m['kind'] ?? 'sms'}',
        address: '${m['address'] ?? ''}',
        body: '${m['body'] ?? ''}',
        date: (m['date'] as num?)?.toInt() ?? 0,
        threadId: '${m['threadId'] ?? ''}',
        messageId: (m['messageId'] as num?)?.toInt() ?? -1,
      );

  bool get isMms => kind == 'mms';

  /// True when [messageId] is a real provider rowId we can target for deletion.
  bool get hasMessageId => messageId > 0;
}

/// A request to open a conversation, emitted when the user taps an SMS
/// notification (or its Voice action).
class SmsOpenRequest {
  final String threadId;
  final String address;
  final bool voiceReply;

  const SmsOpenRequest({
    required this.threadId,
    required this.address,
    required this.voiceReply,
  });

  factory SmsOpenRequest.fromMap(Map<String, dynamic> m) => SmsOpenRequest(
        threadId: '${(m['threadId'] as num?)?.toInt() ?? -1}',
        address: '${m['address'] ?? ''}',
        voiceReply: m['voiceReply'] == true,
      );

  bool get isValid =>
      (int.tryParse(threadId) ?? -1) > 0 || address.isNotEmpty;
}
