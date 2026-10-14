import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

class VideoRenderer extends StatefulWidget {
  final WrappedMediaStream? stream;
  final bool mirror;
  final RTCVideoViewObjectFit fit;

  const VideoRenderer(
    this.stream, {
    this.mirror = false,
    this.fit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _VideoRendererState();
}

class _VideoRendererState extends State<VideoRenderer> {
  RTCVideoRenderer? _renderer;
  bool _rendererReady = false;
  MediaStream? get mediaStream => widget.stream?.stream;
  StreamSubscription? _streamChangeSubscription;

  Future<RTCVideoRenderer> _initializeRenderer() async {
    _renderer ??= RTCVideoRenderer();
    await _renderer!.initialize();
    _renderer!.srcObject = mediaStream;
    return _renderer!;
  }

  void disposeRenderer() {
    try {
      _renderer?.srcObject = null;
      _renderer?.dispose();
      _renderer = null;
      // ignore: empty_catches
    } catch (e) {}
  }

  @override
  void initState() {
    _streamChangeSubscription = widget.stream?.onStreamChanged.stream.listen((
      stream,
    ) {
      if (!mounted) return;
      setState(() {
        _renderer?.srcObject = stream;
      });
    });
    setupRenderer();
    super.initState();
  }

  Future<void> setupRenderer() async {
    await _initializeRenderer();
    // Le widget peut avoir ete retire entre-temps : setState sans mounted leve
    // une exception qui tue le frame de l'appel.
    if (mounted) setState(() => _rendererReady = true);
  }

  /// Le flux WebRTC arrive presque TOUJOURS apres le premier dessin : la camera
  /// s'ouvre, puis le MediaStream est enregistre dans la session. Sans cette
  /// methode, initState s'abonnait a `widget.stream?.onStreamChanged` — donc sur
  /// null — et le renderer restait sur un srcObject nul pour tout l'appel.
  /// Symptome : audio parfait, ecran noir, log `setVideoTrack to null`.
  @override
  void didUpdateWidget(VideoRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(oldWidget.stream, widget.stream)) {
      _streamChangeSubscription?.cancel();
      _streamChangeSubscription = widget.stream?.onStreamChanged.stream.listen((
        stream,
      ) {
        if (!mounted) return;
        setState(() => _renderer?.srcObject = stream);
      });

      // Le flux peut deja etre rempli : appliquer immediatement plutot que
      // d'attendre un nouvel evenement qui ne viendra pas.
      final current = mediaStream;
      if (current != null) {
        _renderer?.srcObject = current;
      } else {
        _renderer?.srcObject = null;
      }
    }

    if (oldWidget.mirror != widget.mirror || oldWidget.fit != widget.fit) {
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _streamChangeSubscription?.cancel();
    disposeRenderer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_rendererReady || _renderer == null
      ? Container()
      : Builder(
          key: widget.key,
          builder: (ctx) {
            return RTCVideoView(
              _renderer!,
              mirror: widget.mirror,
              filterQuality: FilterQuality.medium,
              objectFit: widget.fit,
              placeholderBuilder: (_) =>
                  Container(color: Colors.white.withAlpha(45)),
            );
          },
        );
}
