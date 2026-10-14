import 'dart:core';

import 'package:fluffychat/pages/call/missed_call_store.dart';
import 'package:fluffychat/pages/chat_list/chat_list.dart';
import 'package:fluffychat/pages/dialer/dialer.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc_impl;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;

import '../../utils/voip/user_media_manager.dart';
import '../widgets/matrix.dart';

class VoipPlugin with WidgetsBindingObserver implements WebRTCDelegate {
  final MatrixState matrix;
  Client get client => matrix.client;
  VoipPlugin(this.matrix) {
    voip = VoIP(client, this);
    if (!kIsWeb) {
      final wb = WidgetsBinding.instance;
      wb.addObserver(this);
      didChangeAppLifecycleState(wb.lifecycleState);
    }
  }
  bool background = false;
  bool speakerOn = false;
  late VoIP voip;
  OverlayEntry? overlayEntry;
  BuildContext get context => matrix.context;

  @override
  void didChangeAppLifecycleState(AppLifecycleState? state) {
    background =
        (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused);
  }

  void addCallingOverlay(String callId, CallSession call) {
    // Prefer the navigator key context — it always sits under a Navigator
    // so Overlay.of() resolves. matrix.context can point to a parent of
    // the MaterialApp without an Overlay, leading to a "Null check operator
    // used on a null value" crash inside Overlay.of() (Flutter 3.41 bug).
    final navContext =
        FluffyChatApp.router.routerDelegate.navigatorKey.currentContext;
    final context = kIsWeb
        ? ChatList.contextForVoip!
        : (navContext ?? this.context);

    if (overlayEntry != null) {
      Logs().e('[VOIP] addCallingOverlay: The call session already exists?');
      overlayEntry!.remove();
    }
    // Fallback to a dialog when no Overlay ancestor is reachable (web, or
    // cold-start before the router has mounted its navigator).
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (kIsWeb || overlay == null) {
      showDialog(
        context: context,
        builder: (context) => Calling(
          context: context,
          client: client,
          callId: callId,
          call: call,
          onClear: () => Navigator.of(context).pop(),
        ),
      );
    } else {
      overlayEntry = OverlayEntry(
        builder: (_) => Calling(
          context: context,
          client: client,
          callId: callId,
          call: call,
          onClear: () {
            overlayEntry?.remove();
            overlayEntry = null;
          },
        ),
      );
      overlay.insert(overlayEntry!);
    }
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
      // use fallback flutter call pages for outgoing and video calls.
      addCallingOverlay(call.callId, call);
    } else {
      addCallingOverlay(call.callId, call);
    }
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    try {
      overlayEntry?.remove();
    } catch (e) {
      Logs().w('[VOIP] handleCallEnded: failed to remove overlay: $e');
    }
    overlayEntry = null;
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
    // Listeners are propagated through onCallStateChanged / onCallEventChanged
    // streams already consumed by the Calling widget. Upstream FluffyChat
    // removed its CallKeep wiring (CHANGELOG: "Remove broken callkeep
    // implementation") without restoring a fallback, so incoming calls would
    // hit this method and crash the call before handleNewCall could fire.
    return;
  }
}
