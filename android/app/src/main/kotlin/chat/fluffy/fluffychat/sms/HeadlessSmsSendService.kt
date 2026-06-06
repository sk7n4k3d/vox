package chat.fluffy.fluffychat.sms

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.telephony.TelephonyManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Service RESPOND_VIA_MESSAGE (réponse rapide depuis l'écran d'appel : « envoyer un SMS »).
 *
 * OBLIGATOIRE pour être candidat au rôle ROLE_SMS : Android exige qu'une app SMS par
 * défaut déclare un service gérant l'action `android.intent.action.RESPOND_VIA_MESSAGE`
 * avec la permission `SEND_RESPOND_VIA_MESSAGE`, sinon l'app n'apparaît PAS dans la liste
 * des apps SMS par défaut.
 *
 * Envoie réellement la quick-response : extrait le(s) destinataire(s) de l'URI
 * (sms:/smsto:/mms:/mmsto:, séparés par ';' ou ',') et le texte via EXTRA_TEXT,
 * puis route sur [SmsBridge.sendSms].
 */
class HeadlessSmsSendService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == TelephonyManager.ACTION_RESPOND_VIA_MESSAGE) {
            val recipients = intent.data?.schemeSpecificPart
                ?.split(';', ',')
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                .orEmpty()
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (recipients.isEmpty() || text.isNullOrBlank()) {
                Log.w(SmsBridge.TAG, "RESPOND_VIA_MESSAGE : destinataire ou texte manquant")
            } else {
                val appContext = applicationContext
                scope.launch {
                    for (recipient in recipients) {
                        try {
                            SmsBridge.sendSms(appContext, recipient, text)
                        } catch (e: Exception) {
                            Log.e(SmsBridge.TAG, "RESPOND_VIA_MESSAGE send failed: ${e.message}")
                        }
                    }
                }
            }
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
