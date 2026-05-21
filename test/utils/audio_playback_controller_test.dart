import 'package:fluffychat/utils/audio_playback_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'test_client.dart';

void main() {
  late Client client;
  late Room room;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!room:example.invalid', client: client);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Event makeEvent({
    String eventId = '\$e1',
    String senderId = '@alice:example.invalid',
  }) {
    return Event(
      content: {'body': 'voice', 'msgtype': 'm.audio'},
      type: 'm.room.message',
      eventId: eventId,
      senderId: senderId,
      originServerTs: DateTime.now(),
      room: room,
    );
  }

  group('AudioPlaybackController', () {
    test('play() sets state for the given event', () {
      final controller = AudioPlaybackController();
      addTearDown(controller.dispose);

      controller.play(event: makeEvent(eventId: '\$abc'), room: room);

      expect(controller.eventId, '\$abc');
      expect(controller.roomId, room.id);
      expect(controller.senderId, '@alice:example.invalid');
      expect(controller.hasActiveTrack, isTrue);
      expect(controller.sourceVisible, isTrue);
    });

    test('stop() clears the state', () {
      final controller = AudioPlaybackController();
      addTearDown(controller.dispose);
      controller.play(event: makeEvent(), room: room);

      controller.stop();

      expect(controller.eventId, isNull);
      expect(controller.roomId, isNull);
      expect(controller.senderId, isNull);
      expect(controller.hasActiveTrack, isFalse);
    });

    test('play() with a different event replaces the previous track', () {
      final controller = AudioPlaybackController();
      addTearDown(controller.dispose);
      controller.play(event: makeEvent(eventId: '\$first'), room: room);
      controller.setSourceVisible(false, '\$first');
      expect(controller.sourceVisible, isFalse);

      controller.play(event: makeEvent(eventId: '\$second'), room: room);

      expect(controller.eventId, '\$second');
      // Source visibility resets when a new track is published.
      expect(controller.sourceVisible, isTrue);
    });

    test('setSourceVisible() only mutates state when eventId matches', () {
      final controller = AudioPlaybackController();
      addTearDown(controller.dispose);
      controller.play(event: makeEvent(eventId: '\$active'), room: room);
      expect(controller.sourceVisible, isTrue);

      // Stale report from a different bubble — should be ignored.
      controller.setSourceVisible(false, '\$stale');
      expect(controller.sourceVisible, isTrue);

      // Matching report — should take effect.
      controller.setSourceVisible(false, '\$active');
      expect(controller.sourceVisible, isFalse);
    });

    test('listeners are notified on play/stop/visibility mutations', () {
      final controller = AudioPlaybackController();
      addTearDown(controller.dispose);
      var count = 0;
      controller.addListener(() => count++);

      controller.play(event: makeEvent(eventId: '\$x'), room: room);
      expect(count, 1);

      // No-op visibility (same value) should not notify.
      controller.setSourceVisible(true, '\$x');
      expect(count, 1);

      controller.setSourceVisible(false, '\$x');
      expect(count, 2);

      controller.stop();
      expect(count, 3);
    });
  });
}
