import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
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
  Future<List<RtcFocus>> calleeFoci(String roomId) async {
    final room = client.getRoomById(roomId);
    final me = client.userID;
    if (room == null || me == null) return const [];
    final others =
        room.getParticipants([Membership.join]).where((u) => u.id != me).toList();
    if (others.length != 1) return const [];
    final domain = others.single.id.split(':').last;
    final anon = http.Client();
    final probe = RtcSfuClient(
      homeserver: Uri.https(domain),
      userId: me,
      deviceId: client.deviceID ?? '',
      plainGet: (uri) async =>
          jsonDecode((await anon.get(uri)).body) as Map<String, Object?>,
      openidToken: () async =>
          throw StateError('well-known distant sans openid'),
      plainPost: (_, __) async => throw StateError('well-known distant'),
    );
    try {
      final foci = await probe.discoverFoci();
      return foci.where((f) => f.type == 'livekit').toList();
    } catch (e) {
      Logs().w('[RTC] foci du répondant injoignables: $e');
      return const [];
    } finally {
      anon.close();
    }
  }

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
