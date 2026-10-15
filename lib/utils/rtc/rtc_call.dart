import 'dart:async';

import 'package:matrix/matrix.dart' show Logs;

import 'rtc_e2ee.dart';
import 'rtc_membership.dart';
import 'rtc_service.dart';
import 'rtc_sfu_client.dart';

enum CallState { idle, connecting, ringingOut, active, ringingIn, ended, failed }

enum RtcRemoteEvent { peerJoined, peerLeft, mediaReady, failed }

/// média LiveKit derrière une interface : la vraie implémentation (task 5)
/// parle à `livekit_client`, les tests à un fake.
abstract class RtcMediaGateway {
  Future<void> connect(SfuCredentials credentials);

  /// Installe NOTRE clé média (fournie par [RtcE2ee]) pour le chiffrement
  /// sortant. Doit précéder startMedia sous peine de frames sans clé.
  Future<void> installOutboundKey(String keyLatin1, int index) async {}

  /// Installe la clé d'un pair (déjà authentifiée) pour le déchiffrant.
  Future<void> installRemoteKey(String keyLatin1, int index) async {}

  Future<void> startMedia({required bool audio, required bool video});
  Future<void> publish();
  Stream<RtcRemoteEvent> get remoteEvents;
  Future<void> dispose();

  // Actions des boutons de l'UI. Concrets : une gateway qui ne sait pas faire
  // (fake de test) n'est pas forcée de les implémenter.
  Future<void> setAudioMuted(bool muted) async {}
  Future<void> setCameraMuted(bool muted) async {}
  Future<void> flipCamera() async {}

  /// Media distant déjà reçu (voir la course de [RtcCall._listenGateway]).
  bool get hasRemoteMedia => false;
}

/// Publication/retrait de NOTRE présence dans la room (adapteur Room du
/// task 6 ; injectée pour que la machine soit testable sans Matrix).
abstract class RtcMembershipPublisher {
  /// Publie notre présence et renvoie l'event id (nécessaire pour rattacher
  /// la sonnerie MSC4075), ou null si le serveur n'en rapporte pas.
  Future<String?> publish(Map<String, Object?> content);
  Future<void> retract();
  Future<void> notify(Map<String, Object?> content);
  Future<void> sendKey(String userId, String deviceId, Object? content);
}

typedef RtcTimerHandle = void Function();

/// Planification injectable (Timer réel en prod, file triée en test).
abstract class RtcScheduler {
  RtcTimerHandle schedule(Duration delay, Future<void> Function() task);
}

class TimerScheduler implements RtcScheduler {
  @override
  RtcTimerHandle schedule(Duration delay, Future<void> Function() task) {
    late Timer timer;
    timer = Timer(delay, () => task());
    return () => timer.cancel();
  }
}

/// Machine à états d'un appel MatrixRTC 1:1 (spec §3.3).
class RtcCall {
  RtcCall({
    required this.roomId,
    required this.wantVideo,
    required this.localUserId,
    required this.localDeviceId,
    required RtcSfuClient sfu,
    required RtcMediaGateway gateway,
    required RtcMembershipPublisher memberships,
    DateTime Function()? now,
    RtcScheduler? scheduler,
  }) : _sfu = sfu,
       _gateway = gateway,
       _memberships = memberships,
       _now = now ?? DateTime.now,
       _scheduler = scheduler ?? TimerScheduler();

  final String roomId;
  final bool wantVideo;
  final String localUserId;
  final String localDeviceId;

  final RtcSfuClient _sfu;
  final RtcMembershipPublisher _memberships;
  final DateTime Function() _now;
  final RtcScheduler _scheduler;

  static const _expiryMs = 3600000; // 1 h, rafraîchie à mi-parcours

  /// Chiffrement média MatrixRTC (schéma matrix-rust-rtc, calibrage 15/10).
  RtcE2ee? _e2ee;

  RtcE2ee _ensureE2ee() => _e2ee ??= RtcE2ee(
    roomId: roomId,
    userId: localUserId,
    deviceId: localDeviceId,
    sendKey: (userId, deviceId, content) =>
        _memberships.sendKey(userId, deviceId, content),
  );

  /// Partage notre clé avec la session d'un pair (idempotent par device).
  void _shareKeysWith(RtcSessionMembership m) {
    final e2ee = _e2ee;
    if (e2ee == null) return;
    if (m.userId == localUserId && m.deviceId == localDeviceId) return;
    unawaited(
      e2ee.shareWith(m.userId, m.deviceId).catchError((Object e) {
        Logs().w('[RTC] partage de clé média impossible: $e');
      }),
    );
  }

