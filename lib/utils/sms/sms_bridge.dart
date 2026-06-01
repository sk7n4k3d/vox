import 'dart:async';

import 'package:flutter/services.dart';

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

  /// Broadcast stream of incoming SMS (only fires while VOX is the default
  /// SMS app — that's an Android constraint, not a bug).
  Stream<SmsIncoming> get incoming => _incoming ??= _events
      .receiveBroadcastStream()
      .map((e) => SmsIncoming.fromMap(Map<String, dynamic>.from(e as Map)))
      .asBroadcastStream();

  Future<bool> isDefaultSmsApp() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultSmsApp') ?? false;
    } on PlatformException {
      return false;
    }
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

  Future<List<SmsMessage>> listMessages(String threadId) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listMessages',
        {'threadId': threadId},
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
}

class SmsConversation {
  final String threadId;
  final String address;
  final String? displayName;
  final String snippet;
  final int date;
  final int unreadCount;

  const SmsConversation({
    required this.threadId,
    required this.address,
    required this.displayName,
    required this.snippet,
    required this.date,
    required this.unreadCount,
  });

  factory SmsConversation.fromMap(Map<String, dynamic> m) => SmsConversation(
        threadId: '${m['threadId']}',
        address: '${m['address'] ?? ''}',
        displayName: m['displayName'] as String?,
        snippet: '${m['snippet'] ?? ''}',
        date: (m['date'] as num?)?.toInt() ?? 0,
        unreadCount: (m['unreadCount'] as num?)?.toInt() ?? 0,
      );

  String get title => displayName?.isNotEmpty == true ? displayName! : address;
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
}

class SmsIncoming {
  /// 'sms' or 'mms' (the native layer tags each event).
  final String kind;
  final String address;
  final String body;
  final int date;
  final String threadId;

  const SmsIncoming({
    required this.kind,
    required this.address,
    required this.body,
    required this.date,
    required this.threadId,
  });

  factory SmsIncoming.fromMap(Map<String, dynamic> m) => SmsIncoming(
        kind: '${m['kind'] ?? 'sms'}',
        address: '${m['address'] ?? ''}',
        body: '${m['body'] ?? ''}',
        date: (m['date'] as num?)?.toInt() ?? 0,
        threadId: '${m['threadId'] ?? ''}',
      );

  bool get isMms => kind == 'mms';
}
