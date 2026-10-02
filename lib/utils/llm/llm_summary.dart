import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:matrix/matrix.dart';

/// Prompt système de résumé — français, direct, 3-5 phrases.
const String kLlmSummarySystemPrompt =
    'Tu résumes des conversations de messagerie en français. '
    'Résume la conversation suivante en 3-5 phrases, style direct.';

/// Nombre de messages récents transmis au modèle.
const int kLlmSummaryWindow = 40;

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _hhmm(DateTime dateTime) {
  final local = dateTime.toLocal();
  return '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _hhmmFromMs(int milliseconds) =>
    _hhmm(DateTime.fromMillisecondsSinceEpoch(milliseconds));

/// Construit un transcript « Prénom (hh:mm): message » à partir des derniers
/// événements Matrix textuels. Les événements non textuels sont ignorés.
String buildMatrixTranscript(List<Event> events) {
  final buffer = StringBuffer();
  for (final event in events) {
    if (event.type != EventTypes.Message) continue;
    if (event.messageType != MessageTypes.Text) continue;
    final text = event.plaintextBody.trim();
    if (text.isEmpty) continue;
    final sender = event.senderFromMemoryOrFallback.calcDisplayname();
    buffer.writeln('$sender (${_hhmm(event.originServerTs)}): $text');
  }
  return buffer.toString().trim();
}

/// Construit un transcript « Moi/Contact (hh:mm): message » à partir des
/// derniers messages SMS/MMS textuels du fil.
String buildSmsTranscript(List<SmsMessage> messages, String contactName) {
  final buffer = StringBuffer();
  for (final message in messages) {
    final text = message.body.trim();
    if (text.isEmpty) continue;
    final speaker = message.isFromMe ? 'Moi' : contactName;
    buffer.writeln('$speaker (${_hhmmFromMs(message.date)}): $text');
  }
  return buffer.toString().trim();
}
