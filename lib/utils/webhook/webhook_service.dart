import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_signature.dart';
import 'package:fluffychat/utils/webhook/webhook_store.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Compteurs affichés sur la page de réglages.
@immutable
class WebhookStats {
  const WebhookStats({this.sent = 0, this.failed = 0, this.lastError});

  final int sent;
  final int failed;
  final String? lastError;

  WebhookStats sent1() => WebhookStats(sent: sent + 1, failed: failed);
  WebhookStats failed1(String error) =>
      WebhookStats(sent: sent, failed: failed + 1, lastError: error);
}

/// Pousse chaque message vers l'URL configurée, signé en HMAC V2 comme la
/// plateforme `webhook` de Hermes l'exige.
///
/// v1 : un tir par message, pas de file d'attente ni de retry — un échec est
/// compté et loggé, jamais rejoué.
class WebhookService {
  WebhookService._();
  static final WebhookService instance = WebhookService._();

  static const Duration _timeout = Duration(seconds: 10);

  final ValueNotifier<WebhookStats> stats = ValueNotifier(const WebhookStats());

  /// Rooms Matrix autorisées, mises en cache (le filtre est consulté à chaque
  /// message). Invalidé par [invalidateFilters] quand les réglages changent.
  Set<String>? _allowedRooms;

  /// Fils SMS/MMS autorisés, même principe.
  Set<String>? _allowedSmsThreads;

  Future<Set<String>> allowedRooms() async =>
      _allowedRooms ??= await WebhookStore.instance.loadRooms();

  Future<Set<String>> allowedSmsThreads() async =>
      _allowedSmsThreads ??= await WebhookStore.instance.loadSmsThreads();

  void invalidateFilters() {
    _allowedRooms = null;
    _allowedSmsThreads = null;
  }

  /// Rien ne part tant que l'interrupteur est off ou que l'URL est vide.
  bool get isConfigured =>
      AppSettings.webhookEnabled.value &&
      AppSettings.webhookUrl.value.trim().isNotEmpty;

  /// Tout envoyer (nouvelles conversations comprises) plutôt que la liste
  /// cochée. Lu à chaque message, sans cache : c'est un simple booléen.
  bool get smsAll => AppSettings.webhookSmsAll.value;
  bool get matrixAll => AppSettings.webhookMatrixAll.value;

  Future<void> dispatch(WebhookEvent event) async {
    if (!isConfigured) return;
    final uri = Uri.tryParse(AppSettings.webhookUrl.value.trim());
    if (uri == null || !uri.hasScheme) return;

    final rawBody = jsonEncode(event.toJson());
    final timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final secret = await WebhookStore.instance.loadSecret();

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Webhook-Timestamp': timestamp,
      if (secret.isNotEmpty)
        'X-Webhook-Signature-V2': webhookSignatureV2(
          secret: secret,
          timestamp: timestamp,
          rawBody: rawBody,
        ),
    };

    try {
      final response = await http
          .post(uri, headers: headers, body: rawBody)
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        stats.value = stats.value.sent1();
      } else {
        stats.value = stats.value.failed1('HTTP ${response.statusCode}');
        debugPrint('WebhookService: HTTP ${response.statusCode}');
      }
    } catch (e) {
      stats.value = stats.value.failed1('$e');
      debugPrint('WebhookService: envoi échoué: $e');
    }
  }

  /// Envoie un événement de test, pour vérifier le câblage côté Hermes.
  Future<void> sendTest() => dispatch(
        WebhookEvent(
          source: WebhookSource.sms,
          eventId: 'test-${DateTime.now().millisecondsSinceEpoch}',
          outgoing: false,
          timestamp: DateTime.now(),
          sender: '+33000000000',
          senderName: 'VOX (test)',
          body: 'Test du webhook VOX',
        ),
      );
}
