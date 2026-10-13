import 'dart:convert';

import 'package:fluffychat/utils/conversation_lock.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    ConversationLock.instance.resetForTesting();
  });

  Future<List<String>> mirror() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(ConversationLock.nativeSmsMirrorKey);
    return raw == null ? [] : (jsonDecode(raw) as List).cast<String>();
  }

  test('locking an SMS thread mirrors it for the native notifier', () async {
    final lock = ConversationLock.instance;
    await lock.load();
    await lock.lock(ConversationLock.smsId('42'));
    await lock.lock('!room:example.org');

    expect(await mirror(), ['sms:42']);
  });

  test('unlocking removes the thread from the native mirror', () async {
    final lock = ConversationLock.instance;
    await lock.load();
    await lock.lock(ConversationLock.smsId('42'));
    await lock.unlockPermanently(ConversationLock.smsId('42'));

    expect(await mirror(), isEmpty);
  });

  test('load rewrites the mirror from secure storage', () async {
    FlutterSecureStorage.setMockInitialValues({
      'chat.fluffy.locked_conversations': jsonEncode(['sms:7', '!r:x.org']),
    });
    await ConversationLock.instance.load();

    expect(await mirror(), ['sms:7']);
  });
}
