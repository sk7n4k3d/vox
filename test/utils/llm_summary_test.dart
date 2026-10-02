import 'package:fluffychat/utils/llm/llm_summary.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

SmsMessage _sms({
  required String id,
  required String body,
  required bool fromMe,
  required int date,
}) => SmsMessage(
  id: id,
  address: '+33600000000',
  body: body,
  date: date,
  isFromMe: fromMe,
  type: fromMe ? 2 : 1,
  status: 0,
  read: true,
);

void main() {
  group('buildSmsTranscript', () {
    test('labels self as Moi and the peer with the contact name', () {
      final transcript = buildSmsTranscript([
        _sms(
          id: '1',
          body: 'Salut',
          fromMe: false,
          date: DateTime(2026, 1, 1, 9, 5).millisecondsSinceEpoch,
        ),
        _sms(
          id: '2',
          body: 'Ça va ?',
          fromMe: true,
          date: DateTime(2026, 1, 1, 9, 6).millisecondsSinceEpoch,
        ),
      ], 'Alice');

      expect(transcript, 'Alice (09:05): Salut\nMoi (09:06): Ça va ?');
    });

    test('skips empty bodies', () {
      final transcript = buildSmsTranscript([
        _sms(id: '1', body: '  ', fromMe: false, date: 0),
        _sms(id: '2', body: 'ok', fromMe: false, date: 0),
      ], 'Alice');

      expect(transcript, 'Alice (01:00): ok');
    });

    test('returns empty string for no usable message', () {
      expect(buildSmsTranscript(const [], 'Alice'), '');
    });
  });
}
