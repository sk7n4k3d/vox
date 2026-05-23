package chat.fluffy.fluffychat.bastien_fork.wear.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader

/**
 * Démarre le foreground service au boot de la watch pour que le sync reprenne
 * dès le démarrage, sans attendre que Bastien ouvre l'app. Réenqueue
 * également les uploads vocaux orphelins (audit finding-024).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                WearForegroundService.start(context)
                runCatching { VoiceUploader.reEnqueueOrphans(context) }
            }
        }
    }
}
