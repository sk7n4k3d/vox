import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeController extends CallController {
  FakeController({this.isVideo = false, this.remoteName = 'Alice'});

  @override
  String remoteName;
  @override
  bool isVideo;
  @override
  bool micMuted = false;
  @override
  bool cameraOff = false;
  @override
  bool speakerOn = false;
  @override
  bool reconnecting = false;
  @override
  bool connecting = false;
  @override
  bool connected = true;

  int micToggles = 0;
  int cameraToggles = 0;
  int flips = 0;
  int speakers = 0;
  int hangs = 0;

  @override
  void toggleMic() {
    micToggles++;
    micMuted = !micMuted;
    notifyListeners();
  }

  @override
  void toggleCamera() {
    cameraToggles++;
    cameraOff = !cameraOff;
    notifyListeners();
  }

  @override
  void flipCamera() {
    flips++;
    notifyListeners();
  }

  @override
  void toggleSpeaker() {
    speakers++;
    speakerOn = !speakerOn;
    notifyListeners();
  }

  @override
  void hangup() {
    hangs++;
    notifyListeners();
  }
}

Widget page(FakeController c) => MaterialApp(home: ActiveCallPage(controller: c));

void main() {
  testWidgets('un appel vocal montre micro, haut-parleur et raccrocher', (
    tester,
  ) async {
    await tester.pumpWidget(page(FakeController()));

    expect(find.byKey(const Key('call-toggle-mic')), findsOneWidget);
    expect(find.byKey(const Key('call-toggle-speaker')), findsOneWidget);
    expect(find.byKey(const Key('call-hangup')), findsOneWidget);
    expect(find.byKey(const Key('call-toggle-camera')), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('un appel vidéo ajoute caméra et bascule caméra', (tester) async {
    await tester.pumpWidget(page(FakeController(isVideo: true)));

    expect(find.byKey(const Key('call-toggle-camera')), findsOneWidget);
    expect(find.byKey(const Key('call-flip-camera')), findsOneWidget);
  });

  testWidgets('couper le micro appelle toggleMic et bascule l\'icône', (
    tester,
  ) async {
    final c = FakeController();
    await tester.pumpWidget(page(c));

    await tester.tap(find.byKey(const Key('call-toggle-mic')));
    await tester.pump();

    expect(c.micToggles, 1);
    expect(c.micMuted, isTrue);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('la caméra ne se coupe qu\'en appel vidéo', (tester) async {
    final c = FakeController(isVideo: true);
    await tester.pumpWidget(page(c));

    await tester.tap(find.byKey(const Key('call-toggle-camera')));
    await tester.pump();

    expect(c.cameraToggles, 1);
    expect(c.cameraOff, isTrue);
  });

  testWidgets('le haut-parleur bascule', (tester) async {
    final c = FakeController();
    await tester.pumpWidget(page(c));

    await tester.tap(find.byKey(const Key('call-toggle-speaker')));
    await tester.pump();

    expect(c.speakers, 1);
    expect(c.speakerOn, isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('raccrocher appelle hangup une seule fois', (tester) async {
    final c = FakeController();
    await tester.pumpWidget(page(c));

    await tester.tap(find.byKey(const Key('call-hangup')));
    await tester.tap(find.byKey(const Key('call-hangup')));
    await tester.pump();

    expect(c.hangs, 2);
  });

  testWidgets('le bandeau de reconnexion apparaît puis disparaît', (
    tester,
  ) async {
    final c = FakeController();
    await tester.pumpWidget(page(c));
    expect(find.text('Connexion perdue — reconnexion…'), findsNothing);

    c.reconnecting = true;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Connexion perdue — reconnexion…'), findsOneWidget);

    c.reconnecting = false;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Connexion perdue — reconnexion…'), findsNothing);
  });

  testWidgets('l\'écran audio affiche les initiales de l\'interlocuteur', (
    tester,
  ) async {
    await tester.pumpWidget(page(FakeController(remoteName: 'Alice Martin')));

    expect(find.text('AM'), findsOneWidget);
  });

  testWidgets('affiche Sonnerie… tant que l\'autre côté n\'a pas décroché', (
    tester,
  ) async {
    final c = FakeController()..connecting = true;
    await tester.pumpWidget(page(c));

    expect(find.text('Sonnerie…'), findsOneWidget);
    expect(find.text('Connecté'), findsNothing);

    c.connecting = false;
    c.connected = true;
    c.notifyListeners();
    await tester.pump();

    expect(find.text('Sonnerie…'), findsNothing);
    expect(find.text('Connecté'), findsOneWidget);
  });

  testWidgets('le statut affiche la reconnexion avant connecté', (
    tester,
  ) async {
    final c = FakeController()..reconnecting = true;
    await tester.pumpWidget(page(c));

    expect(find.text('Connexion perdue…'), findsOneWidget);
  });
}