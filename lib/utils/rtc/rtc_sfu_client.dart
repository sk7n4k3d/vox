import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// GET JSON renvoyant le corps décodé (throw sur réseau/HTTP non-JSON).
typedef RtcJsonGet = Future<Map<String, Object?>> Function(Uri uri);

/// POST JSON sans auth Matrix (le token OpenID est dans le corps).
typedef RtcJsonPost = Future<Map<String, Object?>> Function(
  Uri uri,
  Map<String, Object?> body,
);

/// Focus RTC lu dans `.well-known` (`org.matrix.msc4143.rtc_foci`).
class RtcFocus {
  final String type;
  final String livekitServiceUrl;

  const RtcFocus({required this.type, required this.livekitServiceUrl});
}

/// Ce qu'il faut pour se connecter au SFU LiveKit.
class SfuCredentials {
  /// URL websocket du LiveKit (`wss://…`) rendue par le service d'autorisation.
  final String livekitUrl;
  final String jwt;

  const SfuCredentials({required this.livekitUrl, required this.jwt});
}

/// Le SFU a refusé notre identité (token OpenID périmé, session inconnue).
class SfuAuthException implements Exception {
  final String errcode;
  final String error;

  const SfuAuthException(this.errcode, this.error);

  @override
  String toString() => 'SfuAuthException($errcode: $error)';
}

/// Réservation de place sur le SFU : focus (`.well-known`), token OpenID,
/// JWT LiveKit. Séquence prouvée en spike le 2026-10-15 (spec §1/§3.2).
///
/// Le transport est injecté pour rester testable ; en production passer par
/// [RtcSfuClient.of] qui câble la session Matrix courante.
class RtcSfuClient {
  final Uri homeserver;
  final String userId;
  final String deviceId;
  final RtcJsonGet plainGet;

  /// Token OpenID de la session courante. POST obligatoire : l'endpoint est
  /// appelé `request_token` mais Tuwunel (et la spec récente) exigent POST —
  /// un GET repond `M_UNRECOGNIZED: Method Not Allowed` (terrain 15/10).
  final Future<Map<String, Object?>> Function() openidToken;
  final RtcJsonPost plainPost;

  RtcSfuClient({
    required this.homeserver,
    required this.userId,
    required this.deviceId,
    required this.plainGet,
    required this.openidToken,
    required this.plainPost,
  });

  factory RtcSfuClient.of(Client client) {
    final anon = http.Client();
    Future<Map<String, Object?>> plainGet(Uri uri) async {
      final res = await anon.get(uri);
      return jsonDecode(res.body) as Map<String, Object?>;
    }

    return RtcSfuClient(
      homeserver: client.homeserver!,
      userId: client.userID!,
      deviceId: client.deviceID!,
      plainGet: plainGet,
      plainPost: (uri, body) async {
        final res = await anon.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );
        return jsonDecode(res.body) as Map<String, Object?>;
      },
      openidToken: () async {
        final creds = await client.requestOpenIdToken(
          client.userID!,
          <String, Object?>{},
        );
        return {
          'access_token': creds.accessToken,
          'token_type': creds.tokenType ?? 'Bearer',
          'matrix_server_name': creds.matrixServerName,
          'expires_in': creds.expiresIn,
        };
      },
    );
  }

  /// Foci livekit annoncés par le homeserver ; vide si non configuré.
  Future<List<RtcFocus>> discoverFoci() async {
    final wellKnown = await plainGet(
      homeserver.replace(path: '/.well-known/matrix/client'),
    );
    final foci = wellKnown['org.matrix.msc4143.rtc_foci'];
    if (foci is! List) return const [];
    return foci
        .whereType<Map<Object?, Object?>>()
        .map(
          (f) => RtcFocus(
            type: f['type'] as String? ?? '',
            livekitServiceUrl: f['livekit_service_url'] as String? ?? '',
          ),
        )
        .where((f) => f.type == 'livekit' && f.livekitServiceUrl.isNotEmpty)
        .toList();
  }

  /// Token OpenID de CETTE session puis `POST {focus}/sfu/get` (body legacy
  /// `{room, device_id, openid_token}` validé en spike). Une seule tentative :
  /// la politique de retry appartient à l'appelant (RtcCall).
  Future<SfuCredentials> requestCredentials(String roomId, RtcFocus focus) async {
    final openid = await openidToken();
    final body = <String, Object?>{
      'room': roomId,
      'device_id': deviceId,
      'openid_token': {
        'access_token': openid['access_token'],
        'token_type': openid['token_type'] ?? 'Bearer',
        'matrix_server_name': openid['matrix_server_name'],
        'expires_in': openid['expires_in'],
      },
    };
    final res = await plainPost(
      Uri.parse(focus.livekitServiceUrl).replace(path: '/sfu/get'),
      body,
    );
    final errcode = res['errcode'];
    if (errcode is String) {
      Logs().w('[RTC] /sfu/get refusé: $errcode');
      throw SfuAuthException(errcode, res['error'] as String? ?? '');
    }
    final url = res['url'];
    final jwt = res['jwt'];
    if (url is! String || jwt is! String) {
      throw const SfuAuthException('M_BAD_RESPONSE', 'réponse SFU sans url/jwt');
    }
    Logs().w('[RTC] credentials SFU ok (jwt ${jwt.length} car.)');
    return SfuCredentials(livekitUrl: url, jwt: jwt);
  }
}
