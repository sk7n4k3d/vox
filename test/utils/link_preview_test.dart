import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('isBlockedPreviewHost — littéraux interdits', () {
    // Les formes que l'ancienne règle laissait passer (boucle locale atteignable
    // depuis un lien reçu par SMS).
    test('IPv4 mappé en IPv6, toutes les boucles', () {
      expect(isBlockedPreviewHost('::ffff:127.0.0.1'), isTrue);
      expect(isBlockedPreviewHost('::ffff:10.0.0.1'), isTrue);
      expect(isBlockedPreviewHost('::1'), isTrue);
      expect(isBlockedPreviewHost('0.0.0.0'), isTrue);
      expect(isBlockedPreviewHost('0.1.2.3'), isTrue);
    });

    test('plages privées, CGNAT, link-local, ULA', () {
      expect(isBlockedPreviewHost('127.5.5.5'), isTrue);
      expect(isBlockedPreviewHost('10.1.2.3'), isTrue);
      expect(isBlockedPreviewHost('192.168.0.1'), isTrue);
      expect(isBlockedPreviewHost('172.16.0.1'), isTrue);
      expect(isBlockedPreviewHost('172.31.255.255'), isTrue);
      expect(isBlockedPreviewHost('169.254.169.254'), isTrue); // cloud metadata
      expect(isBlockedPreviewHost('100.64.0.1'), isTrue);
      expect(isBlockedPreviewHost('fe80::1'), isTrue);
      expect(isBlockedPreviewHost('fd00::1'), isTrue);
      expect(isBlockedPreviewHost('::'), isTrue);
      expect(isBlockedPreviewHost('224.0.0.1'), isTrue);
    });

    test('écritures numériques et hexadécimales d une IP', () {
      expect(isBlockedPreviewHost('2130706433'), isTrue); // = 127.0.0.1
      expect(isBlockedPreviewHost('0x7f000001'), isTrue);
      expect(isBlockedPreviewHost('localhost'), isTrue);
      expect(isBlockedPreviewHost('foo.localhost'), isTrue);
    });

    test('le domaine public passe (et « 10.evil.com » n est plus banni)', () {
      expect(isBlockedPreviewHost('example.com'), isFalse);
      expect(isBlockedPreviewHost('10.evil.example'), isFalse);
      expect(isBlockedPreviewHost('8.8.8.8'), isFalse);
      expect(isBlockedPreviewHost('172.32.0.1'), isFalse);
      expect(isBlockedPreviewHost('::ffff:8.8.8.8'), isFalse);
      expect(isBlockedPreviewHost('2001:db8::1'), isFalse);
    });
  });

  group('redirections — pas de passe-droit vers le réseau local', () {
    test('une 302 vers 127.0.0.1 ne sort rien et ne télécharge pas', () async {
      final visited = <String>[];
      final svc = LinkPreviewService.forTesting(
        () => MockClient((request) async {
          visited.add(request.url.host);
          if (request.url.host == 'public.example') {
            return http.Response('', 302,
                headers: {'location': 'http://127.0.0.1/secret'});
          }
          return http.Response(
            '<html><head><meta property="og:title" content="interne"></head></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        }),
      );

      final data = await svc.fetch('https://public.example/article');
      expect(data, isNull);
      expect(visited, ['public.example'],
          reason: 'la cible interne ne doit jamais être requêtée');
    });

    test('une chaîne de redirections entre hôtes publics est suivie',
        () async {
      final svc = LinkPreviewService.forTesting(
        () => MockClient((request) async {
          switch (request.url.host) {
            case 'short.example':
              return http.Response('', 301,
                  headers: {'location': 'https://mid.example/a'});
            case 'mid.example':
              return http.Response('', 302,
                  headers: {'location': 'https://final.example/page'});
            default:
              return http.Response(
                '<html><head><meta property="og:title" content="Bien"></head></html>',
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              );
          }
        }),
      );

      final data = await svc.fetch('https://short.example/x');
      expect(data?.title, 'Bien');
    });

    test('une redirection hors http (file://) est coupée', () async {
      final svc = LinkPreviewService.forTesting(
        () => MockClient((request) async {
          if (request.url.host == 'evil.example') {
            return http.Response('', 302,
                headers: {'location': 'file:///etc/passwd'});
          }
          return http.Response('jamais', 200);
        }),
      );
      final data = await svc.fetch('https://evil.example/x');
      expect(data, isNull);
    });
  });
}
