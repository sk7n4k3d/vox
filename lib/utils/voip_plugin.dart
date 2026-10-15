import 'dart:async';
import 'dart:core';

import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:fluffychat/pages/call/incoming_call_page.dart';
import 'package:fluffychat/pages/call/livekit_call_controller.dart';
import 'package:fluffychat/pages/call/missed_call_store.dart';
import 'package:fluffychat/pages/call/rtc_video_view.dart';
import 'package:fluffychat/pages/call/voip_bridge.dart';
import 'package:fluffychat/pages/call/voip_call_controller.dart';
import 'package:fluffychat/utils/rtc/livekit_gateway.dart';
import 'package:fluffychat/utils/rtc/rtc_call.dart';
import 'package:fluffychat/utils/rtc/rtc_client_port.dart';
import 'package:fluffychat/utils/rtc/rtc_e2ee.dart';
import 'package:fluffychat/utils/rtc/rtc_service.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc_impl;
import 'package:matrix/matrix.dart' hide CallState;
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../../utils/voip/user_media_manager.dart';
import '../widgets/matrix.dart';

class VoipPlugin with WidgetsBindingObserver implements WebRTCDelegate {
  final MatrixState matrix;
  Client get client => matrix.client;
  VoipPlugin(this.matrix) {
    voip = VoIP(client, this);
    _initRtc();
    if (!kIsWeb) {
      final wb = WidgetsBinding.instance;
      wb.addObserver(this);
      didChangeAppLifecycleState(wb.lifecycleState);
    }
  }
  bool background = false;
  bool speakerOn = false;
  late VoIP voip;
  BuildContext get context => matrix.context;

  @override
  void didChangeAppLifecycleState(AppLifecycleState? state) {
    background =
        (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused);
  }

  /// Nom de route des écrans d'appel : [closeCall] nettoie tout en un seul appel.
  static const String _callRoute = '/__voip_call';

  // ── MatrixRTC (coexistence, spec 2026-10-15) ──────────────────────────
  RtcService? rtcService;
  LiveKitCallController? _rtcController;
  StreamSubscription? _rtcStateSub;
  StreamSubscription<List<BasicEventWithSender>>? _rtcKeysSub;

  /// La gateway LiveKit est creee par le service a la connexion ; la vue video
  /// s'y abonne des qu'elle apparait.
  final ValueNotifier<LiveKitGateway?> rtcGateway = ValueNotifier(null);

  void _initRtc() {
    rtcService = RtcService(
      port: RtcClientPort(client),
      gatewayFactory: () {
        final g = LiveKitGateway();
        rtcGateway.value = g;
        return g;
      },
      onIncoming: _showRtcIncoming,
    );
    // M1/M4 : journalise les cles e2ee entrantes sans les consommer encore.
    _rtcKeysSub ??= client.onCallEvents.stream.listen((events) {
      for (final e in events) {
        if (e.type == RtcE2ee.encryptionKeysEventType) {
          Logs().w(
            '[RTC-RAW] cle e2ee de ${e.senderId} '
            '(call_id=${e.content['call_id']}, '
            '${(e.content['keys'] as List?)?.length ?? 0} entree(s))',
          );
        }
      }
    });
  }

  Future<void> _showRtcIncoming(RtcCall call) async {
    final room = client.getRoomById(call.roomId);
    final callerName = room?.getLocalizedDisplayname() ?? call.roomId;
    await _bridge.acquireAudioFocus();
    await _bridge.startRinging(video: call.wantVideo);
    _showOverlay(
      () => IncomingCallPage(
        callId: call.roomId,
        roomId: call.roomId,
        callerName: callerName,
        video: call.wantVideo,
        onAnswer: _answerRtc,
        onDecline: _declineRtc,
      ),
    );
  }

  void _answerRtc() {
    final call = rtcService?.currentCall;
    if (call == null) return;
    unawaited(_bridge.stopRinging());
    unawaited(_rtcConnectAndShow(call, accepting: true));
  }

