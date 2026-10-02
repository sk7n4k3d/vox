import 'dart:convert';

import 'package:fluffychat/utils/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

LlmClient _client(MockClient mock) => LlmClient(
  baseUrl: 'https://llm.example/v1',
  apiKey: 'secret',
  model: 'qwen3.5-titan1-16x',
  httpClient: mock,
);

void main() {
  group('LlmClient.fetchModels', () {
    test('parses model ids and sends bearer auth', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'qwen3.5-titan1-16x'},
              {'id': 'ornith1.5-titan1-4x'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final models = await _client(mock).fetchModels();

      expect(models.map((m) => m.id), [
        'qwen3.5-titan1-16x',
        'ornith1.5-titan1-4x',
      ]);
      expect(captured.url.toString(), 'https://llm.example/v1/models');
      expect(captured.headers['Authorization'], 'Bearer secret');
    });

    test('maps 401 to a clean French error', () async {
      final mock = MockClient((_) async => http.Response('nope', 401));
      await expectLater(
        _client(mock).fetchModels(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            'Clé API invalide',
          ),
        ),
      );
    });
  });

  group('LlmClient.chat', () {
    test('returns the first choice content', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Bonjour.'},
              },
            ],
          }),
          200,
        );
      });

      final content = await _client(mock).chat([
        {'role': 'user', 'content': 'salut'},
      ]);

      expect(content, 'Bonjour.');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], 'qwen3.5-titan1-16x');
      expect(body['messages'], [
        {'role': 'user', 'content': 'salut'},
      ]);
    });

    test('times out with a French message', () async {
      final mock = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      });
      final client = LlmClient(
        baseUrl: 'https://llm.example/v1',
        apiKey: 'secret',
        model: 'm',
        httpClient: mock,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.chat(const []),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            'Serveur injoignable (délai dépassé)',
          ),
        ),
      );
    });

    test('empty choices raises Réponse vide', () async {
      final mock = MockClient(
        (_) async => http.Response(jsonEncode({'choices': []}), 200),
      );
      await expectLater(
        _client(mock).chat(const []),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            'Réponse vide du serveur',
          ),
        ),
      );
    });
  });
}
