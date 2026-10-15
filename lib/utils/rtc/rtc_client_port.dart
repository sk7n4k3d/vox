import 'dart:async';

import 'package:matrix/matrix.dart';

import 'rtc_membership.dart';
import 'rtc_service.dart';
import 'rtc_sfu_client.dart';

/// Implémentation [RtcSessionPort] posée sur le [Client] matrix-dart.
class RtcClientPort implements RtcSessionPort {
  RtcClientPort(this.client);

  final Client client;

  @override
  String get userId => client.userID!;
  @override
  String get deviceId => client.deviceID!;

  /// Cle sous laquelle notre presence est stockee dans l etat de la room,
  /// identique a celle d Element X (sinon sa lecture nous ignore, calibrage
  /// serveur 15/10 : voir legacyMembershipStateKey).
  String get _stateKey => legacyMembershipStateKey(userId, deviceId);

  @override
  Stream<RtcIncomingEvent> get membershipEvents =>
      client.onRoomState.stream
          .map((update) => update.state)
          .where((state) => state is Event)
          .cast<Event>()
          .where((event) => event.type == rtcMembershipEventType)
          .map(
            (event) => RtcIncomingEvent(
              roomId: event.room.id,
              senderId: event.senderId,
              content: Map<String, Object?>.from(event.content),
              originServerTs: event.originServerTs,
            ),
          );

  @override
  Future<bool> isRoomJoined(String roomId) async =>
      client.getRoomById(roomId)?.membership == Membership.join;

  @override
  Future<String?> publishMembership(
    String roomId,
    Map<String, Object?> content,
  ) => client.setRoomStateWithKey(
    roomId,
    rtcMembershipEventType,
    _stateKey,
    content,
  );

  @override
  Future<void> sendNotification(
    String roomId,
    Map<String, Object?> content,
  ) async {
    await client.getRoomById(roomId)?.sendEvent(
      content,
      type: rtcNotificationEventType,
      displayPendingEvent: false,
    );
  }

  @override
  Future<void> retractMembership(String roomId) => client.setRoomStateWithKey(
    roomId,
    rtcMembershipEventType,
    _stateKey,
    {},
  );

  @override
  Future<RtcSfuClient?> sfuClient() async {
    if (client.userID == null ||
        client.deviceID == null ||
        client.homeserver == null) {
      return null;
    }
    final candidate = RtcSfuClient.of(client);
    try {
      final foci = await candidate.discoverFoci();
      return foci.any((f) => f.type == 'livekit') ? candidate : null;
    } catch (e) {
      Logs().w('[RTC] découverte des foci impossible: $e');
      return null;
    }
  }
}
