import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmsMessage.fromMap — colonne status', () {
    Map<String, dynamic> row({
      required int type,
      required int status,
      bool isMms = false,
    }) => {
      'id': 42,
      'address': '+33600000000',
      'body': 'x',
      'date': 1,
      'isFromMe': type != 1,
      'type': type,
      'status': status,
      'read': true,
      'isMms': isMms,
      'attachments': <Map<String, dynamic>>[],
    };

    test('conserve le status renvoyé par le provider', () {
      // STATUS_COMPLETE (0) d'un rapport de remise doit arriver intact.
      expect(SmsMessage.fromMap(row(type: 2, status: 0)).status, 0);
      // STATUS_NONE (-1) : aucun rapport (cas le plus courant en France).
      expect(SmsMessage.fromMap(row(type: 2, status: -1)).status, -1);
      // valeur absente -> défaut -1, jamais 0 (= ne pas inventer « distribué »).
      final noStatus = row(type: 2, status: 0)..remove('status');
      expect(SmsMessage.fromMap(noStatus).status, -1);
    });

    test('parse isMms + type pour distinguer SMS et MMS', () {
      final sms = SmsMessage.fromMap(row(type: 2, status: 0));
      final mms = SmsMessage.fromMap(row(type: 2, status: -1, isMms: true));
      expect(sms.isMms, isFalse);
      expect(mms.isMms, isTrue);
      // Un MMS sortant revient en STATUS_NONE du natif (pas de rapport suivi) :
      // jamais 0, pour ne pas afficher un faux « Distribué ».
      expect(mms.status, isNot(0));
    });
  });

  group('AppConfig — liens de l app (plus lancien depot amont)', () {
    test('source/support/issues pointent vers le miroir VoxOne', () {
      expect(AppConfig.sourceCodeUrl, 'https://github.com/sk7n4k3d/vox');
      expect(AppConfig.supportUrl, 'https://github.com/sk7n4k3d/vox/issues');
      expect(AppConfig.newIssueUrl.host, 'github.com');
      expect(AppConfig.newIssueUrl.path, '/sk7n4k3d/vox/issues/new');
    });

    test('aucun lien visible ne pointe vers le depot amont', () {
      for (final url in [
        AppConfig.sourceCodeUrl,
        AppConfig.supportUrl,
        AppConfig.changelogUrl,
        AppConfig.newIssueUrl.toString(),
      ]) {
        expect(
          url,
          isNot(contains('krille-chan/fluffychat')),
          reason: '$url pointe encore vers le dépôt amont',
        );
      }
    });
  });
}
