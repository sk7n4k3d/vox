import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/utils/media/media_backfill.dart';

/// A room history that serves canned pages, oldest page appended last.
class _FakeHistory implements MediaHistory {
  _FakeHistory(List<List<MediaEventInfo>> pages) : _pages = pages {
    events.addAll(pages.first);
  }

  final List<List<MediaEventInfo>> _pages;
  final List<MediaEventInfo> events = [];
  int _next = 1;
  int requestCount = 0;

  @override
  bool get canRequestHistory => _next < _pages.length;

  @override
  Future<void> requestHistory() async {
    requestCount++;
    events.addAll(_pages[_next]);
    _next++;
  }
}

class _FakeSource implements MediaBackfillSource {
  _FakeSource(this._rooms, {this.ownUserId = '@me:server'});

  final Map<String, List<List<MediaEventInfo>>> _rooms;
  final Map<String, _FakeHistory> opened = {};

  @override
  final String ownUserId;

  @override
  Future<List<String>> joinedRoomIds() async => _rooms.keys.toList();

  @override
  Future<MediaHistory> history(String roomId) async {
    final h = _FakeHistory(_rooms[roomId]!);
    opened[roomId] = h;
    return h;
  }
}

class _FakeStore implements MediaBackfillStore {
  _FakeStore([Set<String>? initial]) : done = {...?initial};

  final Set<String> done;
  final List<String> marked = [];

  @override
  Future<Set<String>> loadDoneRooms() async => {...done};

  @override
  Future<void> markRoomDone(String roomId) async {
    done.add(roomId);
    marked.add(roomId);
  }
}

MediaEventInfo _img(String id, {String sender = '@alice:server'}) =>
    MediaEventInfo(
      eventId: id,
      messageType: 'm.image',
      senderId: sender,
    );

MediaEventInfo _vid(String id, {String sender = '@alice:server'}) =>
    MediaEventInfo(
      eventId: id,
      messageType: 'm.video',
      senderId: sender,
    );

MediaEventInfo _text(String id) => MediaEventInfo(
      eventId: id,
      messageType: 'm.text',
      senderId: '@alice:server',
    );

void main() {
  group('MediaBackfillEngine', () {
    test('exports incoming media across every history page, in order', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$new'), _text(r'$t')],
          [_vid(r'$old'), _img(r'$mine', sender: '@me:server')],
        ],
      });
      final exported = <String>[];
      final engine = MediaBackfillEngine(
        source: source,
        store: _FakeStore(),
        isExported: (_) async => false,
        exportEvent: (e) async {
          exported.add(e.eventId);
          return true;
        },
      );

      final result = await engine.run();

      expect(exported, [r'$new', r'$old']);
      expect(source.opened['!room:server']!.requestCount, 1);
      expect(result.exported, 2);
      expect(result.finished, isTrue);
    });

    test('skips own messages, redacted events and non-media types', () async {
      final redacted = MediaEventInfo(
        eventId: r'$red',
        messageType: 'm.image',
        senderId: '@alice:server',
        redacted: true,
      );
      final source = _FakeSource({
        '!room:server': [
          [
            _img(r'$keep'),
            _img(r'$own', sender: '@me:server'),
            redacted,
            _text(r'$txt'),
          ],
        ],
      });
      final exported = <String>[];
      final engine = MediaBackfillEngine(
        source: source,
        store: _FakeStore(),
        isExported: (_) async => false,
        exportEvent: (e) async {
          exported.add(e.eventId);
          return true;
        },
      );

      await engine.run();

      expect(exported, [r'$keep']);
    });

    test('does not export events already present in the gallery', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$done'), _img(r'$todo')],
        ],
      });
      final exported = <String>[];
      final engine = MediaBackfillEngine(
        source: source,
        store: _FakeStore(),
        isExported: (id) async => id == r'$done',
        exportEvent: (e) async {
          exported.add(e.eventId);
          return true;
        },
      );

      await engine.run();

      expect(exported, [r'$todo']);
    });

    test('skips rooms already marked done', () async {
      final source = _FakeSource({
        '!done:server': [
          [_img(r'$a')],
        ],
        '!todo:server': [
          [_img(r'$b')],
        ],
      });
      final exported = <String>[];
      final engine = MediaBackfillEngine(
        source: source,
        store: _FakeStore({'!done:server'}),
        isExported: (_) async => false,
        exportEvent: (e) async {
          exported.add(e.eventId);
          return true;
        },
      );

      await engine.run();

      expect(exported, [r'$b']);
      expect(source.opened.keys, ['!todo:server']);
    });

    test('marks a room done only when its whole history was walked', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$a')],
        ],
      });
      final store = _FakeStore();
      final engine = MediaBackfillEngine(
        source: source,
        store: store,
        isExported: (_) async => false,
        exportEvent: (_) async => true,
      );

      await engine.run();

      expect(store.marked, ['!room:server']);
    });

    test('does not mark a room done when an export failed', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$a'), _img(r'$b')],
        ],
      });
      final store = _FakeStore();
      final engine = MediaBackfillEngine(
        source: source,
        store: store,
        isExported: (_) async => false,
        exportEvent: (e) async => e.eventId != r'$a',
      );

      final result = await engine.run();

      expect(store.marked, isEmpty);
      expect(result.exported, 1);
      expect(result.finished, isTrue);
    });

    test('reports the number of failed exports in the progress', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$a'), _img(r'$b'), _img(r'$c')],
        ],
      });
      final engine = MediaBackfillEngine(
        source: source,
        store: _FakeStore(),
        isExported: (_) async => false,
        exportEvent: (e) async => e.eventId != r'$b',
      );

      final result = await engine.run();

      expect(result.exported, 2);
      expect(result.failed, 1);
    });

    test('a throwing export does not abort the run and blocks done-marking',
        () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$a'), _img(r'$b')],
        ],
      });
      final store = _FakeStore();
      final engine = MediaBackfillEngine(
        source: source,
        store: store,
        isExported: (_) async => false,
        exportEvent: (e) async {
          if (e.eventId == r'$a') throw StateError('boom');
          return true;
        },
      );

      final result = await engine.run();

      expect(store.marked, isEmpty);
      expect(result.exported, 1);
    });

    test('does not mark a room done when the walk is cancelled', () async {
      final source = _FakeSource({
        '!room:server': [
          [_img(r'$a'), _img(r'$b')],
        ],
      });
      final store = _FakeStore();
      late MediaBackfillEngine engine;
      engine = MediaBackfillEngine(
        source: source,
        store: store,
        isExported: (_) async => false,
        exportEvent: (_) async {
          engine.cancel();
          return true;
        },
      );

      final result = await engine.run();

      expect(store.marked, isEmpty);
      expect(result.cancelled, isTrue);
      expect(result.finished, isFalse);
    });
  });
}
