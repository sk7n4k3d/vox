import 'dart:convert';

import 'package:fluffychat/utils/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

LlmClient _client(MockClient mock, {String apiKey = 'secret'}) => LlmClient(
  baseUrl: 'https://llm.example/v1',
  apiKey: apiKey,
  model: 'm',
  httpClient: mock,
);

http.Response _ok(Map<String, dynamic> message) => http.Response(
  jsonEncode({
    'choices': [
      {'message': message},
    ],
  }),
  200,
);

void main() {
  test(
    'retries without chat_template_kwargs when the server answers 400',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        if (body.containsKey('chat_template_kwargs')) {
          return http.Response('unknown parameter', 400);
        }
        return _ok({'content': 'Resume.'});
      });

      expect(await _client(mock).chat(const []), 'Resume.');
      expect(bodies, hasLength(2));
      expect(bodies.last.containsKey('chat_template_kwargs'), isFalse);
    },
  );

  test('never returns the raw reasoning as the answer', () async {
    final mock = MockClient(
      (_) async => _ok({'content': '', 'reasoning_content': 'Je pense que…'}),
    );
    await expectLater(
      _client(mock).chat(const []),
      throwsA(isA<LlmException>()),
    );
  });

  test('omits Authorization when no API key is set', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return _ok({'content': 'ok'});
    });
    await _client(mock, apiKey: '').chat(const []);
    expect(captured.headers.containsKey('Authorization'), isFalse);
  });
}
