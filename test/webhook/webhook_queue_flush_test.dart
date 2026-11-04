import 'dart:async';

import 'package:fluffychat/utils/webhook/webhook_queue.dart';
import 'package:flutter_test/flutter_test.dart';
/// File de retry : le POST d'un gros corps (média base64) peut durer jusqu'à
/// 2 min (WebhookService.timeoutFor) alors que le réveil périodique tic toutes
/// les 60 s et que le bouton « Réessayer » appelle flush(force: true) sans
/// patienter. Sans garde d'entrée, le même corps part plusieurs fois.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deux flush concurrents ne postent pas le même corps deux fois',
      () async {
    final inFlight = Completer<void>();
    final release = Completer<bool>();
    var posts = 0;
    final queue = WebhookQueue.forTest(postRaw: (body) {
      posts++;
      if (posts == 1) {
        inFlight.complete();
        return release.future;
      }
      return Future.value(true);
    });
    addTearDown(queue.stop);

    await queue.add('{"event_id":"dup"}');
    // On vide le délai d'attente : le flush #1 reste bloqué dans postRaw.
    final first = queue.flush(force: true);
    await inFlight.future;

    // Tick périodique (ou appui sur « Réessayer ») pendant l'envoi en vol.
    await queue.flush(force: true);
    expect(posts, 1, reason: 'le corps a été POSTé pendant un envoi déjà en cours');

    release.complete(true);
    await first;
    expect(queue.length, 0);
  });

  test('un échec garde le corps et décale la prochaine tentative', () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => false);
    addTearDown(queue.stop);

    await queue.add('{"event_id":"keep"}');
    await queue.flush(force: true);

    expect(queue.length, 1);
  });

  test('une réussite retire le corps de la file', () async {
    final queue = WebhookQueue.forTest(postRaw: (_) async => true);
    addTearDown(queue.stop);

    await queue.add('{"event_id":"ok"}');
    await queue.flush(force: true);
    expect(queue.length, 0);
  });
}
