package chat.fluffy.fluffychat.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Stub WAP_PUSH_DELIVER (MMS) — Étape 1.
 *
 * OBLIGATOIRE pour être candidat au rôle ROLE_SMS : Android exige qu'une app SMS par
 * défaut déclare un receiver WAP_PUSH_DELIVER pour le MIME `application/vnd.wap.mms-message`,
 * sinon l'app n'apparaît PAS dans la liste des apps SMS par défaut.
 *
 * À l'étape 1 on ne traite pas les MMS (pas de download PDU, pas de parsing). On loggue et
 * on ne fait rien d'autre. L'implémentation complète viendra à l'étape 2.
 */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        Log.i(SmsBridge.TAG, "WAP_PUSH_DELIVER (MMS) reçu — non traité à l'étape 1 (action=${intent?.action})")
        // TODO étape 2 : télécharger + parser le PDU MMS, écrire dans content://mms, notifier Dart.
    }
}
