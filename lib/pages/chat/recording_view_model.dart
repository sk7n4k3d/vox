import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'events/audio_player.dart';

class RecordingViewModel extends StatefulWidget {
  final Widget Function(BuildContext, RecordingViewModelState) builder;

  const RecordingViewModel({required this.builder, super.key});

  @override
  RecordingViewModelState createState() => RecordingViewModelState();
}

class RecordingViewModelState extends State<RecordingViewModel> {
  Timer? _recorderSubscription;
  Duration duration = Duration.zero;

  bool isSending = false;

  // True only once recorder.start() has actually begun capturing — NOT merely
  // when the AudioRecorder object exists. The object is created before the
  // permission check, so keying isRecording on its existence made the overlay
  // think recording had started during the permission prompt, wedging the UI
  // (1st press did nothing visible, 2nd press recorded without overlay).
  bool _recording = false;
  bool get isRecording => _recording;

  AudioRecorder? _audioRecorder;
  final List<double> amplitudeTimeline = [];

  String? fileName;

  bool isPaused = false;

  bool isLocked = false;

  bool isCancelling = false;

  bool isStarting = false;

  void lock() {
    if (!mounted || isLocked) return;
    setState(() => isLocked = true);
  }

  void unlock() {
    if (!mounted || !isLocked) return;
    setState(() => isLocked = false);
  }

  void markCancelling(bool value) {
    if (!mounted || isCancelling == value) return;
    setState(() => isCancelling = value);
  }

  Future<void> startRecording(Room room) async {
    if (mounted && !isStarting) setState(() => isStarting = true);
    room.client.getConfig(); // Preload server file configuration.
    if (PlatformInfos.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt < 19) {
        if (mounted) {
          showOkAlertDialog(
            context: context,
            title: L10n.of(context).unsupportedAndroidVersion,
            message: L10n.of(context).unsupportedAndroidVersionLong,
            okLabel: L10n.of(context).close,
          );
        }
        // Always clear the transient `isStarting` flag on early return,
        // otherwise the overlay/button stay stuck in a half-recording state
        // and the slide-to-cancel / lock UI never shows again.
        if (mounted) setState(_reset);
        return;
      }
    }

    final audioRecorder = _audioRecorder ??= AudioRecorder();
    // Single permission check (was duplicated). On denial, reset so the UI
    // returns to idle instead of being wedged in `isStarting`.
    if (await audioRecorder.hasPermission() != true) {
      if (mounted) {
        showOkAlertDialog(
          context: context,
          title: L10n.of(context).oopsSomethingWentWrong,
          message: L10n.of(context).noPermission,
        );
        setState(_reset);
      } else {
        _reset();
      }
      return;
    }
    if (mounted) setState(() {});

    try {
      final codec =
          !PlatformInfos
                  .isIOS && // Blocked by https://github.com/llfbandit/record/issues/560
              await audioRecorder.isEncoderSupported(AudioEncoder.opus)
          ? AudioEncoder.opus
          : AudioEncoder.aacLc;
      fileName =
          'voice_message_${DateTime.now().millisecondsSinceEpoch}.${codec.fileExtension}';
      String? path;
      if (!kIsWeb) {
        final tempDir = await getTemporaryDirectory();
        path = path_lib.join(tempDir.path, fileName);
      }

      await WakelockPlus.enable();

      await audioRecorder.start(
        RecordConfig(
          bitRate: AppSettings.audioRecordingBitRate.value,
          sampleRate: AppSettings.audioRecordingSamplingRate.value,
          numChannels: AppSettings.audioRecordingNumChannels.value,
          autoGain: AppSettings.audioRecordingAutoGain.value,
          echoCancel: AppSettings.audioRecordingEchoCancel.value,
          noiseSuppress: AppSettings.audioRecordingNoiseSuppress.value,
          encoder: codec,
        ),
        path: path ?? '',
      );
      setState(() {
        duration = Duration.zero;
        isStarting = false;
        _recording = true;
      });
      _subscribe();
    } catch (e, s) {
      Logs().w('Unable to start voice message recording', e, s);
      showOkAlertDialog(
        context: context,
        title: L10n.of(context).oopsSomethingWentWrong,
        message: e.toString(),
      );
      setState(_reset);
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _subscribe() {
    _recorderSubscription?.cancel();
    _recorderSubscription = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) async {
      // Capture the recorder locally: it can be nulled by cancel()/dispose()
      // between this tick and the awaited getAmplitude(), which would throw on
      // `_audioRecorder!`.
      final recorder = _audioRecorder;
      if (!mounted || recorder == null) return;
      final amplitude = await recorder.getAmplitude();
      if (!mounted || _audioRecorder == null) return;
      var value = 100 + amplitude.current * 2;
      value = value < 1 ? 1 : value;
      amplitudeTimeline.add(value);
      setState(() {
        duration += const Duration(milliseconds: 100);
      });
    });
  }

  void _reset() {
    WakelockPlus.disable();
    _recorderSubscription?.cancel();
    final recorder = _audioRecorder;
    _audioRecorder = null;
    _recording = false;
    unawaited(recorder?.stop());
    isSending = false;
    fileName = null;
    duration = Duration.zero;
    amplitudeTimeline.clear();
    isPaused = false;
    isLocked = false;
    isCancelling = false;
    isStarting = false;
  }

  void cancel() {
    if (!mounted) {
      _reset();
      return;
    }
    setState(_reset);
  }

  void pause() {
    _audioRecorder?.pause();
    _recorderSubscription?.cancel();
    setState(() {
      isPaused = true;
    });
  }

  void resume() {
    _audioRecorder?.resume();
    _subscribe();
    setState(() {
      isPaused = false;
    });
  }

  Future<void> stopAndSend(
    Future<void> Function(
      String path,
      int duration,
      List<int> waveform,
      String fileName,
    )
    onSend,
  ) async {
    _recorderSubscription?.cancel();
    final path = await _audioRecorder?.stop();

    if (path == null) throw ('Recording failed!');
    const waveCount = AudioPlayerWidget.wavesCount;
    final step = amplitudeTimeline.length < waveCount
        ? 1
        : (amplitudeTimeline.length / waveCount).round();
    final waveform = <int>[];
    for (var i = 0; i < amplitudeTimeline.length; i += step) {
      waveform.add((amplitudeTimeline[i] / 100 * 1024).round());
    }

    setState(() {
      isSending = true;
    });
    try {
      await onSend(path, duration.inMilliseconds, waveform, fileName!);
    } catch (e, s) {
      Logs().e('Unable to send voice message', e, s);
      setState(() {
        isSending = false;
      });
      return;
    }

    cancel();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}

extension on AudioEncoder {
  String get fileExtension {
    switch (this) {
      case AudioEncoder.aacLc:
      case AudioEncoder.aacEld:
      case AudioEncoder.aacHe:
        return 'm4a';
      case AudioEncoder.opus:
        return 'ogg';
      case AudioEncoder.wav:
        return 'wav';
      case AudioEncoder.amrNb:
      case AudioEncoder.amrWb:
      case AudioEncoder.flac:
      case AudioEncoder.pcm16bits:
        throw UnsupportedError('Not yet used');
    }
  }
}
