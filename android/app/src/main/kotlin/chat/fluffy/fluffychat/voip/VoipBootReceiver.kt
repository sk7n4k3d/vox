package chat.fluffy.fluffychat.voip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Relance le service permanent VoIP au démarrage du téléphone et après une mise à jour
 * de l'app.
 *
 * `ACTION_BOOT_COMPLETED` est indispensable : sans lui, un redémarrage du téléphone laisse
 * VOX incapable de recevoir le moindre appel tant que l'utilisateur n'a pas ouvert
 * l'app à la main.
 *
 * `ACTION_MY_PACKAGE_REPLACED` couvre la mise à jour de VOX elle-même — cas très concret
 * pour un fork sideloadé, où le process est tué à chaque installation d'APK.
 */
class VoipBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                Log.i(VoipBridge.TAG, "boot/update détecté (${intent.action}) -> service permanent")
                VoipBridge.startPersistent(context)
            }
        }
    }
}