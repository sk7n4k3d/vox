package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Reçoit le PendingIntent émis par [SmsBridge.sendMms] (via SmsManager.sendMultimediaMessage)
 * et fait passer la ligne Outbox correspondante en Sent (succès) ou Failed (échec).
 *
 * Non exporté : déclenché uniquement par notre propre PendingIntent (setPackage).
 *
 * `resultCode == RESULT_OK` signifie que la stack a accepté/soumis le m-send-req au MMSC.
 * Ce n'est pas une confirmation de remise (pas de delivery report demandé), mais c'est le seul
 * signal disponible côté sendMultimediaMessage.
 */
class MmsSentReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != SmsBridge.ACTION_MMS_SENT) return
        val mmsId = intent.getLongExtra(SmsBridge.EXTRA_MMS_ID, -1L)
        val ok = resultCode == Activity.RESULT_OK

        if (!ok) {
            Log.w(SmsBridge.TAG, "MMS send FAILED (mmsId=$mmsId, code=$resultCode)")
        } else {
            Log.i(SmsBridge.TAG, "MMS submitted to MMSC (mmsId=$mmsId)")
        }

        if (mmsId <= 0L) return
        try {
            val uri = ContentUris.withAppendedId(Telephony.Mms.CONTENT_URI, mmsId)
            val box = if (ok) Telephony.Mms.MESSAGE_BOX_SENT else Telephony.Mms.MESSAGE_BOX_FAILED
            val values = ContentValues().apply {
                put(Telephony.Mms.MESSAGE_BOX, box)
                put(Telephony.Mms.READ, 1)
                put(Telephony.Mms.SEEN, 1)
            }
            context.contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MmsSentReceiver update(mmsId=$mmsId) failed: ${e.message}")
        }
    }
}
