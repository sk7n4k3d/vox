package chat.fluffy.fluffychat.bastien_fork.wear.notif

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.RemoteInput
import chat.fluffy.fluffychat.bastien_fork.wear.voice.TextUploader
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceRecordingService

/**
 * Reçoit les taps sur les actions des notifications messages :
 *  - [ACTION_VOICE_REPLY] → lance [VoiceRecordingService] en mode headless
 *    (autoUpload=true : le service upload lui-même au stop, sans UI ouverte).
 *  - [ACTION_TEXT_REPLY]  → lit le RemoteInput, pousse le texte vers le phone.
 *  - [ACTION_DISMISS]     → l'utilisateur a balayé la notif, rien à faire de spécial.
 *
 * exported=false : seules nos PendingIntent internes le déclenchent.
 */
class NotificationActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val roomId = intent.getStringExtra(EXTRA_ROOM_ID) ?: return
        val ctx = context.applicationContext
        when (intent.action) {
            ACTION_VOICE_REPLY -> {
                Log.d(TAG, "voice reply requested for ${roomId.redact()}")
                // Démarre l'enregistrement en mode auto-upload : pas d'UI nécessaire,
                // le VoiceRecordingService déclenche VoiceUploader.upload() au stop.
                // La durée est plafonnée par VoiceRecorder.MAX_DURATION_MS (auto-stop).
                VoiceRecordingService.start(ctx, roomId, autoUpload = true)
                // La notif reste affichée : l'utilisateur stoppe via l'ongoing activity
                // du service (timer REC). On ne cancel pas ici.
            }

            ACTION_TEXT_REPLY -> {
                val reply = RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(KEY_TEXT_REPLY)
                    ?.toString()
                    ?.trim()
                    .orEmpty()
                if (reply.isEmpty()) {
                    Log.d(TAG, "empty text reply, ignore")
                    return
                }
                Log.d(TAG, "text reply for ${roomId.redact()} (${reply.length} chars)")
                TextUploader.send(ctx, roomId, reply)
                // Saisie consommée → on retire la notif.
                MessageNotifier.cancelRoom(ctx, roomId)
            }

            ACTION_DISMISS -> {
                Log.d(TAG, "notif dismissed for ${roomId.redact()}")
            }
        }
    }

    companion object {
        private const val TAG = "NotifActionReceiver"

        const val KEY_TEXT_REPLY = "key_text_reply"

        private const val ACTION_VOICE_REPLY =
            "chat.fluffy.fluffychat.bastien_fork.wear.notif.VOICE_REPLY"
        private const val ACTION_TEXT_REPLY =
            "chat.fluffy.fluffychat.bastien_fork.wear.notif.TEXT_REPLY"
        private const val ACTION_DISMISS =
            "chat.fluffy.fluffychat.bastien_fork.wear.notif.DISMISS"

        const val EXTRA_ROOM_ID = "roomId"
        private const val EXTRA_NOTIF_ID = "notifId"

        fun voiceReplyIntent(context: Context, roomId: String, notifId: Int): Intent =
            Intent(context, NotificationActionReceiver::class.java).apply {
                action = ACTION_VOICE_REPLY
                putExtra(EXTRA_ROOM_ID, roomId)
                putExtra(EXTRA_NOTIF_ID, notifId)
            }

        fun textReplyIntent(context: Context, roomId: String, notifId: Int): Intent =
            Intent(context, NotificationActionReceiver::class.java).apply {
                action = ACTION_TEXT_REPLY
                putExtra(EXTRA_ROOM_ID, roomId)
                putExtra(EXTRA_NOTIF_ID, notifId)
            }

        fun dismissIntent(context: Context, roomId: String, notifId: Int): Intent =
            Intent(context, NotificationActionReceiver::class.java).apply {
                action = ACTION_DISMISS
                putExtra(EXTRA_ROOM_ID, roomId)
                putExtra(EXTRA_NOTIF_ID, notifId)
            }

        private fun String.redact(n: Int = 4): String =
            if (length <= n) this else substring(0, n) + "****"
    }
}
