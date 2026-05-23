import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/pages/chat/events/audio_speed_bottom_sheet.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/error_reporter.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/playback_speed_controller.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:just_audio/just_audio.dart';
import 'package:matrix/matrix.dart';
import 'package:opus_caf_converter_dart/opus_caf_converter_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/matrix.dart';

class AudioPlayerWidget extends StatefulWidget {
  final Color color;
  final Color linkColor;
  final double fontSize;
  final Event event;

  static const int wavesCount = 40;

  const AudioPlayerWidget(
    this.event, {
    required this.color,
    required this.linkColor,
    required this.fontSize,
    super.key,
  });

  @override
  AudioPlayerState createState() => AudioPlayerState();
}

enum AudioPlayerStatus { notDownloaded, downloading, downloaded }

class AudioPlayerState extends State<AudioPlayerWidget> {
  static const double buttonSize = 36;

  AudioPlayerStatus status = AudioPlayerStatus.notDownloaded;
  double? _downloadProgress;

  late final MatrixState matrix;
  List<int>? _waveform;
  String? _durationString;
  VoidCallback? _detachSpeedListener;

  @override
  void dispose() {
    super.dispose();
    final audioPlayer = matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (audioPlayer == null) return;
    // Still playing — leave the player alive so the sticky [MiniAudioPlayer]
    // can keep controlling it. Mark the source as off-screen so the mini
    // player slides in immediately.
    if (audioPlayer.playing && !audioPlayer.isAtEndPosition) {
      matrix.audioPlayback.setSourceVisible(false, widget.event.eventId);
      return;
    }
    // Stopped / finished — tear down.
    audioPlayer.pause();
    audioPlayer.dispose();
    _detachSpeedListener?.call();
    _detachSpeedListener = null;
    matrix.voiceMessageEventId.value = matrix.audioPlayer = null;
    matrix.audioPlayback.stop();
  }

