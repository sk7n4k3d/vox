import 'dart:async';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show Logs;

/// Les sorties audio gérées par [VoipBridge]. `wireName` est exactement la
/// chaîne attendue par `VoipBridge.setAudioRoute` côté Kotlin.
///
/// [earpiece] est la route d'un appel téléphonique normal (contre-oreille) : c'est
/// la position de départ d'un appel discret, et la seule alternative au speaker
/// quand aucun casque n'est branché.
enum AudioRoute {
  speaker('speaker'),
  earpiece('earpiece'),
  wired('wired'),
  bluetooth('bluetooth');

  const AudioRoute(this.wireName);

  final String wireName;
}

enum VoipEventKind {
  incomingCall,
  audioRoute,
  serviceKilled,
  hangupRequested,
  unknown;

  static VoipEventKind fromWire(String? kind) => switch (kind) {
    'incoming_call' => VoipEventKind.incomingCall,
    'audio_route' => VoipEventKind.audioRoute,
    'service_killed' => VoipEventKind.serviceKilled,
    'hangup_requested' => VoipEventKind.hangupRequested,
    _ => VoipEventKind.unknown,
  };
}

/// Un événement poussé par la couche native via l'EventChannel.
class VoipEvent {
  const VoipEvent({
    required this.kind,
    this.callId,
    this.roomId,
    this.callerName,
    this.video = false,
    this.route,
  });

  factory VoipEvent.fromMap(Map<dynamic, dynamic> map) => VoipEvent(
    kind: VoipEventKind.fromWire(map['kind'] as String?),
    callId: map['callId'] as String?,
    roomId: map['roomId'] as String?,
    callerName: map['callerName'] as String?,
    video: map['video'] as bool? ?? false,
    route: map['route'] as String?,
  );

  final VoipEventKind kind;
  final String? callId;
  final String? roomId;
  final String? callerName;
  final bool video;
  final String? route;
}

/// Client Dart du pont natif VoIP (`eu.devlabz.vox/voip`).
///
/// Aucune méthode ne lève : un pont natif qui plante, un plugin absent ou une
/// permission refusée renvoient `false` et loguent. Le VoIP ne doit jamais faire
/// tomber l'app au premier plan.
class VoipBridge {
  VoipBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
    : _channel = methodChannel ?? const MethodChannel(methodChannelName),
      _events = eventChannel ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'eu.devlabz.vox/voip';
  static const String eventChannelName = 'eu.devlabz.vox/voip_events';

  final MethodChannel _channel;
  final EventChannel _events;

  Stream<VoipEvent>? _stream;

  /// Flux des événements natifs (appel entrant, bascule audio, service tué).
  /// Chaque appel BuildContext listen déclenche une seule subscription au canal.
  Stream<VoipEvent> get eventStream =>
      _stream ??= _events.receiveBroadcastStream().map(
        (event) => VoipEvent.fromMap(event as Map<dynamic, dynamic>),
      );

  Future<bool> startPersistentService() =>
      _invokeBool('startPersistentService');

  Future<bool> stopPersistentService() => _invokeBool('stopPersistentService');

  Future<bool> setAudioRoute(AudioRoute route) => _invokeBool(
    'setAudioRoute',
    {'route': route.wireName},
  );

  Future<String> currentAudioRoute() async => await _invoke(
        'currentAudioRoute',
        fallback: AudioRoute.earpiece.wireName,
      ) ??
      AudioRoute.earpiece.wireName;

  Future<bool> acquireAudioFocus() => _invokeBool('acquireAudioFocus');

  Future<bool> abandonAudioFocus() => _invokeBool('abandonAudioFocus');

  Future<bool> startRinging({required bool video}) =>
      _invokeBool('startRinging', {'video': video});

  Future<bool> stopRinging() => _invokeBool('stopRinging');

  /// Sonnerie d'attente de l'appel sortant (« ça sonne chez l'autre »).
  Future<bool> startRingback() => _invokeBool('startRingback');

  Future<bool> stopRingback() => _invokeBool('stopRingback');

  /// Notification d'appel : un appui ouvre l'app, l'action « Raccrocher » coupe.
  Future<bool> showCallNotification({
    required String title,
    required String text,
    bool ongoing = true,
  }) => _invokeBool('showCallNotification', {
    'title': title,
    'text': text,
    'ongoing': ongoing,
  });

  Future<bool> clearCallNotification() => _invokeBool('clearCallNotification');

  Future<bool> requestCallPermissions() => _invokeBool('requestCallPermissions');

  Future<bool> isCallPermissionGranted(String permission) async =>
      await _invokeBool('isCallPermissionGranted', {'permission': permission});

  Future<bool> isIgnoringBatteryOptimizations() =>
      _invokeBool('isIgnoringBatteryOptimizations');

  Future<bool> requestIgnoreBatteryOptimizations() =>
      _invokeBool('requestIgnoreBatteryOptimizations');

  Future<void> log(String message) =>
      _invoke<void>('nativeLog', args: {'message': message});

  Future<bool> _invokeBool(String method, [Map<String, dynamic>? args]) async =>
      await _invoke<bool>(method, args: args, fallback: false) == true;

  Future<T?> _invoke<T>(
    String method, {
    Map<String, dynamic>? args,
    T? fallback,
  }) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException catch (e) {
      Logs().w('[VOIP] $method: plugin natif absent (${e.message})');
      return fallback;
    } on PlatformException catch (e) {
      Logs().w('[VOIP] $method a échoué côté natif: ${e.code} ${e.message}');
      return fallback;
    } catch (e) {
      Logs().w('[VOIP] $method a levé une exception inattendue: $e');
      return fallback;
    }
  }
}