  void _declineRtc() {
    final call = rtcService?.currentCall;
    if (call == null) return;
    unawaited(call.hangup());
    unawaited(
      MissedCallStore(matrix.store).add(
        MissedCall(
          callId: 'rtc-${call.roomId}',
          roomId: call.roomId,
          callerName:
              client.getRoomById(call.roomId)?.getLocalizedDisplayname() ??
              call.roomId,
          video: call.wantVideo,
          at: DateTime.now(),
        ),
      ),
    );
  }

  /// Sortant (branche par chat.dart apres les permissions) : ecrans puis
  /// connexion. La gateway livekit est publiee par [rtcGateway].
  Future<void> startRtcOutgoing(RtcCall call) async {
    await _bridge.acquireAudioFocus();
    await _rtcConnectAndShow(call, accepting: false);
  }

  Future<void> _rtcConnectAndShow(RtcCall call, {required bool accepting}) async {
    _showRtcActive(call);
    try {
      if (accepting) {
        await call.accept();
      } else {
        await call.start();
      }
    } catch (e) {
      Logs().w('[RTC] ${accepting ? 'accept' : 'start'} a echoue: $e');
    }
  }

  Future<void> _showRtcActive(RtcCall call) async {
    final room = client.getRoomById(call.roomId);
    final peers = rtcService?.remotePeersOf(call.roomId) ?? const [];
    final peerId = peers.isNotEmpty ? peers.first.userId : null;
    // fallback pour le sortant (personne n'a encore publié de présence) : le
    // contre-participant rejoint du DM.
    String? dmPeerId;
    if (peerId == null && room != null) {
      try {
        dmPeerId = (await room.requestParticipants())
            .where((u) => u.membership == Membership.join && u.id != client.userID)
            .map((u) => u.id)
            .firstOrNull;
      } catch (e) {
        Logs().w('[RTC] contrepartie introuvable: $e');
      }
    }
    final knownPeerId = peerId ?? dmPeerId;
    _rtcStateSub?.cancel();
    // annulee a chaque re-connexion d etat et a la fin d appel
    // ignore: cancel_subscriptions
    _rtcStateSub = call.onStateChanged.listen((s) {
      if (s == CallState.ended || s == CallState.failed) {
        unawaited(_endRtcCall());
      }
    });
    _rtcController?.dispose();
    final controller = _rtcController = LiveKitCallController(
      call: call,
      gateway: call.mediaGateway,
      remoteName: knownPeerId != null
          ? room?.unsafeGetUserFromMemoryOrFallback(knownPeerId).calcDisplayname(
                    mxidLocalPartFallback: false,
                  ) ??
                  call.roomId
          : room?.getLocalizedDisplayname() ?? call.roomId,
      remoteMxid: knownPeerId,
    );
    _showOverlay(
      () => ActiveCallPage(
        controller: controller,
        remoteVideo: RtcVideoView(gatewayListenable: rtcGateway),
        localVideo: RtcVideoView(gatewayListenable: rtcGateway, local: true),
      ),
    );
  }

  Future<void> _endRtcCall() async {
    unawaited(_bridge.stopRinging());
    unawaited(_bridge.abandonAudioFocus());
    _clearOverlay();
    _rtcController?.dispose();
    _rtcController = null;
    rtcGateway.value = null;
  }

  /// A appeler a la fermeture de session : vide les ecoutes RTC.
  void rtcDispose() {
    unawaited(_rtcKeysSub?.cancel());
    _rtcKeysSub = null;
    unawaited(_rtcStateSub?.cancel());
    _rtcStateSub = null;
    unawaited(rtcService?.shutdown());
    rtcService = null;
  }

  CallSession? _session;
  VoipCallController? _controller;
  final VoipBridge _bridge = VoipBridge();
  StreamSubscription<VoipEvent>? _nativeEvents;

  CallSession? get session => _session;

