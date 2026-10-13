import 'dart:async';

import 'package:fluffychat/utils/scheduled/scheduled_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend extends ScheduledSmsBackend {
  _FakeBackend({this.native = false});

  final bool native;
  final List<String> sent = [];
  final Map<String, String> nativeResults = {};
  final Set<String> nativeScheduled = {};
  bool Function() submitResult = () => true;
  Completer<void>? gate;

  @override
  bool get supportsNative => native;

  @override
  Future<bool> submit(String address, String body) async {
    await gate?.future;
    sent.add(body);
    return submitResult();
  }

  @override
  Future<bool> scheduleNative(ScheduledMessage m) async {
    nativeScheduled.add(m.id);
    return true;
  }

  @override
  Future<bool> cancelNative(String id) async => nativeScheduled.remove(id);

  @override
  Future<Map<String, String>> takeNativeResults() async {
    final r = Map.of(nativeResults);
    nativeResults.clear();
    return r;
  }
}

ScheduledMessage _sms(String id, {String body = 'hello', int? sendAt}) =>
    ScheduledMessage(
      id: id,
      body: body,
      sendAt: sendAt ?? DateTime.now().millisecondsSinceEpoch,
      smsAddress: '+33600000000',
    );

Future<void> _settle() => Future.delayed(const Duration(milliseconds: 30));

void main() {
  late _FakeBackend backend;
  late ScheduledMessages scheduled;

  Future<void> setUpWith(_FakeBackend b) async {
    backend = b;
    scheduled = ScheduledMessages.forTesting(b)
      ..overdueDelay = Duration.zero
      ..retryDelay = ((_) => Duration.zero);
    await scheduled.start(null);
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('submitted SMS is sent once even without a provider row', () async {
    await setUpWith(_FakeBackend());
    await scheduled.schedule(_sms('a'));
    await _settle();

    expect(backend.sent, ['hello']);
    expect(scheduled.all, isEmpty);
  });

  test('retries are bounded and the message is kept as failed', () async {
    await setUpWith(_FakeBackend()..submitResult = () => false);
    await scheduled.schedule(_sms('a'));
    await _settle();

    expect(backend.sent, hasLength(ScheduledMessages.maxAttempts));
    expect(scheduled.all.single.failed, isTrue);
  });

  test('rescheduling a failed message retries it', () async {
    var ok = false;
    await setUpWith(_FakeBackend()..submitResult = () => ok);
    await scheduled.schedule(_sms('a'));
    await _settle();
    ok = true;

    expect(await scheduled.reschedule('a', body: 'edited'), isTrue);
    await _settle();
    expect(backend.sent.last, 'edited');
    expect(scheduled.all, isEmpty);
  });

  test('cancel before the due time prevents the send', () async {
    await setUpWith(_FakeBackend());
    final later = DateTime.now().add(const Duration(milliseconds: 20));
    await scheduled.schedule(_sms('a', sendAt: later.millisecondsSinceEpoch));
    expect(await scheduled.cancel('a'), isTrue);
    await _settle();

    expect(backend.sent, isEmpty);
  });

  test('reschedule sends the edited body, never the stale one', () async {
    await setUpWith(_FakeBackend());
    final later = DateTime.now().add(const Duration(milliseconds: 20));
    await scheduled.schedule(_sms('a', sendAt: later.millisecondsSinceEpoch));
    await scheduled.reschedule('a', body: 'new');
    await _settle();

    expect(backend.sent, ['new']);
  });

  test('cancel and reschedule are refused while sending', () async {
    await setUpWith(_FakeBackend()..gate = Completer<void>());
    await scheduled.schedule(_sms('a'));
    await _settle();

    expect(await scheduled.cancel('a'), isFalse);
    expect(await scheduled.reschedule('a', body: 'x'), isFalse);
    backend.gate!.complete();
    await _settle();
    expect(backend.sent, ['hello']);
    expect(scheduled.all, isEmpty);
  });

  test('all returns a sorted copy without reordering the queue', () async {
    await setUpWith(_FakeBackend());
    final now = DateTime.now().add(const Duration(hours: 1));
    await scheduled.schedule(
      _sms(
        'late',
        sendAt: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ),
    );
    await scheduled.schedule(_sms('early', sendAt: now.millisecondsSinceEpoch));

    expect(scheduled.all.map((m) => m.id), ['early', 'late']);
    expect(scheduled.forSms('+33600000000').map((m) => m.id), [
      'late',
      'early',
    ]);
    await scheduled.cancel('late');
    await scheduled.cancel('early');
  });

  group('native AlarmManager', () {
    test('SMS are handed to native, not sent from Dart', () async {
      await setUpWith(_FakeBackend(native: true));
      await scheduled.schedule(_sms('a'));
      await _settle();

      expect(backend.sent, isEmpty);
      expect(backend.nativeScheduled, {'a'});
    });

    test('native results update the queue', () async {
      await setUpWith(_FakeBackend(native: true));
      await scheduled.schedule(_sms('a'));
      await scheduled.schedule(_sms('b'));
      backend.nativeResults.addAll({'a': 'sent', 'b': 'failed'});
      await scheduled.syncNativeResults();

      expect(scheduled.all.single.id, 'b');
      expect(scheduled.all.single.failed, isTrue);
    });

    test('cancel is refused once the alarm already fired', () async {
      await setUpWith(_FakeBackend(native: true));
      await scheduled.schedule(_sms('a'));
      backend.nativeScheduled.clear();
      backend.nativeResults['a'] = 'sent';

      expect(await scheduled.cancel('a'), isFalse);
      expect(scheduled.all, isEmpty);
    });
  });
}
