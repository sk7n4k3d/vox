import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/webhook/webhook_event.dart';
import 'package:fluffychat/utils/webhook/webhook_queue.dart';
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
/// Un échec n'est pas perdu : si l'option est active, le corps brut part dans
/// [WebhookQueue] et sera réessayé (backoff, plafond de tentatives, TTL).
class WebhookService {
  WebhookService._();
  static final WebhookService instance = WebhookService._();

  static const Duration _timeout = Duration(seconds: 10);

  final ValueNotifier<WebhookStats> stats = ValueNotifier(const WebhookStats());

  /// Rooms Matrix cochées, mises en cache (le filtre est consulté à chaque
  /// message). Invalidé par [invalidateFilters] quand les réglages changent.
  Set<String>? _allowedRooms;

  /// Rooms Matrix explicitement décochées.
  Set<String>? _excludedRooms;

  /// Fils SMS/MMS cochés, même principe.
  Set<String>? _allowedSmsThreads;

  /// Fils SMS/MMS explicitement décochés.
  Set<String>? _excludedSmsThreads;

  Future<Set<String>> allowedRooms() async =>
      _allowedRooms ??= await WebhookStore.instance.loadRooms();

  Future<Set<String>> excludedRooms() async =>
      _excludedRooms ??= await WebhookStore.instance.loadExcludedRooms();

  Future<Set<String>> allowedSmsThreads() async =>
      _allowedSmsThreads ??= await WebhookStore.instance.loadSmsThreads();

  Future<Set<String>> excludedSmsThreads() async =>
      _excludedSmsThreads ??=
          await WebhookStore.instance.loadExcludedSmsThreads();

  void invalidateFilters() {
    _allowedRooms = null;
    _excludedRooms = null;
    _allowedSmsThreads = null;
    _excludedSmsThreads = null;
  }

  /// Rien ne part tant que l'interrupteur est off ou que l'URL est vide.
  bool get isConfigured =>
      AppSettings.webhookEnabled.value &&
      AppSettings.webhookUrl.value.trim().isNotEmpty;

  /// Tout envoyer (nouvelles conversations comprises) plutôt que la liste
  /// cochée. Lu à chaque message, sans cache : c'est un simple booléen.
  bool get smsAll => AppSettings.webhookSmsAll.value;
  bool get matrixAll => AppSettings.webhookMatrixAll.value;

  /// Défaut pour une conversation jamais décidée : envoyée sans être cochée.
  bool get smsNewDefault => AppSettings.webhookSmsNew.value;
  bool get matrixNewDefault => AppSettings.webhookMatrixNew.value;

  Future<void> dispatch(WebhookEvent event) async {
    if (!isConfigured) return;
    final rawBody = jsonEncode(event.toJson());
    final ok = await postRaw(rawBody);
    if (!ok && AppSettings.webhookRetryEnabled.value) {
      await WebhookQueue.instance.add(rawBody);
    }
  }

  /// POST signé d'un corps **déjà sérialisé** (le dispatch direct, comme les
  /// réessais de la file). Re-signe à chaque appel : l'horodatage fait partie de
  /// la signature HMAC V2, on ne peut donc pas rejouer la signature d'origine.
  /// @return true si le serveur a répondu 2xx.
  Future<bool> postRaw(String rawBody) async {
    final uri = Uri.tryParse(AppSettings.webhookUrl.value.trim());
    if (uri == null || !uri.hasScheme) return false;

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
        return true;
      }
      stats.value = stats.value.failed1('HTTP ${response.statusCode}');
      debugPrint('WebhookService: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      stats.value = stats.value.failed1('$e');
      debugPrint('WebhookService: envoi échoué: $e');
      return false;
    }
  }

  /// Envoie un événement de test, pour vérifier le câblage côté Hermes — texte
  /// **et** média (un PNG d'un pixel), histoire de valider toute la chaîne
  /// base64, pas seulement le POST.
  Future<void> sendTest() {
    final bytes = base64Decode(_testPngBase64);
    return dispatch(
      WebhookEvent(
        source: WebhookSource.sms,
        eventId: 'test-${DateTime.now().millisecondsSinceEpoch}',
        outgoing: false,
        timestamp: DateTime.now(),
        sender: '+33000000000',
        senderName: 'VOX (test)',
        body: 'Test du webhook VOX',
        media: [
          WebhookMedia(
            mimeType: 'image/png',
            fileName: 'vox-test.png',
            size: bytes.length,
            dataB64: _testPngBase64,
          ),
        ],
      ),
    );
  }
}

/// PNG 1×1 transparent — le média du bouton de test, pour prouver que les octets
/// arrivent bien jusqu'au disque de Hermes.
const String _testPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
