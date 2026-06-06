package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.util.Log

/**
 * Reçoit les PendingIntents SENT / DELIVERED émis par [SmsBridge.sendSms] et met à jour
 * le `type` / `status` de la ligne SMS correspondante dans le provider.
 *
 * Déclaré non-exporté (receiver interne, déclenché par nos propres PendingIntents avec
 * setPackage). Pas de permission système requise.
 */
class SmsSentReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val rowId = intent.getLongExtra(SmsBridge.EXTRA_ROW_ID, 0L)
        if (rowId <= 0L) return
        val uri = Uri.withAppendedPath(Telephony.Sms.CONTENT_URI, rowId.toString())

        when (action) {
            SmsBridge.ACTION_SMS_SENT -> {
                val ok = resultCode == Activity.RESULT_OK
                val type = if (ok) Telephony.Sms.MESSAGE_TYPE_SENT else Telephony.Sms.MESSAGE_TYPE_FAILED
                updateType(context, uri, type, rowId, ok)
                if (!ok) Log.w(SmsBridge.TAG, "SMS send FAILED (row=$rowId, code=$resultCode)")
            }
            SmsBridge.ACTION_SMS_DELIVERED -> {
                // Lire le vrai SMS-STATUS-REPORT au lieu de supposer "remis" :
                // un échec/expiration opérateur doit être enregistré comme tel.
                val status = parseDeliveryStatus(intent)
                updateStatus(context, uri, status, rowId)
            }
        }
    }

    /**
     * Mappe le PDU de delivery-report vers un statut Telephony. Si le PDU est
     * illisible, on retombe sur STATUS_COMPLETE (comportement historique) plutôt
     * que de bloquer.
     */
    private fun parseDeliveryStatus(intent: Intent): Int {
        return try {
            val msg = Telephony.Sms.Intents.getMessagesFromIntent(intent)?.firstOrNull()
                ?: return Telephony.Sms.STATUS_COMPLETE
            // status TP-Status (GSM 03.40) : 0..0x1F = remis, 0x20..0x3F = en
            // cours/temporaire, ≥0x40 = échec permanent.
            when {
                msg.status >= 0x40 -> Telephony.Sms.STATUS_FAILED
                msg.status in 0x20..0x3F -> Telephony.Sms.STATUS_PENDING
                else -> Telephony.Sms.STATUS_COMPLETE
            }
        } catch (e: Exception) {
            Log.w(SmsBridge.TAG, "parseDeliveryStatus failed: ${e.message}")
            Telephony.Sms.STATUS_COMPLETE
        }
    }

    private fun updateType(context: Context, uri: Uri, type: Int, rowId: Long, ok: Boolean) {
        try {
            val values = ContentValues().apply {
                put(Telephony.Sms.TYPE, type)
                // ERROR_CODE : code opérateur. On stocke resultCode si échec (non-zéro
                // = erreur, sémantique attendue par les apps SMS lisant cette colonne).
                if (!ok) put(Telephony.Sms.ERROR_CODE, resultCode)
            }
            context.contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "updateType(row=$rowId) failed: ${e.message}")
        }
    }

    private fun updateStatus(context: Context, uri: Uri, status: Int, rowId: Long) {
        try {
            val values = ContentValues().apply { put(Telephony.Sms.STATUS, status) }
            context.contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "updateStatus(row=$rowId) failed: ${e.message}")
        }
    }
}
