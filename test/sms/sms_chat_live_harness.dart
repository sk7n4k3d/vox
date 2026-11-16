// Harness partagé des tests d'intégration de la page de conversation SMS :
// MethodChannel/EventChannel natifs mockés, page MaterialApp+L10n réelle.
// N'est pas un fichier de test (pas de *_test.dart) — importé par les tests.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/sms_chat/sms_chat_page.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout, kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable, RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const smsChannel = MethodChannel('eu.devlabz.vox/sms');
const eventsChannel = EventChannel('eu.devlabz.vox/sms_events');

const address = '+33600000000';
const threadId = '4';

/// Clé de bulle posée par la page (`sms_row_<uid>`) — joint les assertions à
/// LA bulle d'une table précise, pas juste au texte quelque part dans l'arbre.
Finder liveBubble(String uid) => find.byKey(ValueKey('sms_row_$uid'));

/// Slot média visuel d'une bulle (Semantics « Image MMS » posé par _MmsImage).
/// Le décodage réel de `Image.file` ne complète jamais sous fake-async, donc
/// on affirme sur le slot résolu, pas sur l'image décodée.
final Finder imageSlot = find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Image MMS',
);

Map<String, dynamic> mmsPart(int id, String mime, String name) => {
  'partId': id,
  'mimeType': mime,
  'fileName': name,
};

Map<String, dynamic> smsRow({
  required int id,
  required String body,
  required int date,
  int type = 1,
  int status = -1,
}) => {
  'id': id,
  'address': address,
  'body': body,
  'date': date,
  'isFromMe': type != 1,
  'type': type,
  'status': status,
  'read': true,
  'isMms': false,
  'attachments': <Map<String, dynamic>>[],
};

Map<String, dynamic> mmsRow({
  required int id,
  required String body,
  required int date,
  int type = 1,
  List<Map<String, dynamic>> attachments = const [],
}) => {
  'id': id,
  'address': address,
  'body': body,
  'date': date,
  'isFromMe': type != 1,
  'type': type,
  'status': -1,
  'read': true,
  'isMms': true,
  'attachments': attachments,
};

Map<String, dynamic> smsEvent(int messageId, String body, int date) => {
  'kind': 'sms',
  'address': address,
  'body': body,
  'date': date,
  'threadId': threadId,
  'messageId': messageId,
};

Map<String, dynamic> mmsEvent(int mmsId, String body, int date) => {
  'kind': 'mms',
  'address': address,
  'body': body,
  'date': date,
  'threadId': threadId,
  'mmsId': mmsId,
};

class SmsFixture {
  /// Sinks ouverts par les pages écoutées (un « listen » EventChannel).
  final List<MockStreamHandlerEventSink> sinks = [];
  List<Map<String, dynamic>> latestPage = [];
  List<Map<String, dynamic>> olderPage = [];
  Map<int, List<Map<String, dynamic>>> partsByMms = {};
  int? sendRowId;
  final List<MethodCall> calls = [];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'listMessages':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        return (args['beforeMs'] as int) > 0 ? olderPage : latestPage;
      case 'listMmsParts':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        return partsByMms[args['mmsId']] ?? const [];
      case 'loadMmsPart':
        // Chemin volontairement inexistant : la bulle affiche alors l'icône
        // « image cassée », preuve que la part a bien été résolue et attachée
        // À CETTE bulle-là.
        return '/tmp/vox-test-part-inexistante.img';
      case 'sendSms':
      case 'sendMms':
        return sendRowId;
      case 'deleteMessage':
        return 1;
      case 'markRead':
        return 0;
      default:
        return null;
    }
  }

  Map<String, dynamic> lastArgs(String method) => Map<String, dynamic>.from(
    calls.lastWhere((c) => c.method == method).arguments as Map,
  );

  void emit(Map<String, dynamic> event) {
    for (final sink in List<MockStreamHandlerEventSink>.of(sinks)) {
      sink.success(event);
    }
  }
}

// À installer dans le CORPS du test (zone fake-async de `testWidgets`) :
// enregistrés hors zone (dans un `setUp`), les replies de l'EventChannel
// retombent dans la vraie event loop et `tester.pump()` ne les draine jamais.
Future<SmsFixture> installSmsHarness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await AppSettings.init();
  final fx = SmsFixture();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(smsChannel, fx.handle);
  messenger.setMockStreamHandler(
    eventsChannel,
    // Chaque page écoutée ouvre un « listen » natif : on mémorise son sink
    // pour lui pousser les événements SMS/MMS live.
    MockStreamHandler.inline(onListen: (_, sink) => fx.sinks.add(sink)),
  );
  return fx;
}

Future<void> openSmsPage(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('fr'),
      home: const SmsChatPage(threadId: threadId, address: address),
    ),
  );
  await tester.pump();
  // Solde les animations d'entrée + la boucle bornée de maintien en bas.
  await tester.pump(const Duration(seconds: 1));
  // La réponse mockée de listMessages retombe parfois dans les microtâches
  // d'après-frame : un dernier petit pump garantit que le setState de _load
  // est rendu avant la première assertion.
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> disposeSmsPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Ouvre la sheet d'actions d'une bulle par un vrai long-press. Deux pièges :
/// 1) le corps de texte est un SelectableLinkify — longue pression = sélection
/// de texte (volontaire, cf. commentaire du widget) : on presse une zone
/// NON-texte de la bulle ; 2) l'app bar givrée et le composer débordent sur
/// le hit-test en haut/bas — on centre d'abord la bulle. pumpAndSettle ne
/// converge pas ici (fond cyber animé) → pumps bornés.
Future<void> longPressBubble(WidgetTester tester, String uid) async {
  final element = liveBubble(uid).evaluate().single;
  await Scrollable.ensureVisible(
    element,
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final detectors = find.descendant(
    of: liveBubble(uid),
    matching: find.byType(GestureDetector),
  );
  final box = detectors.evaluate().last.renderObject! as RenderBox;
  final rect = box.paintBounds.shift(box.localToGlobal(Offset.zero));
  Offset? press;
  for (final candidate in [
    rect.center,
    Offset(rect.left + 10, rect.center.dy),
    Offset(rect.center.dx, rect.top + 5),
    Offset(rect.center.dx, rect.bottom - 5),
  ]) {
    final top = tester.hitTestOnBinding(candidate).path.first.target;
    // RenderEditable = proxy de sélection du SelectableLinkify ; RenderParagraph
    // = texte linkifié brut. Les deux volent le long-press à la bulle.
    if (top is! RenderEditable && top is! RenderParagraph) {
      press = candidate;
      break;
    }
  }
  press ??= rect.center;
  final gesture = await tester.startGesture(press);
  await tester.pump();
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Appuie sur l'action [label] de la sheet ouverte (et solde l'animation de
/// fermeture).
Future<void> tapSheetAction(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}