  /// Clé reçue d'un pair (event to-device déjà authentifié par Olm en amont).
  void handleRemoteKey(RtcIncomingEvent e) {
    final key = RtcE2ee.parse(
      e.content,
      roomId: roomId,
      senderUserId: e.senderId,
      senderDeviceId: e.senderDeviceId,
    );
    if (key == null) return;
    if (key.memberId == '$localUserId:$localDeviceId') return;
    Logs().w('[RTC] clé média de ${key.memberId} (index ${key.index})');
    unawaited(_gateway.installRemoteKey(key.keyLatin1, key.index));
  }

  CallState _state = CallState.idle;
  CallState get state => _state;

  final StreamController<CallState> _onStateChanged =
      StreamController<CallState>.broadcast();
  Stream<CallState> get onStateChanged => _onStateChanged.stream;

  final RtcMediaGateway _gateway;

  /// Passerelle exposee a l UI (rendus video, futurs etats e2ee).
  RtcMediaGateway get mediaGateway => _gateway;
  StreamSubscription<RtcRemoteEvent>? _remoteEvents;
  RtcTimerHandle? _cancelRefresh;
  List<RtcFocus> _foci = const [];
  /// Foci publiés par le pair (membership) : l'entrant REJOINT le SFU de
  /// l'appelant, jamais le nôtre (calibrage M1 : Element X appelle depuis son
  /// propre homeserver).
  List<RtcFocus> _preferredFoci = const [];
  bool _outgoing = false;

  /// A appeler avant [accept] avec les `foci_preferred` de la pair.
  void provideFoci(List<RtcFocus> foci) {
    if (_preferredFoci.isEmpty && foci.isNotEmpty) _preferredFoci = foci;
  }
  bool _terminal = false;

  /// Appel sortant : réservation SFU, média, publication de présence.
  Future<void> start() async {
    if (_state != CallState.idle || _terminal) return;
    _outgoing = true;
    _setState(CallState.connecting);
    try {
      final credentials = await _credentialsWithRetry();
      if (_state != CallState.connecting) return _abortIfCeded();
      final e2ee = _ensureE2ee();
      await _gateway.connect(credentials);
      if (_state != CallState.connecting) return _abortIfCeded();
      await _gateway.installOutboundKey(e2ee.ownKeyLatin1, e2ee.ownIndex);
      await _gateway.startMedia(audio: true, video: wantVideo);
      await _gateway.publish();
      if (_state != CallState.connecting) return _abortIfCeded();
      await _publishMembership();
      if (_state != CallState.connecting) return _abortIfCeded();
      _listenGateway();
      _setState(CallState.ringingOut);
      try {
        await _sendRing();
      } on Object catch (e) {
        // la sonnerie ne casse pas l appel : sans elle il reste joignable
        // à vue depuis la timeline
        Logs().w('[RTC] échec de la sonnerie: $e');
      }
      _scheduleRefresh();
    } on Object catch (e) {
      Logs().w('[RTC] start échoué: $e');
      await _fail();
    }
  }

  /// Décrocher un entrant : même séquence, puis `active` dès que le média
  /// distant arrive.
  Future<void> accept() async {
    if (_state != CallState.ringingIn) return;
    _outgoing = false;
    _setState(CallState.connecting);
    try {
      final credentials = await _credentialsWithRetry();
      if (_state != CallState.connecting) return;
      final e2ee = _ensureE2ee();
      await _gateway.connect(credentials);
      await _gateway.installOutboundKey(e2ee.ownKeyLatin1, e2ee.ownIndex);
      await _gateway.startMedia(audio: true, video: wantVideo);
      await _gateway.publish();
      if (_state != CallState.connecting) return;
      await _publishMembership();
      final peer = _lastRemote;
      if (peer != null) _shareKeysWith(peer);
      _listenGateway();
      _scheduleRefresh();
    } on Object catch (e) {
      Logs().w('[RTC] accept échoué: $e');
      await _fail();
    }
  }

  RtcSessionMembership? _lastRemote;

  void onRemoteMembership(RtcSessionMembership m) {
    if (m.userId == localUserId) return; // autre device de nous, ou echo
    if (m.isExpiredAt(_now())) return;
    _lastRemote = m;
    _shareKeysWith(m);
    switch (_state) {
      case CallState.idle:
        _setState(CallState.ringingIn);
      case CallState.connecting when _outgoing:
        // glare : l'autre a publié avant nous → on cède l'entrant.
        unawaited(hangup());
      case CallState.ringingOut:
        _setState(CallState.active);
      default:
        break;
    }
  }

