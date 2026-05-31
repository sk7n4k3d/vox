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
                // Statut de remise opérateur. STATUS_COMPLETE = remis.
                updateStatus(context, uri, Telephony.Sms.STATUS_COMPLETE, rowId)
            }
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
