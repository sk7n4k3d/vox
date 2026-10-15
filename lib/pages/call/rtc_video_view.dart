import 'dart:async';

import 'package:fluffychat/utils/rtc/livekit_gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// Rend une piste vidéo LiveKit (locale ou distante). La gateway n'existe
/// qu'a partir de la connexion reussie : on l'attend via [gatewayListenable]
/// et on ecoute ensuite ses emissions de pistes.
class RtcVideoView extends StatefulWidget {
  const RtcVideoView({
    required this.gatewayListenable,
    this.local = false,
    this.placeholder,
    super.key,
  });

  final ValueListenable<LiveKitGateway?> gatewayListenable;
  final bool local;
  final Widget? placeholder;

  @override
  State<RtcVideoView> createState() => _RtcVideoViewState();
}

class _RtcVideoViewState extends State<RtcVideoView> {
  lk.VideoTrack? _track;
  StreamSubscription<LiveKitTracks>? _tracksSub;
  LiveKitGateway? _gateway;

  @override
  void initState() {
    super.initState();
    widget.gatewayListenable.addListener(_onGatewayChanged);
    _onGatewayChanged();
  }

  void _onGatewayChanged() {
    final gateway = widget.gatewayListenable.value;
    if (gateway == _gateway) return;
    unawaited(_tracksSub?.cancel());
    _gateway = gateway;
    if (gateway == null) {
      _apply(const LiveKitTracks());
      return;
    }
    _apply(gateway.currentTracks);
    _tracksSub = gateway.tracks.listen(_apply);
  }

  void _apply(LiveKitTracks tracks) {
    if (!mounted) return;
    final next = widget.local ? tracks.localVideo : tracks.remoteVideo;
    if (next != _track) setState(() => _track = next);
  }

  @override
  void dispose() {
    widget.gatewayListenable.removeListener(_onGatewayChanged);
    unawaited(_tracksSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    if (track == null) {
      return widget.placeholder ??
          const ColoredBox(color: Colors.black54, child: SizedBox.expand());
    }
    return lk.VideoTrackRenderer(
      track,
      mirrorMode: widget.local
          ? lk.VideoViewMirrorMode.mirror
          : lk.VideoViewMirrorMode.off,
    );
  }
}
