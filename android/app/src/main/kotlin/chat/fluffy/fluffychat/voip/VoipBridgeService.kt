package chat.fluffy.fluffychat.voip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.AudioDeviceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Service foreground permanent qui maintient VOX en vie.
 *
 * Raison d'être : VOX n'embarque pas de FCM. Son push est UnifiedPush/ntfy, mais
 * `lib/utils/push_helper.dart` se contente de filtrer l'affichage sur `m.call.*` et ne
 * démarre aucun appel. Sans ce service, un `m.call.invite` n'atteint l'app que si le
 * process Dart vit déjà — donc jamais quand l'utilisateur a swipé l'app.
 *
 * `foregroundServiceType="specialUse"` et NON "microphone" : le micro n'est requis que
 * pendant un appel en cours, or Android interdit de démarrer un service micro depuis
 * l'arrière-plan (API 34+). Ce service ne fait que tenir le socket Matrix ouvert.
 *
 * `START_STICKY` : Android redémarre le service s'il le tue pour mémoire.
 */
class VoipBridgeService : Service() {

    private val audioManager: AudioManager? by lazy { getSystemService(AudioManager::class.java) }

    /**
     * Surveille les bascules audio : casque Bluetooth connecté en plein appel, SCO qui
     * s'arrête, périphérique filaire branché/débranché. Chaque changement est repoussé
     * vers Dart pour que l'UI affiche la bonne route (Review Focus n°3).
     */
    private val audioWatcher = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action in WATCHED_ACTIONS) {
                VoipBridge.notifyRouteChanged(context)
            }
        }
    }

    /**
     * `AudioDeviceCallback` plutôt qu'un broadcast : Android n'émet pas d'action publique
     * pour brancher/débrancher un casque, il ne propose que ce callback. C'est lui qui
     * couvre le cas « l'utilisateur branche son casque en plein appel ».
     */
    private val deviceCallback = object : android.media.AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            VoipBridge.notifyRouteChanged(this@VoipBridgeService)
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            VoipBridge.notifyRouteChanged(this@VoipBridgeService)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannels()
        startForegroundCompat()
        registerAudioWatcher()
        Log.i(VoipBridge.TAG, "service permanent démarré")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Bouton « Raccrocher » de la notification d'appel : on prévient le Dart
        // (c'est lui qui tient la session WebRTC / LiveKit) puis on se tait.
        if (intent?.action == VoipBridge.ACTION_HANGUP) {
            Log.i(VoipBridge.TAG, "raccroché depuis la notification")
            VoipBridge.onHangupRequested?.invoke()
            return START_STICKY
        }
        // START_STICKY : redémarrage par Android après un kill mémoire.
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterAudioWatcher()
        VoipBridge.onServiceKilled?.invoke()
        Log.i(VoipBridge.TAG, "service permanent arrêté")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Foreground ───────────────────────────────────────────────────────────

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(VoipBridge.CHANNEL_PERSISTENT) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    VoipBridge.CHANNEL_PERSISTENT,
                    "Appels — service permanent",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Maintient VOX connecté pour recevoir les appels entrants"
                    setShowBadge(false)
                },
            )
        }
    }

    /**
     * `startForeground` avec le type `specialUse` sur API 34+. Sans le type explicite,
     * Android lève une `ForegroundServiceStartNotAllowedException` dès que l'app
     * démarre ce service depuis le boot receiver.
     */
    private fun startForegroundCompat() {
        val notification: Notification = Notification.Builder(this, VoipBridge.CHANNEL_PERSISTENT)
            .setContentTitle("VoxOne")
            .setContentText("Connecté — prêt à recevoir les appels")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(VoipBridge.TAG, "startForeground failed: ${e.message}")
            stopSelf()
        }
    }

    private fun registerAudioWatcher() {
        val filter = IntentFilter().apply {
            WATCHED_ACTIONS.forEach { addAction(it) }
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(audioWatcher, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(audioWatcher, filter)
            }
        } catch (e: Exception) {
            Log.e(VoipBridge.TAG, "registerAudioWatcher failed: ${e.message}")
        }
        try {
            audioManager?.registerAudioDeviceCallback(deviceCallback, null)
        } catch (e: Exception) {
            Log.e(VoipBridge.TAG, "registerAudioDeviceCallback failed: ${e.message}")
        }
    }

    private fun unregisterAudioWatcher() {
        try {
            unregisterReceiver(audioWatcher)
        } catch (e: IllegalArgumentException) {
            // Receiver déjà désenregistré — sans conséquence.
        }
        try {
            audioManager?.unregisterAudioDeviceCallback(deviceCallback)
        } catch (e: Exception) {
            Log.e(VoipBridge.TAG, "unregisterAudioDeviceCallback failed: ${e.message}")
        }
    }

    companion object {
        const val NOTIFICATION_ID = 4201

        /** Actions reflétant un changement de routage audio. */
        private val WATCHED_ACTIONS = listOf(
            AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED,
            AudioManager.ACTION_AUDIO_BECOMING_NOISY,
            android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED,
            android.bluetooth.BluetoothDevice.ACTION_ACL_DISCONNECTED,
        )
    }
}