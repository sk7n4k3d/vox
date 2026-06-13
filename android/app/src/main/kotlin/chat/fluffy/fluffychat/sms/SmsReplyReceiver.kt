package chat.fluffy.fluffychat.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.RemoteInput
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Gère les actions des notifications SMS riches :
 *  - ACTION_REPLY : réponse texte inline (RemoteInput) → envoie le SMS.
 *  - ACTION_MARK_READ : marque le thread lu et retire la notif.
 *
 * Non-exporté (déclenché par nos propres PendingIntents avec setPackage).
 */
class SmsReplyReceiver : BroadcastReceiver() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val threadId = intent.getLongExtra(SmsNotifier.EXTRA_THREAD_ID, -1L)
        if (threadId <= 0L) return

        when (action) {
            SmsNotifier.ACTION_REPLY -> {
                val address = intent.getStringExtra(SmsNotifier.EXTRA_ADDRESS)
                val text = RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(SmsNotifier.KEY_REPLY_TEXT)
                    ?.toString()
                    ?.trim()
                if (address.isNullOrBlank() || text.isNullOrBlank()) {
                    Log.w(SmsBridge.TAG, "SMS reply: adresse ou texte vide")
                    return
                }
                val pending = goAsync()
                val appContext = context.applicationContext
                scope.launch {
                    try {
                        SmsBridge.sendSms(appContext, address, text)
                        SmsBridge.markRead(appContext, threadId)
                        SmsNotifier.cancel(appContext, threadId)
                    } catch (e: Exception) {
                        Log.e(SmsBridge.TAG, "SMS reply send failed: ${e.message}")
                    } finally {
                        pending.finish()
                    }
                }
            }

            SmsNotifier.ACTION_MARK_READ -> {
                val pending = goAsync()
                val appContext = context.applicationContext
                scope.launch {
                    try {
                        SmsBridge.markRead(appContext, threadId)
                        SmsNotifier.cancel(appContext, threadId)
                    } catch (e: Exception) {
                        Log.e(SmsBridge.TAG, "SMS mark-read failed: ${e.message}")
                    } finally {
                        pending.finish()
                    }
                }
            }

            SmsNotifier.ACTION_COPY_OTP -> {
                val code = intent.getStringExtra(SmsNotifier.EXTRA_OTP_CODE)
                if (!code.isNullOrBlank()) {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE)
                        as? android.content.ClipboardManager
                    cm?.setPrimaryClip(
                        android.content.ClipData.newPlainText("Code", code),
                    )
                    android.widget.Toast.makeText(
                        context,
                        "Code $code copié",
                        android.widget.Toast.LENGTH_SHORT,
                    ).show()
                }
            }
        }
    }
}
