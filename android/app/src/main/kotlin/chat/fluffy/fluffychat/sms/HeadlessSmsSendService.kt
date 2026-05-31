package chat.fluffy.fluffychat.sms

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Service RESPOND_VIA_MESSAGE (réponse rapide depuis l'écran d'appel : « envoyer un SMS »).
 *
 * OBLIGATOIRE pour être candidat au rôle ROLE_SMS : Android exige qu'une app SMS par
 * défaut déclare un service gérant l'action `android.intent.action.RESPOND_VIA_MESSAGE`
 * avec la permission `SEND_RESPOND_VIA_MESSAGE`, sinon l'app n'apparaît PAS dans la liste
 * des apps SMS par défaut.
 *
 * À l'étape 1 c'est un stub qui se contente d'extraire le destinataire et de loguer.
 * L'envoi réel des quick-responses pourra être branché plus tard sur [SmsBridge.sendSms].
 */
class HeadlessSmsSendService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == TelephonyManager.ACTION_RESPOND_VIA_MESSAGE) {
            val recipient = intent.data?.schemeSpecificPart
            Log.i(
                SmsBridge.TAG,
                "RESPOND_VIA_MESSAGE pour ${SmsBridge.redact(recipient)} — stub étape 1, non envoyé",
            )
            // TODO : récupérer Intent.EXTRA_TEXT et appeler SmsBridge.sendSms si on veut
            //        supporter la réponse rapide depuis l'écran d'appel.
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
