package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Reçoit le PendingIntent de fin de [SmsManager.downloadMultimediaMessage].
 * Quand le download a réussi, le m-retrieve-conf est dans le fichier fourni :
 * on le parse et on l'insère dans content://mms via [SmsBridge.ingestDownloadedMms].
 */
class MmsDownloadedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != SmsBridge.ACTION_MMS_DOWNLOADED) return
        val ok = resultCode == Activity.RESULT_OK
        val pduPath = intent.getStringExtra("download_path")
        val from = intent.getStringExtra(SmsBridge.EXTRA_FROM)
        Log.i(
            SmsBridge.TAG,
            "MMS_DOWNLOADED resultCode=$resultCode ok=$ok path=$pduPath",
        )
        if (!ok || pduPath.isNullOrBlank()) {
            Log.e(SmsBridge.TAG, "MMS download échoué (resultCode=$resultCode)")
            return
        }
        val pending = goAsync()
        val app = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                SmsBridge.ingestDownloadedMms(app, pduPath, from)
            } finally {
                pending.finish()
            }
        }
    }
}
