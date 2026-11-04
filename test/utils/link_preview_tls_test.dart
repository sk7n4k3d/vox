// Non-régression F1 (audit 2026-11-04) : le client épinglé doit établir un
// VRAI TLS vers l'adresse jugée, avec SNI + vérification sur le nom d'origine
// — et ne jamais retomber en clair. Les tests MockClient ne voyaient jamais ce
// chemin (socket réelle inexistante) ; ceux-ci montent de vrais serveurs
// localhost, avec des certificats générés en mémoire.

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/x509_selfsigned.dart';

final _good = generateTestCert(
  commonName: 'preview.test',
  dnsNames: ['preview.test', 'localhost'],
);
final _other = generateTestCert(
  commonName: 'other.test',
  dnsNames: ['other.test'],
);

SecurityContext _serverContext(TestCert cert) => SecurityContext()
  // dart:io attend du PEM dans les variantes *Bytes, pas le DER brut.
  ..useCertificateChainBytes(latin1.encode(cert.certPem))
  ..usePrivateKeyBytes(latin1.encode(cert.keyPem));

SecurityContext _clientTrusting(TestCert root) =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(latin1.encode(root.certPem));

const _ogHtml =
    '<html><head><meta property="og:title" content="Titre TLS"></head></html>';

Future<HttpServer> _httpsServer(TestCert cert, {String body = _ogHtml}) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    _serverContext(cert),
  );
  server.listen((request) async {
    // bindSecure : n'accepte que des poignées de main TLS — une requête en
    // clair ne peut pas être servie, ce qui est précisément la preuve
    // recherchée.
    request.response
      ..headers.contentType = ContentType('text', 'html')
      ..write(body);
    await request.response.close();
  });
  return server;
}

Future<HttpServer> _plainServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..headers.contentType = ContentType('text', 'html')
      ..write(_ogHtml);
    await request.response.close();
  });
  return server;
}

void main() {
  // Ces tests montent de vrais serveurs TLS/HTTP loopback : ils exigent un
  // HttpClient réel (hors binding flutter_test, sinon HttpOverrides le moque).
  setUpAll(() => HttpOverrides.global = null);

  test('https épinglé établit un vrai TLS (200, corps html, client TLS)',
    () async {
      final server = await _httpsServer(_good);
      addTearDown(server.close);
      final client = LinkPreviewService.pinningClientForTesting(
        [InternetAddress.loopbackIPv4], // l'adresse épinglée = celle du serveur
        trustedRootsOverride: _clientTrusting(_good),
      );
      addTearDown(client.close);

      final response = await client.get(
        Uri.parse('https://preview.test:${server.port}/og'),
      );
      expect(response.statusCode, 200);
      // le corps ne sort QUE si le chiffrement a réussi : un serveur TLS ne
      // sert jamais du clair.
      expect(response.body, contains('Titre TLS'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('la socket épinglée est bien chiffrée : un serveur clair la refuse',
    () async {
      final plain = await _plainServer();
      addTearDown(plain.close);
      final client = LinkPreviewService.pinningClientForTesting(
        [InternetAddress.loopbackIPv4],
        trustedRootsOverride: _clientTrusting(_good),
      );
      addTearDown(client.close);

      // https vers un serveur HTTP clair : l'escalade TLS échoue, AUCUNE
      // donnée applicative ne transite (c'était la régression F1).
      await expectLater(
        client.get(Uri.parse('https://preview.test:${plain.port}/og')),
        throwsA(anything),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('certificat non inspiré est rejeté (pas de onBadCertificate laxiste)',
    () async {
      final server = await _httpsServer(_other);
      addTearDown(server.close);
      // racine de confiance : le BON certificat ; le serveur présente l'autre
      // (other.test, non-signataire de cette racine).
      final client = LinkPreviewService.pinningClientForTesting(
        [InternetAddress.loopbackIPv4],
        trustedRootsOverride: _clientTrusting(_good),
      );
      addTearDown(client.close);

      await expectLater(
        client.get(Uri.parse('https://preview.test:${server.port}/og')),
        throwsA(anything),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('certificat au mauvais nom est rejeté malgré la racine qui le signe',
    () async {
      final server = await _httpsServer(_other);
      addTearDown(server.close);
      final client = LinkPreviewService.pinningClientForTesting(
        [InternetAddress.loopbackIPv4],
        trustedRootsOverride: _clientTrusting(_other),
      );
      addTearDown(client.close);

      // racine OK, mais le certificat présente CN=other.test et le client
      // demande preview.test : la vérification de NOM (pas seulement chaîne)
      // doit échouer.
      await expectLater(
        client.get(Uri.parse('https://preview.test:${server.port}/og')),
        throwsA(anything),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('http simple garde le chemin épinglé non-TLS fonctionnel', () async {
    final server = await _plainServer();
    addTearDown(server.close);
    final client = LinkPreviewService.pinningClientForTesting(
      [InternetAddress.loopbackIPv4],
    );
    addTearDown(client.close);

    final response = await client.get(
      Uri.parse('http://preview.test:${server.port}/og'),
    );
    expect(response.statusCode, 200);
    expect(response.body, contains('Titre TLS'));
  });
}
