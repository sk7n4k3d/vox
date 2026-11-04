// Sonde blue-team (audit 8960c5cc) — comptage du cache vignettes sous
// concurrence : ÉVICTION PUIS RÉINSERTION DE LA MÊME URL (scroll avant/arrière
// sur un lien dont la 1re requête est encore en vol). Copie hors cible.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/utils/sms/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _thumb = 2 * 1024 * 1024; // vignette au max (_maxImageBytes)
const _ceiling = 8 * 1024 * 1024;

/// Une place par appel `send`, dans l ordre des `arm()` : index stable, pour
/// pouvoir résoudre la 2e requête AVANT la 1re (résolution hors ordre).
class _Slot {
  final completer = Completer<http.StreamedResponse>();
  bool claimed = false;
}

class _Gate {
  final Map<String, List<_Slot>> q = {};

  void arm(String url) => q.putIfAbsent(url, () => <_Slot>[]).add(_Slot());

  int pending(String url) => q[url]!.where((s) => !s.completer.isCompleted).length;

  /// Résout la n-ième requête de [url] avec une image de [size].
  void succeed(String url, int n, int size) {
    q[url]![n].completer.complete(
      http.StreamedResponse(
        Stream.value(Uint8List(size)),
        200,
        headers: {'content-type': 'image/png'},
      ),
    );
  }

  /// Fait échouer la n-ième requête (CDN lent qui casse tard) : la future de
  /// service rend alors null, donc 0 octet compté.
  void fail(String url, int n) {
    q[url]![n].completer.completeError(const SocketException('reseau casse tard'));
  }

  Future<http.StreamedResponse> take(String url) {
    final slot = q[url]!.firstWhere((s) => !s.claimed);
    slot.claimed = true;
    return slot.completer.future;
  }
}

class _GatedClient extends http.BaseClient {
  _GatedClient(this.gate);
  final _Gate gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      gate.take(request.url.toString());

  @override
  void close() {}
}

void main() {
  late _Gate gate;
  late LinkPreviewService svc;

  setUp(() {
    gate = _Gate();
    svc = LinkPreviewService.forTesting(
      newClient: (_) => _GatedClient(gate),
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  Future<void> load(String url, {int size = _thumb}) async {
    gate.arm(url);
    final f = svc.fetchImage(url);
    gate.succeed(url, 0, size);
    await f;
    await settle();
  }

  Future<void> fillCeiling(String tag, int n) async {
    for (var i = 0; i < n; i++) {
      await load('https://c/$tag$i.png');
    }
  }

  test('T1 — meme URL evictee-reinseree : compteur faux des la 1re occurrence',
      () async {
    // Plafond atteint : 4 vignettes de 2 Mo = 8 Mo comptés, 8 Mo retenus.
    await fillCeiling('f', 4);
    expect(svc.imageCacheBytesForTest, _ceiling);
    expect(svc.imageCacheCountForTest, 4);

    // Lien lent : 1re requete reste en vol, 4 inserts le chassent du cache.
    final u = 'https://c/lent.png';
    gate.arm(u);
    final stale = svc.fetchImage(u);
    await settle();
    for (var i = 0; i < 4; i++) {
      await load('https://c/churn$i.png');
    }
    expect(svc.imageCacheCountForTest, 4);
    expect(svc.imageCacheBytesForTest, _ceiling);

    // Scroll retour : MEME url, toujours en vol → nouvelle entrée payée 2 Mo.
    gate.arm(u);
    final fresh = svc.fetchImage(u);
    expect(identical(fresh, stale), isFalse,
        reason: 'l entree a bien ete evictee puis reinseree');
    gate.succeed(u, 1, _thumb); // la 2e requete aboutit
    await fresh;
    await settle();
    expect(svc.imageCacheBytesForTest, _ceiling,
        reason: '8 Mo comptés pour 8 Mo retenus : ok avant le retard');

    // Et la 1re requete, trop lente, échoue plus tard :
    gate.fail(u, 0);
    await stale;
    await settle();
    final bytes = svc.imageCacheBytesForTest;
    final count = svc.imageCacheCountForTest;
    // ignore: avoid_print
    print('T1 apres echec tardif: compteur=$bytes count=$count '
        'retention=${count * _thumb} deficit=${count * _thumb - bytes}');

    // Consequence directe : le plafond ne se déclenche plus au bon seuil.
    await load('https://c/debordement.png');
    final over = svc.imageCacheCountForTest * _thumb;
    // ignore: avoid_print
    print('T1 retention apres insert suivant: $over (plafond $_ceiling), '
        'compteur=${svc.imageCacheBytesForTest} '
        'count=${svc.imageCacheCountForTest}');
    expect(over, lessThanOrEqualTo(_ceiling),
        reason: 'la rétention dépasse le plafond voulu : $over > $_ceiling '
            'à cause du déficit de ${count * _thumb - bytes} octets');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('T2 — meme pattern repete (scroll reel) : plafond franchi à chaque fois',
      () async {
    await fillCeiling('g', 4);
    var maxRetention = 0;
    var maxBytes = 0;
    var abaCount = 0;
    void sample() {
      final r = svc.imageCacheCountForTest * _thumb;
      maxRetention = r > maxRetention ? r : maxRetention;
      maxBytes = svc.imageCacheBytesForTest > maxBytes
          ? svc.imageCacheBytesForTest
          : maxBytes;
    }

    Future<void> stepLoad(String url) async {
      gate.arm(url);
      final f = svc.fetchImage(url);
      gate.succeed(url, 0, _thumb);
      await f;
      await settle();
      sample();
    }

    sample();
    for (var r = 0; r < 12; r++) {
      final u = 'https://c/r$r.png';
      gate.arm(u);
      final stale = svc.fetchImage(u);
      await settle();
      sample();
      for (var i = 0; i < 4; i++) {
        await stepLoad('https://c/h$r-$i.png');
      }
      gate.arm(u);
      final fresh = svc.fetchImage(u);
      sample();
      if (identical(fresh, stale)) {
        gate.fail(u, 0); // pas d ABA ce tour-ci, on purge
        await stale;
        await settle();
        sample();
        continue;
      }
      abaCount++;
      gate.succeed(u, 1, _thumb);
      await fresh;
      await settle();
      sample();
      gate.fail(u, 0);
      await stale;
      await settle();
      sample();
      // ignore: avoid_print
      print('T2 r=$r compteur=${svc.imageCacheBytesForTest} '
          'count=${svc.imageCacheCountForTest} '
          'retention=${svc.imageCacheCountForTest * _thumb}');
    }
    // ignore: avoid_print
    print('T2 aba=$abaCount maxRetention=$maxRetention maxCompteur=$maxBytes '
        'plafond=$_ceiling');
    expect(maxRetention, lessThanOrEqualTo(_ceiling),
        reason: 'retention max observee $maxRetention > plafond $_ceiling '
            'sur $abaCount occurrences du pattern');
  }, timeout: const Timeout(Duration(seconds: 240)));
}
