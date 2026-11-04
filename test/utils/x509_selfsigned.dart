// ignore_for_file: depend_on_referenced_packages
// Générateur de certificats X.509 auto-signés **en mémoire**, utilisé par les
// tests TLS de link_preview. Auto-signé avec CA:TRUE, il sert aussi de racine
// de confiance : un pair présentant exactement ce DER se vérifie contre elle.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

class TestCert {
  const TestCert(this.certPem, this.keyPem, this.certBytes);

  final String certPem;
  final String keyPem;
  final Uint8List certBytes;
}

final _ipRe = RegExp(r'^\d+\.\d+\.\d+\.\d+$');

TestCert generateTestCert({
  required String commonName,
  List<String> dnsNames = const [],
}) {
  final rng = _rng();
  final kp = _generateRsaKeyPair(rng);
  final priv = kp.privateKey as RSAPrivateKey;
  final pub = kp.publicKey as RSAPublicKey;

  final name = _rn(commonName);
  final notBefore = DateTime.now().subtract(const Duration(hours: 1));
  final notAfter = DateTime.now().add(const Duration(days: 2));

  final spki = ASN1Sequence()
    ..add(_algIdRsaEncryption())
    ..add(
      ASN1BitString(
        _derSequence([
          ASN1Integer(pub.modulus!),
          ASN1Integer(pub.exponent!),
        ]),
      ),
    );

  final subjects = <String>{commonName, ...dnsNames};
  final sanSeq = ASN1Sequence();
  for (final entry in subjects) {
    if (_ipRe.hasMatch(entry)) {
      sanSeq.add(
        ASN1IpAddress(
          entry.split('.').map(int.parse).toList(),
          tag: 0x87, // [7] primitive : GeneralName iPAddress
        ),
      );
    } else {
      sanSeq.add(ASN1IA5String(entry, tag: 0x82)); // [2] dNSName
    }
  }

  final extensions = ASN1Sequence()
    ..add(
      ASN1Sequence()
        ..add(ASN1ObjectIdentifier.fromComponentString('2.5.29.19'))
        ..add(ASN1Boolean(true))
        ..add(ASN1OctetString(_derSequence([ASN1Boolean(true)]))), // CA:TRUE
    )
    ..add(
      ASN1Sequence()
        ..add(ASN1ObjectIdentifier.fromComponentString('2.5.29.17'))
        ..add(ASN1OctetString(sanSeq.encodedBytes)),
    );

  final tbs = ASN1Sequence()
    ..add(_explicitTag(0, ASN1Integer(BigInt.two).encodedBytes)) // v3
    ..add(ASN1Integer(BigInt.from(DateTime.now().millisecondsSinceEpoch)))
    ..add(_algIdSha256WithRsa())
    ..add(name)
    ..add(
      ASN1Sequence()
        ..add(ASN1UtcTime(notBefore.toUtc()))
        ..add(ASN1UtcTime(notAfter.toUtc())),
    )
    ..add(name) // issuer == subject (auto-signé)
    ..add(spki)
    ..add(_explicitTag(3, extensions.encodedBytes));

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(priv));
  final sig = signer.generateSignature(tbs.encodedBytes);

  final cert =
      ASN1Sequence()
        ..add(tbs)
        ..add(_algIdSha256WithRsa())
        ..add(ASN1BitString(sig.bytes));

  final der = cert.encodedBytes;
  final pkcs1 = _derSequence([
    ASN1Integer(BigInt.zero),
    ASN1Integer(priv.modulus!),
    // Attention : priv.exponent est un ALIAS de privateExponent chez
    // pointycastle — l'exposant PUBLIC vient de la clé publique.
    ASN1Integer(pub.exponent!),
    ASN1Integer(priv.privateExponent!),
    ASN1Integer(priv.p!),
    ASN1Integer(priv.q!),
    ASN1Integer(priv.d! % (priv.p! - BigInt.one)),
    ASN1Integer(priv.d! % (priv.q! - BigInt.one)),
    ASN1Integer(priv.q!.modInverse(priv.p!)),
  ]);
  // PKCS#8 PrivateKeyInfo (dart:io attend « BEGIN PRIVATE KEY ») :
  // SEQUENCE { version 0, AlgorithmIdentifier RSA, OCTET STRING PKCS#1 }
  final pkcs8 = _derSequence([
    ASN1Integer(BigInt.zero),
    _algIdRsaEncryption(),
    ASN1OctetString(pkcs1),
  ]);

  return TestCert(
    _pem('CERTIFICATE', der),
    _pem('PRIVATE KEY', pkcs8),
    Uint8List.fromList(der),
  );
}

SecureRandom _rng() {
  final rng = FortunaRandom();
  final source = Random.secure();
  final seed = Uint8List.fromList(
    List.generate(32, (_) => source.nextInt(256)),
  );
  rng.seed(KeyParameter(seed));
  return rng;
}

AsymmetricKeyPair<PublicKey, PrivateKey> _generateRsaKeyPair(SecureRandom rng) {
  final generator =
      RSAKeyGenerator()
        ..init(
          ParametersWithRandom(
            RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
            rng,
          ),
        );
  return generator.generateKeyPair();
}

ASN1Sequence _rn(String cn) =>
    ASN1Sequence()
      ..add(
        ASN1Set()
          ..add(
            ASN1Sequence()
              ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
              ..add(ASN1UTF8String(cn)),
          ),
      );

ASN1Sequence _algIdSha256WithRsa() =>
    ASN1Sequence()
      ..add(
        ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'),
      )
      ..add(ASN1Null());

ASN1Sequence _algIdRsaEncryption() =>
    ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());

/// [index] EXPLICIT, construit (context 0x80 | constructed 0x20 | n).
ASN1Object _explicitTag(int index, Uint8List inner) =>
    ASN1Object.preEncoded(0xa0 | index, inner);

Uint8List _derTlv(int tag, Uint8List value) {
  final lenBytes = _derLength(value.length);
  final out = Uint8List(1 + lenBytes.length + value.length);
  out[0] = tag;
  out.setRange(1, 1 + lenBytes.length, lenBytes);
  out.setRange(1 + lenBytes.length, out.length, value);
  return out;
}

Uint8List _derLength(int length) {
  if (length < 128) return Uint8List.fromList([length]);
  final bytes = <int>[];
  var v = length;
  while (v > 0) {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _derSequence(List<ASN1Object> elements) {
  final body = BytesBuilder();
  for (final e in elements) {
    body.add(e.encodedBytes);
  }
  return _derTlv(0x30, body.toBytes());
}

String _pem(String label, Uint8List der) {
  final b64 = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}
