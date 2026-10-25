import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/utils/resize_video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('eu.devlabz.vox/video');
const _events = EventChannel('eu.devlabz.vox/video_events');

class _MockStream extends MockStreamHandler {
  MockStreamHandlerEventSink? _sink;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) =>
      _sink = events;

  @override
  void onCancel(Object? arguments) => _sink = null;

  void emit(Map<String, Object?> event) => _sink?.success(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late List<MethodCall> calls;
  late _MockStream sink;
  Object? Function(String method, Map<String, Object?> args) handler =
      (_, _) => null;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('resize_video_test');
    calls = [];
    sink = _MockStream();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(_events, sink);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      return handler(call.method, args);
    });
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(_events, null);
  });

  File writeFile(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('getVideoInfo compresses via the native bridge, no dimension swapping',
      () async {
    final src = writeFile('in.mp4', [1, 2, 3]);
    final out = writeFile('out.mp4', [9, 8, 7, 6]);
    var emitted = false;
    handler = (method, args) {
      if (method == 'start') {
        if (!emitted) {
          emitted = true;
          sink.emit({
            'kind': 'done',
            'jobId': 'j1',
            'outputPath': out.path,
            'width': 1080,
            'height': 1920,
            'durationMs': 80000,
            'sizeBytes': 4,
            'passthrough': false,
          });
        }
        return {'jobId': 'j1'};
      }
      return null;
    };
    final file = await XFile(src.path).getVideoInfo(compress: true);
    expect(file.bytes.toList(), [9, 8, 7, 6]);
    expect(file.width, 1080);
    expect(file.height, 1920);
    expect(file.duration, 80);
    expect(calls.map((c) => c.method), containsAllInOrder(['start']));
  });

  test('compress=false reads metadata only, never starts a job', () async {
    final src = writeFile('in.mp4', [1, 2, 3]);
    handler = (method, args) {
      if (method == 'meta') {
        return {
          'width': 720,
          'height': 1280,
          'durationMs': 5000,
          'sizeBytes': 3,
        };
      }
      return null;
    };
    final file = await XFile(src.path).getVideoInfo(compress: false);
    expect(file.bytes.toList(), [1, 2, 3]);
    expect(file.width, 720);
    expect(file.height, 1280);
    expect(file.duration, 5);
    expect(calls.map((c) => c.method), isNot(contains('start')));
  });

  test('getVideoThumbnail returns native thumbnail bytes', () async {
    final src = writeFile('in.mp4', [1]);
    handler = (method, args) =>
        method == 'thumbnail' ? Uint8List.fromList([42, 43]) : null;
    final thumb = await XFile(src.path).getVideoThumbnail();
    expect(thumb?.bytes.toList(), [42, 43]);
  });

  test('getVideoThumbnail is null when native has no frame', () async {
    final src = writeFile('in.mp4', [1]);
    handler = (_, _) => null;
    expect(await XFile(src.path).getVideoThumbnail(), isNull);
  });
}
