package chat.fluffy.fluffychat.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Receiver WAP_PUSH_DELIVER (MMS entrant).
 *
 * OBLIGATOIRE pour le rôle ROLE_SMS : une app SMS par défaut DOIT déclarer un receiver
 * WAP_PUSH_DELIVER pour `application/vnd.wap.mms-message`.
 *
 * ⚠️ Quand VOX détient ROLE_SMS, la stack Android ne télécharge PLUS le corps du MMS
 * automatiquement — c'est la responsabilité de l'app par défaut. On parse donc le PDU
 * de notification (M-Notification.ind) pour en extraire la content-location, puis on
 * déclenche le download via [SmsBridge.downloadIncomingMms].
 */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION) {
            return
        }
        val data = intent.getByteArrayExtra("data")
        if (data == null || data.isEmpty()) {
            Log.w(SmsBridge.TAG, "WAP_PUSH_DELIVER: no PDU data extra")
            return
        }
        Log.i(SmsBridge.TAG, "WAP_PUSH_DELIVER (MMS) reçu, PDU=${data.size} octets")

        val notif = MmsNotificationParser.parse(data)
        if (notif == null) {
            Log.e(SmsBridge.TAG, "WAP_PUSH_DELIVER: PDU notification illisible")
            return
        }
        // PII expurgée : ni le numéro, ni la content-location, ni le transaction-id
        // ne doivent atterrir en clair dans logcat. On ne logge que des présences.
        Log.i(
            SmsBridge.TAG,
            "MMS notif parsée: size=${notif.messageSize} " +
                "from=${if (notif.from.isNullOrBlank()) "?" else "ok"} " +
                "loc=${if (notif.contentLocation.isNullOrBlank()) "absente" else "ok"}",
        )

        // Déclenche le download réel (asynchrone). goAsync pour tenir le process.
        val pending = goAsync()
        SmsBridge.downloadIncomingMms(
            context.applicationContext,
            notif,
        ) {
            pending.finish()
        }
    }
}