  /// Raccrocher (nous ou pair) : présence effacée, média libéré.
  Future<void> hangup() async {
    if (_terminal) return;
    _terminal = true;
    _cancelRefresh?.call();
    await _memberships.retract();
    await _gateway.dispose();
    await _remoteEvents?.cancel();
    _setState(CallState.ended);
  }

  Future<SfuCredentials> _credentialsWithRetry() async {
    final foci = _preferredFoci.isNotEmpty
        ? _preferredFoci
        : await _sfu.discoverFoci();
    if (foci.isEmpty) {
      throw const SfuAuthException('M_NO_FOCUS', 'aucun focus livekit connu');
    }
    _foci = foci;
    try {
      return await _sfu.requestCredentials(roomId, foci.first);
    } on SfuAuthException {
      // une seule régénération (token OpenID périmé), jamais de boucle.
      return await _sfu.requestCredentials(roomId, foci.first);
    }
  }

  String? _ownMembershipEventId;
  bool _ringSent = false;

  Future<void> _publishMembership() async {
    final id = await _memberships.publish(
      buildMembershipContent(
        RtcSessionMembership(
          userId: localUserId,
          deviceId: localDeviceId,
          callId: '',
          application: 'm.call',
          expiresMs: _expiryMs,
          membershipId: '',
          originServerTs: _now(),
          fociPreferred: _foci
              .map(
                (f) => RtcFocus(
                  type: f.type,
                  livekitServiceUrl: f.livekitServiceUrl,
                  livekitAlias: f.livekitAlias ?? roomId,
                ),
              )
              .toList(),
          intent: wantVideo ? 'video' : 'audio',
        ),
      ),
    );
    if (id != null && id.isNotEmpty) _ownMembershipEventId = id;
  }

  /// Sonnerie MSC4075 : uniquement le premier membre (l'appelant) la publie,
  /// rattachée à sa présence. Element X n'affiche rien sans elle.
  Future<void> _sendRing() async {
    if (_ringSent) return;
    final id = _ownMembershipEventId;
    if (id == null) {
      Logs().w('[RTC] sonnerie non envoyée : pas d event id de présence');
      return;
    }
    _ringSent = true;
    await _memberships.notify(
      buildNotificationContent(
        senderUserId: localUserId,
        deviceId: localDeviceId,
        memberEventId: id,
        senderTsMs: _now().millisecondsSinceEpoch,
        intent: wantVideo ? 'video' : 'audio',
      ),
    );
  }

  void _scheduleRefresh() {
    _cancelRefresh?.call();
    _cancelRefresh = _scheduler.schedule(
      Duration(milliseconds: _expiryMs ~/ 2),
      () async {
        if (_terminal || _state == CallState.ended) return;
        await _publishMembership();
        _scheduleRefresh();
      },
    );
  }

  void _listenGateway() {
    // rattrapage : le média a pu arriver pendant qu'on publiait notre
    // présence, avant cet abonnement au flux d'evenements
    if (_gateway.hasRemoteMedia &&
        (_state == CallState.connecting || _state == CallState.ringingOut)) {
      _setState(CallState.active);
    }
    _remoteEvents = _gateway.remoteEvents.listen((event) async {
      switch (event) {
        case RtcRemoteEvent.mediaReady:
        case RtcRemoteEvent.peerJoined:
          if (_state == CallState.ringingOut ||
              (_state == CallState.connecting && !_outgoing)) {
            _setState(CallState.active);
          }
        case RtcRemoteEvent.peerLeft:
          if (!_terminal) await hangup();
        case RtcRemoteEvent.failed:
          if (!_terminal) await _fail();
      }
    });
  }

  void _abortIfCeded() {
    // glare : hangup() a déjà nettoyé, ne pas ressusciter ringingOut.
  }

  Future<void> _fail() async {
    if (_terminal) return;
    _terminal = true;
    _cancelRefresh?.call();
    await _gateway.dispose();
    await _remoteEvents?.cancel();
    _setState(CallState.failed);
  }

  void _setState(CallState next) {
    if (_state == next) return;
    _state = next;
    Logs().w('[RTC] état: ${next.name}');
    _onStateChanged.add(next);
  }
}
