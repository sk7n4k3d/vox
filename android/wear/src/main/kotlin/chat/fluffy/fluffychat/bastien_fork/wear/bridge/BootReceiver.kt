package chat.fluffy.fluffychat.bastien_fork.wear.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Démarre le foreground service au boot de la watch pour que le sync reprenne
 * dès le démarrage, sans attendre que Bastien ouvre l'app.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                WearForegroundService.start(context)
            }
        }
    }
}
