import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:http/http.dart' as http;

/// Erreur utilisateur d'un appel au client LLM — le message est prêt à être
/// affiché en français (déjà localisé, sans jargon).
class LlmException implements Exception {
  final String message;

  const LlmException(this.message);

  @override
  String toString() => message;
}

/// Modèle annoncé par `GET /v1/models`.
class LlmModelInfo {
  final String id;

  const LlmModelInfo(this.id);
}

/// Client minimal pour un endpoint OpenAI-compatible (`/v1/chat/completions`
/// et `/v1/models`). Aucune dépendance au SDK Matrix : utilisable depuis toute
/// page (chat Matrix, conversation SMS, réglages).
class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final http.Client _http;

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client();

  /// Construit un client depuis les réglages persistés.
  factory LlmClient.fromSettings({http.Client? httpClient}) => LlmClient(
    baseUrl: AppSettings.llmBaseUrl.value,
    apiKey: AppSettings.llmApiKey.value,
    model: AppSettings.llmModel.value,
    httpClient: httpClient,
  );

  Uri _endpoint(String path) {
    final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$normalized/$path');
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json; charset=utf-8',
    if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
  };

  /// `GET /models` — sert au bouton « Tester la connexion ».
  Future<List<LlmModelInfo>> fetchModels() async {
    final response = await _withTimeout(
      () => _http.get(_endpoint('models'), headers: _headers),
    );
    if (response.statusCode != 200) _throwForStatus(response);
    final decoded = _decodeBody(response);
    final data = decoded['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((m) => LlmModelInfo('${m['id'] ?? ''}'.trim()))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  /// `POST /chat/completions` — renvoie le contenu du premier choix.
  Future<String> chat(
    List<Map<String, String>> messages, {
    int maxTokens = 1024,
    double temperature = 0.4,
  }) async {
    final response = await _withTimeout(
      () => _http.post(
        _endpoint('chat/completions'),
        headers: _headers,
        body: jsonEncode({
          'model': model.trim().isEmpty ? 'qwen3.5-titan1-16x' : model.trim(),
          'messages': messages,
          'max_tokens': maxTokens,
          'temperature': temperature,
        }),
      ),
    );
    if (response.statusCode != 200) _throwForStatus(response);
    final decoded = _decodeBody(response);
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map)['message'];
      if (message is Map) {
        final content = message['content'];
        if (content is String && content.trim().isNotEmpty) {
          return content.trim();
        }
      }
    }
    throw const LlmException('Réponse vide du serveur');
  }

  Future<http.Response> _withTimeout(
    Future<http.Response> Function() send,
  ) async {
    try {
      return await send().timeout(timeout);
    } on TimeoutException {
      throw const LlmException('Serveur injoignable (délai dépassé)');
    } on LlmException {
      rethrow;
    } catch (_) {
      throw const LlmException('Serveur injoignable');
    }
  }

  Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return const {};
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Fall through to the generic error below.
    }
    throw const LlmException('Réponse illisible du serveur');
  }

  Never _throwForStatus(http.Response response) {
    switch (response.statusCode) {
      case 400:
        throw const LlmException('Requête refusée par le serveur');
      case 401:
        throw const LlmException('Clé API invalide');
      case 403:
        throw const LlmException('Accès refusé par le serveur');
      case 404:
        throw const LlmException('Endpoint introuvable (vérifie l\'URL)');
      case 429:
        throw const LlmException('Trop de requêtes — réessaie plus tard');
      default:
        if (response.statusCode >= 500) {
          throw LlmException('Erreur serveur (${response.statusCode})');
        }
        throw LlmException('Erreur HTTP ${response.statusCode}');
    }
  }
}
