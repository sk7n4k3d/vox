import 'dart:convert';
import 'dart:typed_data';

import 'package:fluffychat/utils/rtc/rtc_e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

({
  RtcE2ee e2ee,
  List<({String type, Map<String, Map<String, Object?>> byUser})> sent,
}) _make({String callId = 'call-1'}) {
  final sent =
      <({String type, Map<String, Map<String, Object?>> byUser})>[];
  final e2ee = RtcE2ee(
    callId: callId,
    sender: (type, messages) async => sent.add((type: type, byUser: messages)),
  );
  return (e2ee: e2ee, sent: sent);
}

void main() {
  test('passkey : 32 octets aléatoires, présente au share', () async {
    final c = _make();
    expect(c.e2ee.passkey, hasLength(32));
    await c.e2ee.shareWithDevice('@noemie:s', 'N1');
    expect(c.sent.single.type, 'io.element.call.encryption_keys');
    final content = (c.sent.single.byUser['@noemie:s']!['N1']!
        as Map).cast<String, Object?>();
    expect(content['call_id'], 'call-1');
    final keys = content['keys'] as List;
    final entry = (keys.single as Map).cast<String, Object?>();
    expect(entry['index'], 0);
    expect(
      base64Decode(entry['key']! as String),
      c.e2ee.passkey,
    );
  });

  test('deux devices = deux destinataires, même message', () async {
    final c = _make();
    await c.e2ee.shareWithDevice('@noemie:s', 'N1');
    await c.e2ee.shareWithDevice('@noemie:s', 'N2');
    expect(c.sent, hasLength(2));
    final content = (c.sent.first.byUser['@noemie:s']!['N1']!
        as Map).cast<String, Object?>();
    final keyB64 = (((content['keys'] as List).single as Map)['key']
        as String);
    expect(base64Decode(keyB64), c.e2ee.passkey);
  });

  test('keys entrantes valides → onKey émet la clé décodée', () async {
    final c = _make();
    final got = <Uint8List>[];
    c.e2ee.onKey.listen(got.add);
    final key = Uint8List.fromList(List.filled(32, 7));
    c.e2ee.handleIncomingKeys(
      {
        'call_id': 'call-1',
        'keys': [
          {'index': 0, 'key': base64Encode(key)},
        ],
      },
      '@noemie:s',
    );
    await pumpEventQueue();
    expect(got.single, key);
  });

  test("call_id d'un autre appel → ignoré", () async {
    final c = _make(callId: 'le-nôtre');
    final got = <Uint8List>[];
    c.e2ee.onKey.listen(got.add);
    c.e2ee.handleIncomingKeys(
      {
        'call_id': 'appel-d-autre-chose',
        'keys': [
          {'index': 0, 'key': base64Encode(Uint8List(32))},
        ],
      },
      '@noemie:s',
    );
    await pumpEventQueue();
    expect(got, isEmpty);
  });

  test('contenu cassé → ignoré sans exception', () {
    final c = _make();
    for (final bad in [
      <String, Object?>{},
      {'call_id': 'call-1'},
      {
        'call_id': 'call-1',
        'keys': 'pasuneListe',
      },
      {
        'call_id': 'call-1',
        'keys': [{'index': 0}],
      },
    ]) {
      expect(
        () => c.e2ee.handleIncomingKeys(bad, '@x:y'),
        returnsNormally,
        reason: 'sur $bad',
      );
    }
  });

  test('aucun secret dans toString', () {
    final c = _make();
    expect(c.e2ee.toString(), isNot(contains(base64Encode(c.e2ee.passkey))));
  });
}
