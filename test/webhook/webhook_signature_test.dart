import 'package:fluffychat/utils/webhook/webhook_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('webhookSignatureV2', () {
    // Vecteur de reference calcule hors Dart :
    //   hex(hmac_sha256("sk7-test-secret", "1791308830.<body>"))
    // S'il casse, la signature ne correspond plus a ce que Hermes valide
    // (gateway/platforms/webhook.py, generic HMAC V2).
    test('signe "<timestamp>.<corps>" comme Hermes l attend', () {
      expect(
        webhookSignatureV2(
          secret: 'sk7-test-secret',
          timestamp: '1791308830',
          rawBody: '{"source":"sms","event_id":"42","body":"hello"}',
        ),
        '0cbb95465ac1a42741f514bae3cd289ed0268d8037058cc59ce45ccd01ecd15b',
      );
    });

    test('le corps entre dans la signature (pas seulement le timestamp)', () {
      final a = webhookSignatureV2(
        secret: 's',
        timestamp: '1',
        rawBody: '{"a":1}',
      );
      final b = webhookSignatureV2(
        secret: 's',
        timestamp: '1',
        rawBody: '{"a":2}',
      );
      expect(a, isNot(b));
    });

    test('change si le secret change', () {
      final a = webhookSignatureV2(secret: 'a', timestamp: '1', rawBody: 'x');
      final b = webhookSignatureV2(secret: 'b', timestamp: '1', rawBody: 'x');
      expect(a, isNot(b));
    });

    test('produit 64 caracteres hexadecimaux', () {
      final sig = webhookSignatureV2(secret: 's', timestamp: '1', rawBody: 'x');
      expect(sig, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
