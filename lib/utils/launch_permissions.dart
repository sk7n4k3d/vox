import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/sms/sms_bridge.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

/// Runtime permissions that Android would otherwise never ask for.
///
/// Deux trous confirmés sur la release :
///  - POST_NOTIFICATIONS n'était demandé que dans `setupPusher()`, donc jamais
///    en mode SMS seul (pas de compte Matrix) ni avant le premier push — les
///    notifications SMS arrivaient silencieusement bloquées (SmsNotifier sort
///    sur permission manquante) ;
///  - les permissions SMS runtime (READ/SEND/RECEIVE_SMS, RECEIVE_MMS)
///    n'étaient jamais demandées : hors rôle « app SMS par défaut », rien ne
///    les accorde, et la lecture du provider échouait en SecurityException
///    silencieuse.
///
/// La salve notifications reste one-shot au premier lancement. La demande SMS
/// est AU CONTRAIRE relancée à chaque lancement tant qu'on est en mode SMS
/// seul sans permissions (audit 2026-11-05 : liée au drapeau one-shot, elle
/// était structurellement morte au premier lancement, le mode SMS-only
/// n'étant choisi qu'après). Le respect Android : on ne relance que si le
/// système montre encore un dialogue (refus simple) ; sur refus permanent
/// (« ne plus demander ») on s'arrête, et c'est à l'utilisateur de revenir
/// via l'appui manuel dans les réglages système.
Future<void> requestLaunchPermissionsOnce() async {
  if (!PlatformInfos.isAndroid) return;
  try {
    if (!AppSettings.permissionsPromptedAtLaunch.value) {
      // Le drapeau est posé AVANT la demande : Android peut ne jamais rendre la
      // main (dialogue resté ouvert, process tué), et on ne veut pas harceler à
      // chaque lancement.
      await AppSettings.permissionsPromptedAtLaunch.setItem(true);
      final notifications = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // < 13 : no-op qui rend null, pas d'attente inutile.
      if (await notifications?.requestNotificationsPermission() != null) {
        // Laisse le dialogue système se refermer avant d'enchaîner.
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    }
  } catch (e, s) {
    Logs().w('requestLaunchPermissionsOnce (notifications) failed', e, s);
  }
  await ensureSmsPermissions();
}

/// Demande les permissions SMS runtime si on est en mode SMS/MMS seul sans
/// les avoir. Appelée à chaque lancement (via [requestLaunchPermissionsOnce])
/// ET à l'entrée dans le mode SMS seul depuis l'intro ou les Réglages — le
/// moment où l'on a réellement besoin de les solliciter. Ne fait rien hors
/// mode SMS seul ; les appelants non-Android sont gardés par leur propre
/// test de plateforme (le canal n'existerait pas et l'état reste false).
///
/// Politique de reprise après refus (voir [shouldAskSmsPermissions] pour la
/// règle pure) : on redemande tant qu'Android accepte d'afficher le dialogue,
/// on cesse sur refus permanent. Retourne l'état final des permissions.
///
/// [userInitiated] = entrée VOLONTAIRE dans le mode SMS (bouton de l'intro,
/// bascule des Réglages) : un appui explicite n'est pas du harcèlement, on
/// ignore alors le drapeau « déjà demandé » et on ne juge que le `rationale`
/// (audit 2026-11-05 F2 : process tué PENDANT le dialogue laissait
/// asked=true + rationale jamais évalué → classé refus permanent → plus jamais
/// de demande, sans aucun point de rattrapage dans l'app). Sur refus
/// permanent réel, Android solde lui-même la demande sans afficher de
/// dialogue : aucun risque de harceler.
Future<bool> ensureSmsPermissions({bool userInitiated = false}) async {
  if (!AppSettings.smsOnlyMode.value) return false;
  try {
    if (await SmsBridge.instance.hasSmsPermissions()) {
      // Accordées : on remet le drapeau à zéro pour qu'une révocation future
      // depuis les réglages système reparte d'un état « jamais demandé ».
      if (AppSettings.smsPermissionsAsked.value) {
        await AppSettings.smsPermissionsAsked.setItem(false);
      }
      return true;
    }
    final askedBefore = AppSettings.smsPermissionsAsked.value;
    final rationale = await SmsBridge.instance
        .shouldShowSmsPermissionRationale();
    if (!shouldAskSmsPermissions(
      askedBefore: askedBefore,
      rationale: rationale,
      force: userInitiated,
    )) {
      // Refus permanent : plus aucun dialogue possible côté système.
      Logs().i(
        'SMS permissions refusées durablement, nouvelle demande ignorée',
      );
      return false;
    }
    // Drapeau posé AVANT la demande : si le process meurt pendant le dialogue,
    // le prochain lancement saura distinguer « jamais demandé » de « refus ».
    await AppSettings.smsPermissionsAsked.setItem(true);
    final granted = await SmsBridge.instance.requestSmsPermissions();
    Logs().i('Demande permissions SMS soldée: accordées=$granted');
    return granted;
  } catch (e, s) {
    Logs().w('ensureSmsPermissions failed', e, s);
    return false;
  }
}

/// Règle pure de la reprise après refus — testable sans plugin ni prefs :
///  - jamais demandée → on demande ;
///  - demandée et refusée une fois (rationale vrai) → on redemande, Android
///    affichera encore le dialogue ;
///  - demandée et rationale faux → refus permanent ou accordées entre-temps :
///    on ne relance plus rien (harceler est explicitement interdit par la
///    plateforme) SAUF entrée volontaire ([force]) : un appui explicite de
///    l'utilisateur n'est pas du harcèlement, et c'est le seul rattrapage du
///    faux « refus permanent » laissé par un process tué pendant le dialogue
///    (asked=true posé avant la demande, rationale jamais réévalué).
bool shouldAskSmsPermissions({
  required bool askedBefore,
  required bool rationale,
  bool force = false,
}) => force || !askedBefore || rationale;