  Future<void> _onButtonTap() async {
    final currentPlayer =
        matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (currentPlayer != null && !currentPlayer.isAtEndPosition) {
      if (currentPlayer.playing) {
        currentPlayer.pause();
      } else {
        currentPlayer.play();
      }
      return;
    }

    matrix.voiceMessageEventId.value = widget.event.eventId;
    _detachSpeedListener?.call();
    _detachSpeedListener = null;
    matrix.audioPlayer
      ?..stop()
      ..dispose();
    // Clear previous track metadata on the shared controller; a new one
    // will be published once the player is ready below.
    matrix.audioPlayback.stop();
    File? file;
    MatrixFile? matrixFile;

    setState(() => status = AudioPlayerStatus.downloading);
    try {
      final fileSize = widget.event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
      matrixFile = await widget.event.downloadAndDecryptAttachment(
        onDownloadProgress: fileSize != null && fileSize > 0
            ? (progress) {
                final progressPercentage = progress / fileSize;
                setState(() {
                  _downloadProgress = progressPercentage < 1
                      ? progressPercentage
                      : null;
                });
              }
            : null,
      );

      final attachmentUrl = widget.event.attachmentOrThumbnailMxcUrl();

      if (!kIsWeb && attachmentUrl != null) {
        final tempDir = await getTemporaryDirectory();
        final fileName = Uri.encodeComponent(attachmentUrl.pathSegments.last);
        file = File('${tempDir.path}/${fileName}_${matrixFile.name}');

        await file.writeAsBytes(matrixFile.bytes);

        if (Platform.isIOS &&
            matrixFile.mimeType.toLowerCase() == 'audio/ogg') {
          Logs().v('Convert ogg audio file for iOS...');
          final convertedFile = File('${file.path}.caf');
          if (await convertedFile.exists() == false) {
            OpusCaf().convertOpusToCaf(file.path, convertedFile.path);
          }
          file = convertedFile;
        }
      }

      setState(() {
        status = AudioPlayerStatus.downloaded;
      });
    } catch (e, s) {
      Logs().v('Could not download audio file', e, s);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      rethrow;
    }
    if (!context.mounted) return;
    if (matrix.voiceMessageEventId.value != widget.event.eventId) return;

    final audioPlayer = matrix.audioPlayer = AudioPlayer();
    _detachSpeedListener = playbackSpeedController.attachPlayer(audioPlayer);
    matrix.audioPlayback.play(
      player: audioPlayer,
      event: widget.event,
      room: widget.event.room,
    );

    if (file != null) {
      audioPlayer.setFilePath(file.path);
    } else {
      await audioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.dataFromBytes(matrixFile.bytes, mimeType: matrixFile.mimeType),
        ),
      );
    }

    audioPlayer.play().onError(
      ErrorReporter(context, 'Unable to play audio message').onErrorCallback,
    );
  }

  Future<void> _toggleSpeed() => playbackSpeedController.cycle();

  String _formatSpeed(double s) =>
      s == s.truncateToDouble() ? '${s.toInt()}x' : '${s}x';

  List<int>? _getWaveform() {
    final eventWaveForm = widget.event.content
        .tryGetMap<String, Object?>('org.matrix.msc1767.audio')
        ?.tryGetList<int>('waveform');
    if (eventWaveForm == null || eventWaveForm.isEmpty) {
      return null;
    }
    while (eventWaveForm.length < AudioPlayerWidget.wavesCount) {
      for (var i = 0; i < eventWaveForm.length; i = i + 2) {
        eventWaveForm.insert(i, eventWaveForm[i]);
      }
    }
    var i = 0;
    final step = (eventWaveForm.length / AudioPlayerWidget.wavesCount).round();
    while (eventWaveForm.length > AudioPlayerWidget.wavesCount) {
      eventWaveForm.removeAt(i);
      i = (i + step) % AudioPlayerWidget.wavesCount;
    }
    return eventWaveForm.map((i) => i > 1024 ? 1024 : i).toList();
  }

  @override
  void initState() {
    super.initState();
    matrix = Matrix.of(context);
    _waveform = _getWaveform();

    // If we're rebuilding the bubble for the currently active track, the
    // source bubble is back in the timeline — let the controller know so
    // the mini player slides out.
    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        matrix.audioPlayback.setSourceVisible(true, widget.event.eventId);
      });
    }

    final durationInt = widget.event.content
        .tryGetMap<String, Object?>('info')
        ?.tryGet<int>('duration');
    if (durationInt != null) {
      final duration = Duration(milliseconds: durationInt);
      _durationString = duration.minuteSecondString;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waveform = _waveform;

    return VisibilityDetector(
      key: Key('audio-${widget.event.eventId}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        matrix.audioPlayback.setSourceVisible(
          info.visibleFraction >= 0.3,
          widget.event.eventId,
        );
      },
      child: ValueListenableBuilder(
        valueListenable: matrix.voiceMessageEventId,
        builder: (context, eventId, _) {
        final audioPlayer = eventId != widget.event.eventId
            ? null
            : matrix.audioPlayer;

        final fileDescription = widget.event.fileDescription;

        return StreamBuilder<Object>(
          stream: audioPlayer == null
              ? null
              : StreamGroup.merge([
                  audioPlayer.positionStream.asBroadcastStream(),
                  audioPlayer.playerStateStream.asBroadcastStream(),
                ]),
          builder: (context, _) {
            final maxPosition =
                audioPlayer?.duration?.inMilliseconds.toDouble() ?? 1.0;
            var currentPosition =
                audioPlayer?.position.inMilliseconds.toDouble() ?? 0.0;
            if (currentPosition > maxPosition) currentPosition = maxPosition;

            final wavePosition =
                (currentPosition / maxPosition) * AudioPlayerWidget.wavesCount;

            final statusText = audioPlayer == null
                ? _durationString ?? '00:00'
                : audioPlayer.position.minuteSecondString;
            return Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                mainAxisSize: .min,
                crossAxisAlignment: .start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: FluffyThemes.columnWidth,
                    ),
                    child: Row(
                      mainAxisSize: .min,
                      children: <Widget>[
                        SizedBox(
                          width: buttonSize,
                          height: buttonSize,
                          child: status == AudioPlayerStatus.downloading
                              ? CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: widget.color,
                                  value: _downloadProgress,
                                )
                              : InkWell(
                                  borderRadius: BorderRadius.circular(64),
                                  onLongPress: () =>
                                      widget.event.saveFile(context),
                                  onTap: _onButtonTap,
                                  child: Material(
                                    color: widget.color.withAlpha(64),
                                    borderRadius: BorderRadius.circular(64),
                                    child: Icon(
                                      audioPlayer?.playing == true &&
                                              audioPlayer?.isAtEndPosition ==
                                                  false
                                          ? Icons.pause_outlined
                                          : Icons.play_arrow_outlined,
                                      color: widget.color,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Stack(
                            children: [
                              if (waveform != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                  ),
                                  child: Row(
                                    children: [
                                      for (
                                        var i = 0;
                                        i < AudioPlayerWidget.wavesCount;
                                        i++
                                      )
                                        Expanded(
                                          child: Container(
                                            height: 32,
                                            alignment: Alignment.center,
                                            child: Container(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: i < wavePosition
                                                    ? widget.color
                                                    : widget.color.withAlpha(
                                                        128,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(64),
                                              ),
                                              height: 32 * (waveform[i] / 1024),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              SizedBox(
                                height: 32,
                                child: Slider(
                                  thumbColor:
                                      widget.event.senderId ==
                                          widget.event.room.client.userID
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.primary,
                                  activeColor: waveform == null
                                      ? widget.color
                                      : Colors.transparent,
                                  inactiveColor: waveform == null
                                      ? widget.color.withAlpha(128)
                                      : Colors.transparent,
                                  max: maxPosition,
                                  value: currentPosition,
                                  onChanged: (position) => audioPlayer == null
                                      ? _onButtonTap()
                                      : audioPlayer.seek(
                                          Duration(
                                            milliseconds: position.round(),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Sprint 2 V3.1 — width bumped 36→56 to fit '00:00'
                        // dans la new bubble gradient sans wrap → '00:0\\n4'.
                        SizedBox(
                          width: 56,
                          child: Text(
                            statusText,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: widget.color,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedCrossFade(
                          // Sprint 2 V3.1 — drop the parasite mic icon shown
                          // before playback. Empty placeholder keeps the
                          // crossfade transition smooth when the user taps
                          // play and the speed pill appears.
                          firstChild: const SizedBox(width: 32, height: 20),
                          secondChild: ValueListenableBuilder<double>(
                            valueListenable: playbackSpeedController,
                            builder: (context, speed, _) => Material(
                              color: widget.color.withAlpha(
                                speed > 1.0 ? 128 : 64,
                              ),
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius,
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  AppConfig.borderRadius,
                                ),
                                onTap: _toggleSpeed,
                                onLongPress: () => showAdaptiveBottomSheet(
                                  context: context,
                                  builder: (_) => const AudioSpeedBottomSheet(),
                                ),
                                child: SizedBox(
                                  width: 32,
                                  height: 20,
                                  child: Center(
                                    child: Text(
                                      _formatSpeed(speed),
                                      style: TextStyle(
                                        color: widget.color,
                                        fontSize: 9,
                                        fontWeight: speed != 1.0
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          crossFadeState: audioPlayer == null
                              ? CrossFadeState.showFirst
                              : CrossFadeState.showSecond,
                          duration: FluffyThemes.animationDuration,
                        ),
                      ],
                    ),
                  ),
                  if (fileDescription != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Linkify(
                        text: fileDescription,
                        textScaleFactor: MediaQuery.textScalerOf(
                          context,
                        ).scale(1),
                        style: TextStyle(
                          color: widget.color,
                          fontSize: widget.fontSize,
                        ),
                        options: const LinkifyOptions(humanize: false),
                        linkStyle: TextStyle(
                          color: widget.linkColor,
                          fontSize: widget.fontSize,
                          decoration: TextDecoration.underline,
                          decorationColor: widget.linkColor,
                        ),
                        onOpen: (url) =>
                            UrlLauncher(context, url.url).launchUrl(),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
        },
      ),
    );
  }
}

extension on AudioPlayer {
  bool get isAtEndPosition {
    final duration = this.duration;
    if (duration == null) return true;
    return position >= duration;
  }
}

extension on Duration {
  String get minuteSecondString =>
      '${inMinutes.toString().padLeft(2, '0')}:${(inSeconds % 60).toString().padLeft(2, '0')}';
}
