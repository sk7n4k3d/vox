import 'dart:async';
import 'dart:io';

import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _public = [InternetAddress('93.184.216.34')];

LinkPreviewService _svc({
  required List<String> visited,
  http.Response Function(http.Request request)? handler,
  Map<String, List<InternetAddress>> dns = const {},
  Duration? timeout,
}) => LinkPreviewService.forTesting(
  timeoutOverride: timeout,
  lookup: (host) async => dns[host] ?? (_public.map((a) => a).toList()),
  newClient: (addresses) => MockClient((request) async {
    visited.add(request.url.toString());
    if (handler == null) {
      return http.Response(
        '<html><head><meta property="og:title" content="OK"></head></html>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    return handler(request);
  }),
);

void main() {
  group('isBlockedPreviewHost — littéraux interdits', () {
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

    test(
      'gaps IPv6 relevés par l audit (v4-compat, NAT64, Teredo, 6to4, mc)',
      () {
        expect(isBlockedPreviewHost('::ffff:0:127.0.0.1'), isTrue);
        expect(
          isBlockedPreviewHost('::127.0.0.1'),
          isTrue,
        ); // v4-compat déprécié
        expect(isBlockedPreviewHost('::10.0.0.1'), isTrue); // v4-compat privé
        expect(isBlockedPreviewHost('64:ff9b::127.0.0.1'), isTrue); // NAT64
        expect(isBlockedPreviewHost('2001::1'), isTrue); // Teredo
        expect(isBlockedPreviewHost('2002:7f00:1::'), isTrue); // 6to4
        expect(isBlockedPreviewHost('ff02::1'), isTrue); // multicast v6
        expect(isBlockedPreviewHost('100::1'), isTrue); // discard
      },
    );

    test('écritures numériques et hexadécimales d une IP', () {
      expect(isBlockedPreviewHost('2130706433'), isTrue); // = 127.0.0.1
      expect(isBlockedPreviewHost('0x7f000001'), isTrue);
      expect(isBlockedPreviewHost('localhost'), isTrue);
      expect(isBlockedPreviewHost('foo.localhost'), isTrue);
    });

    test('le domaine et l IP publics passent (pas de sur-blocage)', () {
      expect(isBlockedPreviewHost('example.com'), isFalse);
      expect(isBlockedPreviewHost('10.evil.example'), isFalse);
      expect(isBlockedPreviewHost('8.8.8.8'), isFalse);
      expect(isBlockedPreviewHost('172.32.0.1'), isFalse);
      expect(isBlockedPreviewHost('::ffff:8.8.8.8'), isFalse);
      expect(isBlockedPreviewHost('2001:db8::1'), isFalse);
      expect(isBlockedPreviewHost('64:ff9b::8.8.8.8'), isFalse);
      expect(isBlockedPreviewHost('2606:4700::1'), isFalse);
      expect(isBlockedPreviewHost('2001:67c::1'), isFalse); // RIPE public
    });
  });

  group('résolution DNS — le verrou porte sur l adresse dialée', () {
    test(
      'un domaine qui résout en 127.0.0.1 est rejeté sans connexion',
      () async {
        final visited = <String>[];
        final svc = _svc(
          visited: visited,
          dns: {
            'evil.example': [InternetAddress('127.0.0.1')],
          },
        );
        expect(await svc.fetch('http://evil.example/x'), isNull);
        expect(
          visited,
          isEmpty,
          reason: 'le nom A→127.0.0.1 ne doit JAMAIS être demandé',
        );
      },
    );

    test('un domaine qui résout en LAN interne est rejeté', () async {
      final visited = <String>[];
      final svc = _svc(
        visited: visited,
        dns: {
          'nas.example': [InternetAddress('10.8.0.10')],
        },
      );
      expect(await svc.fetch('http://nas.example/api'), isNull);
      expect(visited, isEmpty);
    });

    test(
      'une réponse publique mélangée à une réponse interne est rejetée',
      () async {
        final visited = <String>[];
        final svc = _svc(
          visited: visited,
          dns: {
            'split.example': [
              InternetAddress('93.184.216.34'),
              InternetAddress('169.254.169.254'),
            ],
          },
        );
        expect(await svc.fetch('http://split.example/x'), isNull);
        expect(visited, isEmpty);
      },
    );

    test('une redirection 302 vers un nom interne est coupée', () async {
      final visited = <String>[];
      final svc = _svc(
        visited: visited,
        dns: {
          'homeassistant.local': [InternetAddress('10.8.0.20')],
        },
        handler: (request) => request.url.host == 'public.example'
            ? http.Response(
                '',
                302,
                headers: {'location': 'http://homeassistant.local:8123/api'},
              )
            : http.Response('<html>interne</html>', 200),
      );
      expect(await svc.fetch('https://public.example/x'), isNull);
      expect(visited, contains('https://public.example/x'));
      expect(visited.any((u) => u.contains('homeassistant.local')), isFalse);
    });

    test('une redirection littérale vers 127.0.0.1 est coupée', () async {
      final visited = <String>[];
      final svc = _svc(
        visited: visited,
        handler: (request) => request.url.host == 'public.example'
            ? http.Response(
                '',
                302,
                headers: {'location': 'http://127.0.0.1/secret'},
              )
            : http.Response('<html>interne</html>', 200),
      );
      expect(await svc.fetch('https://public.example/x'), isNull);
      expect(visited.length, 1);
    });

    test('le domaine public résolu et validé est chargé normalement', () async {
      final visited = <String>[];
      final svc = _svc(visited: visited);
      final data = await svc.fetch('https://example.com/article');
      expect(data?.title, 'OK');
      expect(visited.length, 1);
    });
  });

  group('miniatures — plus de contournement par Image.network', () {
    test('une og:image vers la boucle locale ne part pas', () async {
      final visited = <String>[];
      final svc = _svc(visited: visited);
      expect(
        await svc.fetchImage('http://127.0.0.1:8080/x.png'),
        isNull,
        reason: 'schéma http et cible interne refusés, sans requête',
      );
      expect(visited, isEmpty);
    });

    test('une vignette interne en littéral IPv6 mappé est refusée', () async {
      final visited = <String>[];
      final svc = _svc(visited: visited);
      expect(await svc.fetchImage('https://[::ffff:127.0.0.1]/x.png'), isNull);
      expect(visited, isEmpty);
    });

    test('une og:image dont le nom résout en interne est refusée', () async {
      final visited = <String>[];
      final svc = _svc(
        visited: visited,
        dns: {
          'img.internal-cdn.example': [InternetAddress('192.168.1.1')],
        },
      );
      expect(
        await svc.fetchImage('https://img.internal-cdn.example/a.jpg'),
        isNull,
      );
      expect(visited, isEmpty);
    });

    test(
      'une vignette publique avec content-type image est renvoyée',
      () async {
        final visited = <String>[];
        final svc = _svc(
          visited: visited,
          handler: (request) => http.Response.bytes(
            [0x89, 0x50, 0x4e, 0x47],
            200,
            headers: {'content-type': 'image/png'},
          ),
        );
        final bytes = await svc.fetchImage('https://cdn.example/a.png');
        expect(bytes, [0x89, 0x50, 0x4e, 0x47]);
        expect(visited.length, 1);
      },
    );

    test('une réponse non-image n est pas une vignette', () async {
      final visited = <String>[];
      final svc = _svc(visited: visited);
      expect(await svc.fetchImage('https://cdn.example/x.html'), isNull);
    });
  });

  group('délais — plus de Future éternel', () {
    test(
      'un corps qui ne finit jamais est abandonné (deadline globale)',
      () async {
        final svc = LinkPreviewService.forTesting(
          timeoutOverride: const Duration(milliseconds: 50),
          lookup: (_) async => _public,
          newClient: (addresses) => MockClient.streaming((request, _) async {
            return http.StreamedResponse(
              StreamController<List<int>>().stream,
              200,
              headers: {'content-type': 'text/html'},
              request: request,
            );
          }),
        );
        final data = await svc
            .fetch('https://slow.example/x')
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('fetch suspendu malgré la deadline'),
            );
        expect(data, isNull);
      },
    );

    test('une boucle de redirections finit par s arrêter', () async {
      final visited = <String>[];
      final svc = _svc(
        visited: visited,
        timeout: const Duration(milliseconds: 50),
        handler: (request) => http.Response(
          '',
          302,
          headers: {'location': 'https://loop.example/next'},
        ),
      );
      final data = await svc
          .fetch('https://loop.example/x')
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('la boucle de redirections ne termine pas'),
          );
      expect(data, isNull);
      expect(visited.length, lessThanOrEqualTo(7));
    });
  });
}
