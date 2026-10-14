import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Un appel manqué, persisté pour être affiché plus tard dans l'app.
class MissedCall {
  MissedCall({
    required this.callId,
    required this.roomId,
    required this.callerName,
    required this.video,
    required this.at,
  });

  final String callId;
  final String roomId;
  final String callerName;
  final bool video;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'roomId': roomId,
    'callerName': callerName,
    'video': video,
    'at': at.millisecondsSinceEpoch,
  };

  factory MissedCall.fromJson(Map<String, dynamic> json) => MissedCall(
    callId: json['callId'] as String? ?? '',
    roomId: json['roomId'] as String? ?? '',
    callerName: json['callerName'] as String? ?? '',
    video: json['video'] as bool? ?? false,
    at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0),
  );
}

/// Journal des appels manqués VoIP. Trié du plus récent au plus ancien,
/// plafonné à [maxEntries] pour ne pas faire grossir le stockage.
class MissedCallStore {
  MissedCallStore(this.store);

  static const String storageKey = 'voip.missedCalls';
  static const int maxEntries = 50;

  final SharedPreferences store;

  List<MissedCall> get recent {
    final raw = store.getString(storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
              .cast<Map<String, dynamic>>()
              .map(MissedCall.fromJson)
              .toList()
            ..sort((a, b) => b.at.compareTo(a.at));
    } catch (_) {
      return [];
    }
  }

  Future<void> add(MissedCall call) async {
    final list = recent..removeWhere((c) => c.callId == call.callId);
    list.insert(0, call);
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    await store.setString(
      storageKey,
      jsonEncode(list.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> clear() => store.remove(storageKey);
}