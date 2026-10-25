import 'package:fluffychat/utils/video/video_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturedStreamHandler extends MockStreamHandler {
  MockStreamHandlerEventSink? _sink;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) =>
      _sink = events;

  @override
  void onCancel(Object? arguments) => _sink = null;

  void emit(Map<String, Object?> event) {
    final sink = _sink;
    if (sink == null) {
      throw StateError('emit avant que le pont ne se soit abonné');
    }
    sink.success(event);
  }
}

class _FakeNative {
  _FakeNative(this._onCall);

  final Future<Object?> Function(String method, Map<String, Object?> args)
      _onCall;
  final List<MethodCall> calls = [];

  void bind() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('eu.devlabz.vox/video'),
            (call) async {
      calls.add(call);
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      return _onCall(call.method, args);
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CapturedStreamHandler streamHandler;
  late _FakeNative native;
  late VideoBridge bridge;

  setUp(() {
    streamHandler = _CapturedStreamHandler();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('eu.devlabz.vox/video_events'), streamHandler);
  });

  tearDown(() async {
    bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('eu.devlabz.vox/video'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('eu.devlabz.vox/video_events'), null);
  });

  void bridgeWith(
      Future<Object?> Function(String method, Map<String, Object?> args)
          onCall,
      {Duration timeout = const Duration(minutes: 5)}) {
    native = _FakeNative(onCall)..bind();
    bridge = VideoBridge(
      timeout: timeout,
      eventSource: const EventChannel('eu.devlabz.vox/video_events')
          .receiveBroadcastStream(),
    );
  }

  Map<String, Object?> doneEvent(String jobId, {bool passthrough = false}) => {
        'kind': 'done',
        'jobId': jobId,
        'outputPath': passthrough ? '/orig.mp4' : '/cache/video/$jobId.mp4',
        'width': 1080,
        'height': 1920,
        'durationMs': 80000,
        'sizeBytes': 12345678,
        'passthrough': passthrough,
      };

  group('start + waitFor', () {
    test('start returns the native jobId', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = await bridge.start('/v.mp4', compress: true);
      expect(job?.jobId, 'j1');
      expect(native.calls.single.method, 'start');
      expect(
          native.calls.single.arguments, {'path': '/v.mp4', 'compress': true});
    });

    test('waitFor resolves when the done event arrives', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit(doneEvent('j1'));
      final result = await future;
      expect(result.outputPath, '/cache/video/j1.mp4');
      expect(result.width, 1080);
      expect(result.height, 1920);
      expect(result.durationMs, 80000);
      expect(result.passthrough, isFalse);
    });

    test('done arriving before waitFor is not lost', () async {
      bridgeWith((m, a) async {
        // native résout le passe-plat AVANT que start() ne revienne à Dart
        streamHandler.emit(doneEvent('j1', passthrough: true));
        return {'jobId': 'j1'};
      });
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final result = await bridge.waitFor(job.jobId);
      expect(result.passthrough, isTrue);
      expect(result.outputPath, '/orig.mp4');
    });

    test('error event rejects with its code', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit({
        'kind': 'error',
        'jobId': 'j1',
        'code': 'encoder',
        'message': 'no'
      });
      await expectLater(
        future,
        throwsA(isA<VideoCompressionException>()
            .having((e) => e.code, 'code', 'encoder')),
      );
    });

    test('cancelled event rejects with code cancelled', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit({'kind': 'cancelled', 'jobId': 'j1'});
      await expectLater(
        future,
        throwsA(isA<VideoCompressionException>()
            .having((e) => e.code, 'code', 'cancelled')),
      );
    });
  });

  group('progress', () {
    test('progress events are forwarded', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final percents = <int>[];
      final sub = bridge.progress.listen((p) => percents.add(p.percent));
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit({'kind': 'progress', 'jobId': 'j1', 'percent': 40});
      streamHandler.emit(doneEvent('j1'));
      await future;
      await pumpEventQueue();
      expect(percents, [40]);
      await sub.cancel();
    });
  });

  group('timeout', () {
    test('no event at all rejects timeout and cancels native job', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'},
          timeout: const Duration(milliseconds: 60));
      final job = (await bridge.start('/v.mp4', compress: true))!;
      await expectLater(
        bridge.waitFor(job.jobId),
        throwsA(isA<VideoCompressionException>()
            .having((e) => e.code, 'code', 'timeout')),
      );
      expect(native.calls.map((c) => c.method), contains('cancel'));
    });

    test('a progress event re-arms the timeout', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'},
          timeout: const Duration(milliseconds: 150));
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      // progress à ~75 ms, done à ~185 ms : plus vieux que le timeout de
      // 150 ms depuis start → ne passe QUE si le timer a été remé.
      await Future<void>.delayed(const Duration(milliseconds: 75));
      streamHandler.emit({'kind': 'progress', 'jobId': 'j1', 'percent': 10});
      await Future<void>.delayed(const Duration(milliseconds: 110));
      streamHandler.emit(doneEvent('j1'));
      final result = await future;
      expect(result.outputPath, '/cache/video/j1.mp4');
    });
  });

  group('disposeResult', () {
    test('cleanup is called with the output path', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit(doneEvent('j1'));
      await future;
      await bridge.disposeResult(job.jobId);
      final cleanup = native.calls.lastWhere((c) => c.method == 'cleanup');
      expect(cleanup.arguments['paths'], ['/cache/video/j1.mp4']);
    });

    test('passthrough output is a cache copy and IS deleted', () async {
      bridgeWith((m, a) async => {'jobId': 'j1'});
      final job = (await bridge.start('/v.mp4', compress: true))!;
      final future = bridge.waitFor(job.jobId);
      streamHandler.emit(doneEvent('j1', passthrough: true));
      await future;
      await bridge.disposeResult(job.jobId);
      final cleanup = native.calls.lastWhere((c) => c.method == 'cleanup');
      expect(cleanup.arguments['paths'], ['/orig.mp4']);
    });
  });

  group('meta + thumbnail', () {
    test('meta returns parsed dimensions', () async {
      bridgeWith((m, a) async =>
          {'width': 1080, 'height': 1920, 'durationMs': 5000, 'sizeBytes': 999});
      final meta = await bridge.meta('/v.mp4');
      expect(meta!.width, 1080);
      expect(meta.durationMs, 5000);
    });

    test('meta returns null on platform error', () async {
      bridgeWith((m, a) async => throw PlatformException(code: 'unreadable'));
      expect(await bridge.meta('/v.mp4'), isNull);
    });

    test('thumbnail returns bytes', () async {
      bridgeWith((m, a) async => Uint8List.fromList([1, 2, 3]));
      final bytes = await bridge.thumbnail('/v.mp4', maxSize: 512);
      expect(bytes, [1, 2, 3]);
      expect(native.calls.single.arguments['maxSize'], 512);
    });
  });
}
