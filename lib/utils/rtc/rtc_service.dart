import 'dart:async';
import 'dart:convert';

import 'package:matrix/matrix.dart' show Logs;

import 'rtc_call.dart';
import 'rtc_membership.dart';
import 'rtc_sfu_client.dart';

/// Événement de présence reçu, réduit à ce qui nous intéresse.
class RtcIncomingEvent {
  final String roomId;
  final String senderId;
  final Map<String, Object?> content;
  final DateTime originServerTs;

  const RtcIncomingEvent({
    required this.roomId,
    required this.senderId,
    required this.content,
    required this.originServerTs,
  });
}

/// Ce dont le service a besoin du monde Matrix. Adapter sur [Client] côté
/// plugin ; fake en test — la machine à états reste testable sans SDK.
abstract class RtcSessionPort {
  String get userId;
  String get deviceId;

  Stream<RtcIncomingEvent> get membershipEvents;

  Future<bool> isRoomJoined(String roomId);
  Future<void> publishMembership(String roomId, Map<String, Object?> content);
  Future<void> retractMembership(String roomId);

  /// Client prêt à parler au SFU, ou null si le homeserver n'annonce aucun
  /// focus livekit (le well-known est le juge de paix, spec §1).
  Future<RtcSfuClient?> sfuClient();
}

/// Pilote les appels MatrixRTC d'une session : un seul appel actif à la fois
/// (v1), détection des entrants, création des sortants.
class RtcService {
  RtcService({
    required RtcSessionPort port,
    required RtcMediaGateway Function() gatewayFactory,
    void Function(RtcCall call)? onIncoming,
    DateTime Function()? now,
    RtcScheduler? scheduler,
  }) : _port = port,
       _gatewayFactory = gatewayFactory,
       _onIncoming = onIncoming ?? _noop,
       _now = now ?? DateTime.now,
       _scheduler = scheduler ?? TimerScheduler() {
    _sub = _port.membershipEvents.listen(handleMembershipEvent);
  }

  final RtcSessionPort _port;
  final RtcMediaGateway Function() _gatewayFactory;
  final void Function(RtcCall call) _onIncoming;
  final DateTime Function() _now;
  final RtcScheduler _scheduler;

  StreamSubscription<RtcIncomingEvent>? _sub;
  RtcCall? _current;
  String? _remoteOfCurrent;
  final Map<String, List<RtcSessionMembership>> _peers = {};
  RtcSfuClient? _sfu;
  bool? _availableCache;

  RtcCall? get currentCall => _current;

  /// Dernières présences vivantes connues par room (base du partage de clés).
  List<RtcSessionMembership> remotePeersOf(String roomId) =>
      List.unmodifiable(_peers[roomId] ?? const []);

  Future<void> shutdown() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Le homeserver annonce-t-il un média-server RTC joignable ?
  Future<bool> rtcAvailable() async {
    if (_availableCache == true) return true;
    // un echec (homeserver pas encore pret) ne se fige pas : on re-interroge
    final sfu = _sfu ??= await _port.sfuClient();
    _availableCache = sfu != null;
    return _availableCache!;
  }

  /// Point d'entrée unique des events de présence (stream prod ou test).
  Future<void> handleMembershipEvent(RtcIncomingEvent event) async {
    // M1 (spec §8) : journal brut calibré sur le trafic réel d'Element X.
    // Contient IDs et foci uniquement — jamais de token ni de clé.
    Logs().w(
      '[RTC-RAW] membership ${event.roomId} de ${event.senderId} @'
      '${event.originServerTs.toIso8601String()}: '
      '${_truncate(jsonEncode(event.content))}',
    );
    if (event.senderId == _port.userId) return; // notre propre écho
    final members = parseMembershipEvent(
      event.content,
      event.senderId,
      event.originServerTs,
    );
    final alive = members
        .where((m) => !m.isExpiredAt(_now()) && m.isImplicitRoomCall)
        .toList();
    if (alive.isEmpty) {
      // retrait de présence : si notre appel actif perd ce pair, on finit.
      if (_current != null &&
          _current!.roomId == event.roomId &&
          _remoteOfCurrent == event.senderId) {
        await _current!.hangup();
      }
      return;
    }
    if (await _port.isRoomJoined(event.roomId) != true) return;
    _peers[event.roomId] = alive;
    if (_current != null) {
      Logs().w('[RTC] appel déjà actif : nouvelle présence ignorée');
      return;
    }
    final sfu = _sfu ??= await _port.sfuClient();
    if (sfu == null) return;
    _availableCache = true;
    final call = _makeCall(event.roomId, video: false, sfu: sfu);
    // l entrant rejoint le média-server annonce par l appelant
    call.provideFoci(alive.first.fociPreferred);
    _current = call;
    _remoteOfCurrent = event.senderId;
    call.onRemoteMembership(alive.first);
    if (call.state == CallState.ringingIn) _onIncoming(call);
  }

  /// Déclare un appel sortant ; l'écran appelle ensuite [RtcCall.start].
  /// Retourne null si le homeserver n'a pas de focus RTC.
  Future<RtcCall?> outgoingCall({
    required String roomId,
    required bool video,
  }) async {
    final sfu = _sfu ??= await _port.sfuClient();
    if (sfu == null) return null;
    final call = _makeCall(roomId, video: video, sfu: sfu);
    _current = call;
    return call;
  }

  RtcCall _makeCall(
    String roomId, {
    required bool video,
    required RtcSfuClient sfu,
  }) {
    final gateway = _gatewayFactory();
    final call = RtcCall(
      roomId: roomId,
      wantVideo: video,
      localUserId: _port.userId,
      localDeviceId: _port.deviceId,
      memberships: _PortPublisher(_port, roomId),
      gateway: gateway,
      sfu: sfu,
      now: _now,
      scheduler: _scheduler,
    );
    call.onStateChanged.listen((s) {
      if (s == CallState.ended || s == CallState.failed) {
        if (_current == call) {
          _current = null;
          _remoteOfCurrent = null;
        }
      }
    });
    return call;
  }
}

/// Adapte le port étroit à l'interface de publication de présence.
class _PortPublisher implements RtcMembershipPublisher {
  final RtcSessionPort _port;
  final String _roomId;

  _PortPublisher(this._port, this._roomId);

  @override
  Future<void> publish(Map<String, Object?> content) =>
      _port.publishMembership(_roomId, content);

  @override
  Future<void> retract() => _port.retractMembership(_roomId);
}

void _noop(RtcCall call) {}

/// Bornage du journal brut : un event malveillant ou énorme ne doit pas
/// saturer logcat/stockage.
String _truncate(String s) => s.length <= 400 ? s : '${s.substring(0, 400)}…';