  /// Navigator racine du GoRouter.
  ///
  /// On n'utilise PAS `Overlay.maybeOf()` : `matrix.context` peut pointer un
  /// parent du MaterialApp et n'a alors aucun Overlay au-dessus — cas constaté en
  /// prod le 2026-10-14 (« pas d'Overlay racine disponible, écran d'appel différé »),
  /// qui empêchait TOUT écran d'appel sortant. `navigatorKey.currentState` existe
  /// dès que le router est monté et n'a pas besoin d'un ancêtre Overlay.
  NavigatorState? get _nav {
    final key = FluffyChatApp.router.routerDelegate.navigatorKey;
    if (key.currentState != null) return key.currentState;
    try {
      return Navigator.of(_overlayContext, rootNavigator: true);
    } catch (_) {
      return null;
    }
  }

  BuildContext get _overlayContext =>
      FluffyChatApp.router.routerDelegate.navigatorKey.currentContext ?? context;

  /// Pousse l'écran d'appel. Un échec est loggé mais ne casse jamais l'appel :
  /// mieux vaut un appel sans écran qu'un appel qui meurt.
  void _showOverlay(Widget Function() builder) {
    final nav = _nav;
    if (nav == null) {
      Logs().w('[VOIP] Navigator indisponible, écran d\'appel non affiché');
      return;
    }
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => builder(),
        settings: const RouteSettings(name: _callRoute),
        fullscreenDialog: true,
      ),
    );
    Logs().w('[VOIP] écran d\'appel affiché');
  }

  /// Retire tous les écrans d'appel empilés (entrant + en cours).
  void _clearOverlay() {
    _nav?.popUntil((route) => route.settings.name != _callRoute);
  }

  /// Abonne les événements natifs une seule fois pour toute la vie du plugin :
  /// une bascule Bluetooth en plein appel doit reaching l'UI même si l'appel a été
  /// posé depuis le service permanent.
  void _listenNativeEvents() {
    _nativeEvents ??= _bridge.eventStream.listen((event) {
      if (event.kind == VoipEventKind.audioRoute && event.route != null) {
        _controller?.onNativeRouteChanged(event.route!);
      }
    });
  }

  @override
  MediaDevices get mediaDevices => webrtc_impl.navigator.mediaDevices;

  @override
  bool get isWeb => kIsWeb;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) => webrtc_impl.createPeerConnection(configuration, constraints);

  Future<bool> get hasCallingAccount async => false;

  @override
  Future<void> playRingtone() async {
    if (!background && !await hasCallingAccount) {
      try {
        await UserMediaManager().startRingingTone();
      } catch (_) {}
    }
  }

  @override
  Future<void> stopRingtone() async {
    if (!background && !await hasCallingAccount) {
      try {
        await UserMediaManager().stopRingingTone();
      } catch (_) {}
    }
  }

  @override
  Future<void> handleNewCall(CallSession call) async {
    // On ne re-teste PAS « ligne occupée » ici : le SDK l'a déjà fait avant de nous
    // appeler (voip.dart:507, qui déclenche handleMissedCall si occupé). Ici,
    // voip.currentCID pointe DÉJÀ vers cet appel lui-même (assigné ligne 539) :
    // tout test de canHandleNewCall dans cette méthode se juge occupé et
    // raccroche chaque appel, sortant comme entrant. Cause racine du « aucun
    // appel ne sort ni ne rentre » du 2026-10-14.
    _session = call;
    _controller = VoipCallController(call);
    _listenNativeEvents();

    if (PlatformInfos.isAndroid) {
      try {
        final wasForeground = await FlutterForegroundTask.isAppOnForeground;
        await matrix.store.setString(
          'wasForeground',
          wasForeground == true ? 'true' : 'false',
        );
        FlutterForegroundTask.setOnLockScreenVisibility(true);
        FlutterForegroundTask.wakeUpScreen();
        FlutterForegroundTask.launchApp();
      } catch (e) {
        Logs().e('VOIP foreground failed $e');
      }
    }

    final controller = _controller!;
    final outgoing = call.isOutgoing;

    if (outgoing) {
      // C'est NOUS qui appelons : pas de sonnerie (le vibeur en boucle venait de
      // là) et pas d'écran « répondre/refuser » — l'appelant attend la réponse.
      Logs().w('[VOIP] appel sortant vers ${controller.remoteName}');
      // Focus audio + capteur de proximite aussi cote sortant : c'est lui qui
      // declenche l'ecoute du capteur (VoipBridge.acquireAudioFocus -> startProximityWatch).
      await _bridge.acquireAudioFocus();
      _showOverlay(() => ActiveCallPage(controller: controller));
      return;
    }

    // Focus audio + sonnerie AVANT de poser l'overlay : sinon le premier « dring »
    // est avalé par la construction de l'écran.
    await _bridge.acquireAudioFocus();
    await _bridge.startRinging(video: call.type == CallType.kVideo);

    final callerName = call.remoteUserId ?? call.room.getLocalizedDisplayname();
    Logs().w('[VOIP] appel entrant de $callerName (${call.type})');

    _showOverlay(
      () => IncomingCallPage(
        callId: call.callId,
        roomId: call.room.id,
        callerName: callerName,
        video: call.type == CallType.kVideo,
        onAnswer: _answer,
        onDecline: _decline,
      ),
    );
  }

  void _answer() {
    final call = _session;
    final controller = _controller;
    if (call == null || controller == null) return;
    unawaited(_bridge.stopRinging());
    _showOverlay(() => ActiveCallPage(controller: controller));
  }

  void _decline() {
    final call = _session;
    if (call == null) return;
    call.hangup(reason: CallErrorCode.userHangup);
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    unawaited(_bridge.stopRinging());
    unawaited(_bridge.abandonAudioFocus());
    _clearOverlay();
    _controller?.dispose();
    _controller = null;
    _session = null;

    if (PlatformInfos.isAndroid) {
      try {
        FlutterForegroundTask.setOnLockScreenVisibility(false);
        FlutterForegroundTask.stopService();
        final wasForeground = matrix.store.getString('wasForeground');
        if (wasForeground == 'false') FlutterForegroundTask.minimizeApp();
      } catch (e) {
        Logs().w('[VOIP] handleCallEnded: foreground task cleanup failed: $e');
      }
    }
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
    // TODO: implement handleGroupCallEnded
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    // TODO: implement handleNewGroupCall
  }

  @override
  bool get canHandleNewCall =>
      voip.currentCID == null && voip.currentGroupCID == null;

  @override
  Future<void> handleMissedCall(CallSession session) async {
    await MissedCallStore(matrix.store).add(
      MissedCall(
        callId: session.callId,
        roomId: session.room.id,
        callerName: session.remoteUserId ?? session.room.getLocalizedDisplayname(),
        video: session.type == CallType.kVideo,
        at: DateTime.now(),
      ),
    );
  }

  /// VOX ne chiffre pas les appels (spec § 7) : on renvoie null pour que le
  /// SDK n'exige pas de clé. L'upstream renvoyait `throw
  /// UnimplementedError()`, qui faisait planter tout appel proposant un
  /// chiffrement avant même l'établissement du flux.
  @override
  EncryptionKeyProvider? get keyProvider => null;

  @override
  Future<void> registerListeners(CallSession session) async {
    // C'était le stub qui tuait l'appel entrant : le SDK appelle cette méthode avant
    // handleNewCall, et l'upstream y avait retiré CallKeep sans rien mettre à la
    // place (« Remove broken callkeep implementation »).
    //
    // VOX n'a pas de CallKeep : le service permanent VoipBridgeService garde le client
    // Matrix connecté, donc l'invite arrive par le socket et arrive jusqu'ici. Le seul
    // vrai travail est de brancher le routage audio natif sur la session.
    _listenNativeEvents();
    // On ne force PAS de route ici : le SDK Android part deja sur le
    // contre-oreille, et forcer le speaker a chaque appel rendait l'appel
    // impossible a mener discretement (bug signale le 2026-10-14).
    await _bridge.currentAudioRoute();
  }
}
