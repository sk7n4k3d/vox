import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the native video compressor (Media3 Transformer, Kotlin
/// `VideoCompressorPlugin`). Talks over `eu.devlabz.vox/video` + the
/// `eu.devlabz.vox/video_events` EventChannel.
///
/// Lifecycle of a job: [start] returns a jobId immediately, the native side
/// reports `progress`/`done`/`error`/`cancelled` events. [waitFor] resolves
/// when the job finishes; a `done` that arrives before anyone waits is kept.
/// If the native encoder goes silent for [timeout] (no event for the job at
/// all), the bridge gives up on its own and cancels the native job — that
/// silent-forever hang is exactly what `video_compress` used to do.
class VideoJob {
  const VideoJob(this.jobId);

  final String jobId;
}

class VideoProgress {
  const VideoProgress(this.jobId, this.percent);

  final String jobId;
  final int percent;
}

class VideoMeta {
  const VideoMeta({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.sizeBytes,
  });

  /// Dimensions already rotation-applied (display orientation).
  final int width;
  final int height;
  final int durationMs;
  final int sizeBytes;
}

class VideoJobResult {
  const VideoJobResult({
    required this.jobId,
    required this.outputPath,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.sizeBytes,
    required this.passthrough,
  });

  final String jobId;

  /// Compressed file under the app cache, or the input path when
  /// [passthrough] (already small/compliant enough — never delete it).
  final String outputPath;
  final int width;
  final int height;
  final int durationMs;
  final int sizeBytes;
  final bool passthrough;
}

class VideoCompressionException implements Exception {
  const VideoCompressionException(this.code, [this.message = '']);

  /// `encoder | unreadable | timeout | cancelled`
  final String code;
  final String message;

  @override
  String toString() => 'VideoCompressionException($code, $message)';
}

/// A timeout or cancellation must not silently send the original attachment.
bool shouldSendOriginalAfterCompressionFailure(Object error) =>
    error is! VideoCompressionException ||
    (error.code != 'timeout' && error.code != 'cancelled');

int? _asInt(Object? v) => v is num ? v.toInt() : null;

class VideoBridge {
  VideoBridge({
    this.timeout = const Duration(minutes: 5),
    Stream<dynamic>? eventSource,
  }) {
    _eventsSubscription = (eventSource ??
            _events.receiveBroadcastStream())
        .listen(_onEvent, onError: (Object e) => debugPrint('video event error: $e'));
  }

  static final VideoBridge instance = VideoBridge();

  static const MethodChannel _channel = MethodChannel('eu.devlabz.vox/video');
  static const EventChannel _events = EventChannel('eu.devlabz.vox/video_events');

  /// Safety net against a native encoder that never reports again.
  final Duration timeout;

  /// jobId of the last successful [waitFor] — lets the sender clean the temp
  /// file up after the upload without threading ids through the UI layer.
  String? lastCompressJobId;

  final Map<String, Completer<VideoJobResult>> _pending = {};
  final Map<String, VideoJobResult> _finished = {};
  final Map<String, Object?> _failures = {};
  final Map<String, Timer> _timers = {};
  final StreamController<VideoProgress> _progressCtrl =
      StreamController<VideoProgress>.broadcast();
  StreamSubscription<dynamic>? _eventsSubscription;

  Stream<VideoProgress> get progress => _progressCtrl.stream;

  Future<VideoJob?> start(String path, {required bool compress}) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'start',
        {'path': path, 'compress': compress},
      );
      final jobId = result?['jobId'] as String?;
      if (jobId == null) return null;
      _armTimeout(jobId);
      return VideoJob(jobId);
    } on Object catch (e) {
      debugPrint('video start failed: $e');
      return null;
    }
  }

  Future<VideoJobResult> waitFor(String jobId) {
    final failure = _failures[jobId];
    if (failure != null) return Future.error(failure);
    final finished = _finished[jobId];
    if (finished != null) return Future.value(finished);
    return _pending.putIfAbsent(jobId, Completer<VideoJobResult>.new).future;
  }

  Future<VideoJobResult?> resultFor(String jobId) async =>
      _finished[jobId];

  Future<void> cancel(String jobId) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'jobId': jobId});
    } on Object catch (e) {
      debugPrint('video cancel failed: $e');
    }
  }

  Future<VideoMeta?> meta(String path) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'meta',
        {'path': path},
      );
      if (result == null) return null;
      return VideoMeta(
        width: _asInt(result['width']) ?? 0,
        height: _asInt(result['height']) ?? 0,
        durationMs: _asInt(result['durationMs']) ?? 0,
        sizeBytes: _asInt(result['sizeBytes']) ?? 0,
      );
    } on Object catch (e) {
      debugPrint('video meta failed: $e');
      return null;
    }
  }

  Future<Uint8List?> thumbnail(String path, {int maxSize = 720}) async {
    try {
      return await _channel.invokeMethod<Uint8List>(
        'thumbnail',
        {'path': path, 'maxSize': maxSize},
      );
    } on Object catch (e) {
      debugPrint('video thumbnail failed: $e');
      return null;
    }
  }

  /// Deletes the temp output of a finished job. Passthrough outputs are
  /// copies made under the app cache too — the user's source file itself is
  /// never in scope (native cleanup is guarded to cacheDir/video).
  Future<void> disposeResult(String jobId) async {
    final result = _finished.remove(jobId);
    if (result == null) return;
    try {
      await _channel
          .invokeMethod<void>('cleanup', {'paths': [result.outputPath]});
    } on Object catch (e) {
      debugPrint('video cleanup failed: $e');
    }
  }

  void dispose() {
    _eventsSubscription?.cancel();
    _eventsSubscription = null;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_progressCtrl.close());
  }

  void _armTimeout(String jobId) {
    _timers.remove(jobId)?.cancel();
    _timers[jobId] = Timer(timeout, () => _onTimeout(jobId));
  }

  void _onTimeout(String jobId) {
    if (_finished.containsKey(jobId) || _failures.containsKey(jobId)) return;
    _settleFailure(jobId,
        const VideoCompressionException('timeout', 'compression silencieuse'));
    unawaited(cancel(jobId));
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = raw.cast<String, Object?>();
    final jobId = event['jobId'] as String?;
    if (jobId == null) return;
    // A late encoder callback must not reverse a timeout, cancellation or
    // another terminal result, nor restart the timer for an already-ended job.
    if (_finished.containsKey(jobId) || _failures.containsKey(jobId)) return;
    switch (event['kind']) {
      case 'progress':
        _armTimeout(jobId);
        final percent = _asInt(event['percent']) ?? 0;
        _progressCtrl.add(VideoProgress(jobId, percent));
      case 'done':
        _finish(jobId, event);
      case 'error':
        _settleFailure(
          jobId,
          VideoCompressionException(
            event['code'] as String? ?? 'encoder',
            event['message'] as String? ?? '',
          ),
        );
      case 'cancelled':
        _settleFailure(
            jobId, const VideoCompressionException('cancelled', 'annulé'));
    }
  }

  void _finish(String jobId, Map<String, Object?> event) {
    final result = VideoJobResult(
      jobId: jobId,
      outputPath: event['outputPath'] as String? ?? '',
      width: _asInt(event['width']) ?? 0,
      height: _asInt(event['height']) ?? 0,
      durationMs: _asInt(event['durationMs']) ?? 0,
      sizeBytes: _asInt(event['sizeBytes']) ?? 0,
      passthrough: event['passthrough'] == true,
    );
    _timers.remove(jobId)?.cancel();
    _finished[jobId] = result;
    lastCompressJobId = jobId;
    _settle(_pending.remove(jobId), error: null, result: result);
  }

  void _settleFailure(String jobId, Object error) {
    _timers.remove(jobId)?.cancel();
    _failures[jobId] = error;
    _settle(_pending.remove(jobId), error: error, result: null);
  }

  void _settle(
    Completer<VideoJobResult>? completer, {
    required Object? error,
    required VideoJobResult? result,
  }) {
    if (completer == null) return;
    if (error != null) {
      // waitFor may be called later (it then reads _failures) — make sure the
      // error of this already-settled future is not reported as unhandled.
      completer.future.ignore();
      completer.completeError(error);
    } else {
      completer.complete(result);
    }
  }
}
