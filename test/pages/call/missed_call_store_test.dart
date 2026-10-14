import 'package:fluffychat/pages/call/missed_call_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

MissedCall call(String id, int hour, {bool video = false}) => MissedCall(
  callId: id,
  roomId: 'room-$id',
  callerName: 'caller-$id',
  video: video,
  at: DateTime(2026, 10, 14, hour),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<MissedCallStore> freshStore() async =>
      MissedCallStore(await SharedPreferences.getInstance());

  test('un store neuf ne contient aucun appel manqué', () async {
    expect((await freshStore()).recent, isEmpty);
  });

  test('ajoute un appel manqué et le restitue du plus récent au plus ancien',
      () async {
    final store = await freshStore();
    await store.add(call('a', 10));
    await store.add(call('b', 11));
    await store.add(call('c', 9));

    expect(store.recent.map((c) => c.callId), ['b', 'a', 'c']);
  });

  test('ne garde que les 50 derniers appels manqués', () async {
    final store = await freshStore();
    for (var i = 0; i < 60; i++) {
      await store.add(call('c$i', i % 24));
    }

    expect(store.recent, hasLength(MissedCallStore.maxEntries));
  });

  test('un appel rejoue avec le meme callId ne s accumule pas', () async {
    final store = await freshStore();
    await store.add(call('a', 10));
    await store.add(call('b', 11));
    await store.add(call('a', 12));

    expect(store.recent.map((c) => c.callId), ['a', 'b']);
    expect(store.recent.first.at.hour, 12);
  });

  test('conserve les attributs video et callerName', () async {
    final store = await freshStore();
    await store.add(call('a', 10, video: true));

    expect(store.recent.single.video, isTrue);
    expect(store.recent.single.callerName, 'caller-a');
    expect(store.recent.single.roomId, 'room-a');
  });

  test('clear vide le journal', () async {
    final store = await freshStore();
    await store.add(call('a', 10));
    await store.clear();

    expect(store.recent, isEmpty);
  });

  test('survit a une reinstanciation du store (persistance)', () async {
    final prefs = await SharedPreferences.getInstance();
    await MissedCallStore(prefs).add(call('a', 10));

    expect(MissedCallStore(prefs).recent.single.callId, 'a');
  });

  test('une donnee corrompue ne fait pas planter la lecture', () async {
    SharedPreferences.setMockInitialValues({
      'voip.missedCalls': '{pas du json',
    });
    final store = MissedCallStore(await SharedPreferences.getInstance());

    expect(store.recent, isEmpty);
  });
}