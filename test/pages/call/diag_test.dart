import 'package:fluffychat/pages/call/active_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' show WrappedMediaStream;

class FakeC extends CallController {
  @override
  String remoteName = 'Alice';
  @override
  bool isVideo = true;
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
  @override
  WrappedMediaStream? localStream;
  @override
  WrappedMediaStream? remoteStream;
  @override
  void toggleMic() {}
  @override
  void toggleCamera() {}
  @override
  void flipCamera() {}
  @override
  void toggleSpeaker() {}
  @override
  void hangup() {}
}

void main() {
  testWidgets('le bouton raccrocher reste dans l ecran en video (360 dp)', (tester) async {
    // Pixel 10 Pro XL : 1280 px de large a densite ~420 dpi => ~360 dp de large utile.
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: ActiveCallPage(controller: FakeC())));
    final screen = tester.getSize(find.byType(MaterialApp));
    final row = find.descendant(
        of: find.byType(Row), matching: find.byKey(const Key('call-hangup')));
    final box = row.first;
    final size = tester.getSize(box);
    final topLeft = tester.getTopLeft(box);
    final topRight = tester.getTopRight(box);
    debugPrint('SCREEN width=${screen.width}');
    debugPrint('HANGUP width=${size.width} left=${topLeft.dx} right=${topRight.dx}');
    debugPrint('DEBORDEMENT DROIT: ${topRight.dx > screen.width}');
    expect(topRight.dx <= screen.width, true,
        reason: 'le raccrocher sort de l ecran : six controles avec libelles non tenus');
  });
}
