import 'dart:convert';

import 'package:fluffychat/utils/rtc/rtc_sfu_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Transport de test : enregistre les requêtes et répond selon une table.
class _Recorder {
  final List<http.Request> requests = [];
  Future<http.Response> Function(http.Request request)? handler;

  RtcJsonGet get get => (uri) async {
        final req = http.Request('GET', uri);
        requests.add(req);
        final res = await handler!(req);
        return jsonDecode(res.body) as Map<String, Object?>;
      };

  RtcJsonPost get post => (uri, body) async {
        final req = http.Request('POST', uri)..body = jsonEncode(body);
        requests.add(req);
        final res = await handler!(req);
        return jsonDecode(res.body) as Map<String, Object?>;
      };
}

RtcSfuClient _client(_Recorder rec) => RtcSfuClient(
      homeserver: Uri.parse('https://matrix.sk7.sh'),
      userId: '@hermes:matrix.sk7.sh',
      deviceId: 'DEVSPICE',
      plainGet: rec.get,
      openidToken: () async => {
        'access_token': 'oid-token',
        'token_type': 'Bearer',
        'matrix_server_name': 'matrix.sk7.sh',
        'expires_in': 3600,
      },
      plainPost: rec.post,
    );

/// Fixture réelle servie par matrix.sk7.sh le 2026-10-15.
const _wellKnown =
    '{"m.homeserver":{"base_url":"https://matrix.sk7.sh"},'
    '"org.matrix.msc4143.rtc_foci":[{"type":"livekit",'
    '"livekit_service_url":"https://matrix-rtc.sk7.sh"}]}';

void main() {
  group('RtcSfuClient.discoverFoci', () {
    test('lit les foci livekit dans le well-known du homeserver', () async {
      final rec = _Recorder()
        ..handler = (req) async => http.Response(_wellKnown, 200);
      final foci = await _client(rec).discoverFoci();
      expect(foci, hasLength(1));
      expect(foci.single.type, 'livekit');
      expect(foci.single.livekitServiceUrl, 'https://matrix-rtc.sk7.sh');
      expect(
        rec.requests.single.url.toString(),
        'https://matrix.sk7.sh/.well-known/matrix/client',
      );
    });

    test('well-known sans rtc_foci → liste vide, pas exception', () async {
      final rec = _Recorder()
        ..handler = (req) async => http.Response(
              '{"m.homeserver":{"base_url":"https://matrix.sk7.sh"}}',
              200,
            );
      expect(await _client(rec).discoverFoci(), isEmpty);
    });
  });

  group('RtcSfuClient.requestCredentials', () {
    test('openid puis /sfu/get avec le body legacy exact', () async {
      final rec = _Recorder()
        ..handler = (req) async {
          expect(req.url.path, '/sfu/get');
          return http.Response(
            jsonEncode({'url': 'wss://matrix-rtc.sk7.sh', 'jwt': 'le-jwt'}),
            200,
          );
        };
      final creds = await _client(rec).requestCredentials(
        '!y2jT1plx0un4plMEDxtM66gwZBdsgc6M673rNLm933M',
        const RtcFocus(
          type: 'livekit',
          livekitServiceUrl: 'https://matrix-rtc.sk7.sh',
        ),
      );
      expect(creds.livekitUrl, 'wss://matrix-rtc.sk7.sh');
      expect(creds.jwt, 'le-jwt');
      final body = jsonDecode(rec.requests.single.body) as Map<String, Object?>;
      expect(
        body['room'],
        '!y2jT1plx0un4plMEDxtM66gwZBdsgc6M673rNLm933M',
      );
      expect(body['device_id'], 'DEVSPICE');
      final oid = body['openid_token'] as Map<String, Object?>;
      expect(oid['access_token'], 'oid-token');
      expect(oid['token_type'], 'Bearer');
      expect(oid['matrix_server_name'], 'matrix.sk7.sh');
      expect(oid['expires_in'], 3600);
    });

    test('SFU refuse (M_UNKNOWN_TOKEN) → SfuAuthException, pas de retry ici',
        () async {
      var posts = 0;
      final rec = _Recorder()
        ..handler = (req) async {
          posts++;
          return http.Response(
            '{"errcode":"M_UNKNOWN_TOKEN","error":"expired"}',
            401,
          );
        };
      await expectLater(
        _client(rec).requestCredentials(
          '!room:matrix.sk7.sh',
          const RtcFocus(
            type: 'livekit',
            livekitServiceUrl: 'https://matrix-rtc.sk7.sh',
          ),
        ),
        throwsA(isA<SfuAuthException>()),
      );
      expect(posts, 1);
    });
  });
}
