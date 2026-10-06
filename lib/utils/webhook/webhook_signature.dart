import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Signature générique V2 attendue par la plateforme `webhook` de Hermes
/// (`gateway/platforms/webhook.py`) : hex HMAC-SHA256 de `"<timestamp>.<corps>"`.
///
/// À envoyer avec le corps **brut** dans `X-Webhook-Signature-V2`, et
/// l'horodatage epoch (secondes) dans `X-Webhook-Timestamp`. Hermes refuse un
/// timestamp manquant ou hors de sa fenêtre anti-replay (300 s).
String webhookSignatureV2({
  required String secret,
  required String timestamp,
  required String rawBody,
}) =>
    Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode('$timestamp.$rawBody'))
        .toString();
