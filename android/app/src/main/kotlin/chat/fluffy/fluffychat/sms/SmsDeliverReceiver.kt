package chat.fluffy.fluffychat.sms

import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Receiver lié à `SMS_DELIVER` — le broadcast qu'Android envoie UNIQUEMENT à l'app
 * détenant le rôle `RoleManager.ROLE_SMS` (app SMS par défaut) à l'arrivée d'un SMS.
 *
 * Responsabilités :
 *  - Parser les PDUs en [android.telephony.SmsMessage].
 *  - Écrire chaque message dans l'inbox du provider Telephony (obligatoire : en tant
 *    qu'app par défaut, l'OS ne l'écrit PLUS automatiquement, on est seul responsable).
 *  - Notifier Dart via [SmsBridge.onSmsReceived] (si Flutter est attaché).
 *
 * Si VOX n'est pas l'app SMS par défaut, ce receiver ne se déclenche jamais.
 *
 * L'I/O provider + Contacts + notification est faite hors du main thread (goAsync +
 * coroutine IO) : sinon le budget du receiver explose et l'OS tue l'app (ANR
 * « Broadcast of Intent … SMS_DELIVER has timed out »).
 */
class SmsDeliverReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return

        val messages = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "SMS_DELIVER parse failed: ${e.message}")
            return
        }
        if (messages.isNullOrEmpty()) {
            Log.w(SmsBridge.TAG, "SMS_DELIVER with empty payload")
            return
        }

        // Concaténation des parts multi-PDU par expéditeur (même burst d'arrivée).
        val grouped = messages.groupBy { it.originatingAddress ?: "?" }

        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                for ((sender, parts) in grouped) {
                    val body = parts.joinToString(separator = "") { it.messageBody ?: "" }
                    val timestamp = parts.firstOrNull()?.timestampMillis ?: System.currentTimeMillis()

                    val uri = SmsBridge.insertInbox(appContext, sender, body, timestamp)
                    val threadId = if (uri != null) SmsBridge.threadIdForSms(appContext, uri) else 0L
                    // rowId du message inséré : nécessaire côté Dart pour armer un
                    // éphémère sur un SMS reçu (sinon impossible de cibler la suppression).
                    val messageId = if (uri != null) {
                        try {
                            ContentUris.parseId(uri)
                        } catch (e: Exception) {
                            -1L
                        }
                    } else {
                        -1L
                    }

                    Log.i(
                        SmsBridge.TAG,
                        "SMS_DELIVER from ${SmsBridge.redact(sender)} (${body.length} chars, thread=$threadId)",
                    )

                    // Notifie Dart si le pont est branché. Null = Flutter pas attaché : le SMS
                    // est déjà persisté dans le provider, Dart le récupérera au prochain
                    // listConversations()/listMessages().
                    SmsBridge.onSmsReceived?.invoke(
                        mapOf(
                            "address" to sender,
                            "body" to body,
                            "date" to timestamp,
                            "threadId" to threadId,
                            "messageId" to messageId,
                        )
                    )

                    // Notification système riche (MessagingStyle + actions). Résolution
                    // contact best-effort (nom + photo), respecte les réglages et le
                    // verrou de conversation côté SmsNotifier.
                    if (threadId > 0L && sender != "?") {
                        runCatching {
                            val info = SmsBridge.lookupContact(appContext, sender)
                            SmsNotifier.notifyIncoming(
                                context = appContext,
                                threadId = threadId,
                                address = sender,
                                senderName = info.name?.takeIf { it.isNotBlank() } ?: sender,
                                body = body,
                                photoPath = info.photoPath,
                                timestamp = timestamp,
                            )
                        }
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }
}
