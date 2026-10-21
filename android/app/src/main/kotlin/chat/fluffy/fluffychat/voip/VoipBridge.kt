package chat.fluffy.fluffychat.voip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import chat.fluffy.fluffychat.MainActivity

/**
 * Couche native VoIP de VOX — ce qu'Android n'autorise pas au Dart.
 *
 * Trois responsabilités (cf. docs/superpowers/specs/2026-10-14-voip-call-design.md) :
 *  - [startPersistent] / [stopPersistent] : service foreground permanent démarré au boot.
 *    VOX n'a pas de FCM, et `push_helper.dart` ne démarre aucun appel sur un `m.call.*`.
 *    Sans ce service, un `m.call.invite` n'atteint l'app que si le process Dart vit déjà.
 *  - [setAudioRoute] : routage haut-parleur / écouteur filaire / Bluetooth, avec repousse
 *    de chaque changement vers Dart (le casque peut se connecter APRÈS le début de l'appel).
 *  - [startRinging] / [stopRinging] : sonnerie d'appel entrant sur le canal audio du
 *    haut-parleur + vibration, sans toucher au volume système.
 *
 * Aucun état métier ici : le client Matrix (Dart) EST l'état. Les callbacks sont posés
 * par [VoipBridgePlugin] et routés vers l'EventChannel.
 *
 * Compatible GrapheneOS : aucune dépendance Play Services.
 */
object VoipBridge {

    const val TAG = "VoipBridge"

    /** Canal de la notification « service permanent ». IMPORTANCE_MIN : jamais de son. */
    const val CHANNEL_PERSISTENT = "voip_persistent"

    /** Canal de la sonnerie d'appel entrant. IMPORTANCE_LOW : on gère le son nous-mêmes. */
    const val CHANNEL_INCALL = "voip_incall"

    /** Canal de la notification « appel en cours ». IMPORTANCE_LOW : le son est géré par nous. */
    const val CHANNEL_CALL = "voip_call"

    /** Id de la notification d'appel (distincte du service permanent). */
    private const val NOTIFICATION_ID_CALL = 2002

    /** Action du bouton « Raccrocher » de la notification d'appel. */
    const val ACTION_HANGUP = "eu.devlabz.vox.voip.HANGUP"

    /** Callback : l'utilisateur a appuyé sur « Raccrocher » dans la notification. */
    @Volatile
    var onHangupRequested: (() -> Unit)? = null

    /**
     * Callback poussé quand un `m.call.invite` est reçu.
     * Map : { callId: String, roomId: String, callerName: String, video: Boolean }
     */
    @Volatile
    var onIncomingCall: ((Map<String, Any?>) -> Unit)? = null

    /**
     * Callback poussé à chaque bascule de routage audio : un casque Bluetooth se connecte
     * ou se déconnecte en plein appel, et le Dart doit refléter l'état (Review Focus n°3).
     * Valeur : "speaker" | "wired" | "bluetooth".
     */
    @Volatile
    var onAudioRouteChanged: ((String) -> Unit)? = null

    /** Callback poussé quand Android tue le service — le Dart doit le savoir pour ne pas mentir. */
    @Volatile
    var onServiceKilled: (() -> Unit)? = null

    // ── Service permanent ────────────────────────────────────────────────────

    /** Démarre (ou relance) le service foreground permanent. Idempotent. */
    fun startPersistent(context: Context) {
        try {
            val intent = android.content.Intent(context, VoipBridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startPersistent failed: ${e.message}")
        }
    }

    /** Arrête le service permanent. Appelé au force-stop explicite et au nettoyage complet. */
    fun stopPersistent(context: Context) {
        try {
            context.stopService(android.content.Intent(context, VoipBridgeService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "stopPersistent failed: ${e.message}")
        }
    }

    // ── Routage audio ────────────────────────────────────────────────────────

    /**
     * Bascule la sortie audio de l'appel en cours.
     * @param route "speaker" | "wired" | "bluetooth"
     * @return true si la bascule a été demandée sans exception.
     */
    fun setAudioRoute(context: Context, route: String) = try {
        val am = context.getSystemService(AudioManager::class.java) ?: return false
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        // API 31+ : une seule API couvre les 3 routes. En dessous, on retombe sur
        // les setters dépréciés (SCO + speakerphone), qui fonctionnent encore.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = when (route) {
                "bluetooth" -> am.availableCommunicationDevices.firstOrNull { it.type ==
                    android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                "wired" -> am.availableCommunicationDevices.firstOrNull { it.type ==
                    android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET }
                "speaker" -> am.availableCommunicationDevices.firstOrNull { it.type ==
                    android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                // Contre-oreille : la route d'un appel telephonique normal. C est elle
                // qui manquait, ce qui forcait tout le reste a retomber sur le speaker.
                else -> am.availableCommunicationDevices.firstOrNull { it.type ==
                    android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
            }
            if (device != null) {
                am.clearCommunicationDevice()
                am.setCommunicationDevice(device)
                Log.i(TAG, "setAudioRoute($route) -> ${device.productName}")
                true
            } else {
                Log.w(TAG, "setAudioRoute($route): aucun device de ce type")
                false
            }
        } else {
            @Suppress("DEPRECATION")
            when (route) {
                "bluetooth" -> {
                    am.isSpeakerphoneOn = false
                    am.isBluetoothScoOn = true
                    am.startBluetoothSco()
                }
                "wired" -> {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                    am.isSpeakerphoneOn = false
                }
                "speaker" -> {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                    am.isSpeakerphoneOn = true
                }
                // Contre-oreille : haut-parleur coupe, c est la route par defaut.
                else -> {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                    am.isSpeakerphoneOn = false
                }
            }
            Log.i(TAG, "setAudioRoute($route) (legacy)")
            true
        }
    } catch (e: Exception) {
        Log.e(TAG, "setAudioRoute failed: ${e.message}")
        false
    }

    /** Route audio courante, déduite de la liste des périphériques actifs. */
    fun currentAudioRoute(context: Context): String = try {
        val am = context.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            val t = am.communicationDevice?.type
            when (t) {
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth"
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
                android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                // Contre-oreille et tout le reste : la route d un appel normal.
                else -> "earpiece"
            }
        } else {
            @Suppress("DEPRECATION")
            if (am?.isBluetoothScoOn == true) "bluetooth" else if (am?.isSpeakerphoneOn == true) "speaker" else "earpiece"
        }
    } catch (e: Exception) {
        Log.e(TAG, "currentAudioRoute failed: ${e.message}")
        "earpiece"
    }

    /** Repousse la route courante vers Dart (appelé par le receiver SCO / A2DP). */
    fun notifyRouteChanged(context: Context) {
        onAudioRouteChanged?.invoke(currentAudioRoute(context))
    }

    // ── Capteur de proximite ────────────────────────────────────────────────

    private var proximitySensor: android.hardware.Sensor? = null
    private var proximityRegistered = false

    /** Contexte conserve au demarrage : le listener le reference et il n'en a pas. */
    @Volatile
    private var proximityContext: Context? = null

    private val proximityListener = object : android.hardware.SensorEventListener {
        override fun onSensorChanged(event: android.hardware.SensorEvent) {
            // Valeur < 1 cm = phone contre l'oreille.
            val ctx = proximityContext ?: return
            val near = event.values.getOrNull(0)?.let { it < 1f } ?: false
            val route = if (near) "earpiece" else "speaker"
            if (setAudioRoute(ctx, route)) {
                onAudioRouteChanged?.invoke(route)
            }
        }

        override fun onAccuracyChanged(sensor: android.hardware.Sensor?, accuracy: Int) = Unit
    }

    /**
     * Ecoute le capteur de proximite pendant un appel : contre-oreille quand le
     * telephone est colle a la tete, haut-parleur quand il s'en eloigne.
     *
     * Registre UNIQUEMENT en appel — le service tourne en permanence, et laisser ce
     * capteur actif en dehors d'un appel consumerait de la batterie pour rien.
     *
     * @return false si le capteur n'existe pas sur l'appareil (l'appel reste utilisable).
     */
    @Synchronized
    fun startProximityWatch(context: Context): Boolean {
        if (proximityRegistered) return true
        return try {
            val sm = context.getSystemService(android.content.Context.SENSOR_SERVICE)
                as? android.hardware.SensorManager ?: return false
            proximitySensor = sm.getDefaultSensor(android.hardware.Sensor.TYPE_PROXIMITY)
            val sensor = proximitySensor ?: return false
            proximityContext = context
            proximityRegistered = sm.registerListener(
                proximityListener,
                sensor,
                android.hardware.SensorManager.SENSOR_DELAY_NORMAL,
            )
            Log.i(TAG, "capteur de proximite ecoute")
            proximityRegistered
        } catch (e: Exception) {
            Log.e(TAG, "startProximityWatch failed: ${e.message}")
            false
        }
    }

    /** Arrete l'ecoute du capteur. Idempotent. */
    @Synchronized
    fun stopProximityWatch(context: Context) {
        if (!proximityRegistered) return
        try {
            val sm = context.getSystemService(android.content.Context.SENSOR_SERVICE)
                as? android.hardware.SensorManager
            sm?.unregisterListener(proximityListener)
            proximityRegistered = false
            proximityContext = null
        } catch (e: Exception) {
            Log.e(TAG, "stopProximityWatch failed: ${e.message}")
        }
    }

    // ── Focus audio ──────────────────────────────────────────────────────────

    private var focusRequest: AudioFocusRequest? = null

    /**
     * Prend le focus audio pour couper la musique pendant l'appel.
     * @return true si le focus est obtenu (ou déjà tenu par nous).
     */
    fun acquireAudioFocus(context: Context): Boolean = try {
        // Le focus audio marque le debut d'un appel : c'est le bon moment pour
        // ecouter le capteur de proximite (et le seul).
        startProximityWatch(context)
        val am = context.getSystemService(AudioManager::class.java) ?: return false
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                null,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
        result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    } catch (e: Exception) {
        Log.e(TAG, "acquireAudioFocus failed: ${e.message}")
        false
    }

    /** Rend le focus audio. Idempotent. */
    fun abandonAudioFocus(context: Context) {
        try {
            val am = context.getSystemService(AudioManager::class.java) ?: return
            stopProximityWatch(context)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "abandonAudioFocus failed: ${e.message}")
        }
    }

    // ── Sonnerie d'appel entrant ─────────────────────────────────────────────

    private var ringing = false

    /// LA sonnerie en cours : stop() doit viser cette instance, pas un objet
    /// frais (un Ringtone fraichement cree ne stoppe rien du tout — bug
    /// "sonnerie infinie" constaté sur le terrain le 15/10).
    private var currentRingtone: android.media.Ringtone? = null

    /** Démarre la sonnerie (son par défaut du système + vibration). Idempotent. */
    fun startRinging(context: Context, video: Boolean) {
        if (ringing) return
        ringing = true
        try {
            val uri = RingtoneManager.getDefaultUri(
                if (video) RingtoneManager.TYPE_RINGTONE else RingtoneManager.TYPE_RINGTONE,
            )
            val player = RingtoneManager.getRingtone(context, uri)
            currentRingtone = player
            if (player != null) {
                // Flux ALARME et non RING : en mode communication, le flux RING
                // est reroute vers l'ecouteur (l'appareil en communication), donc
                // la sonnerie sortait de l'ecouteur — inaudible. Le flux
                // alarme, lui, reste sur le haut-parleur.
                player.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                player.play()
            }
            vibrate(context, true)
        } catch (e: Exception) {
            Log.e(TAG, "startRinging failed: ${e.message}")
        }
    }

    /** Arrête la sonnerie. Idempotent, sans exception si elle n'a jamais tourné. */
    fun stopRinging(context: Context) {
        if (!ringing) return
        ringing = false
        try {
            currentRingtone?.stop()
            currentRingtone = null
        } catch (e: Exception) {
            Log.e(TAG, "stopRinging failed: ${e.message}")
        }
        vibrate(context, false)
    }

    private fun vibrate(context: Context, on: Boolean) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Vibrator::class.java)
            } ?: return
            if (on) {
                vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 800, 500), 0))
            } else {
                vibrator.cancel()
            }
        } catch (e: Exception) {
            Log.e(TAG, "vibrate failed: ${e.message}")
        }
    }

    // ── Notification d'appel ─────────────────────────────────────────────────

    /**
     * Notification d'appel : QUI on appelle / qui nous appelle, et l'etat.
     *
     * Un appui ouvre l'app (l'ecran d'appel est re-empile au retour au premier
     * plan), l'action « Raccrocher » termine l'appel sans rouvrir l'app.
     */
    fun showCallNotification(
        context: Context,
        title: String,
        text: String,
        ongoing: Boolean,
    ) {
        try {
            val mgr = context.getSystemService(NotificationManager::class.java) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                mgr.getNotificationChannel(CHANNEL_CALL) == null
            ) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_CALL,
                        "Appels",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Appel en cours : appui pour reprendre l'appel"
                        setShowBadge(false)
                        enableVibration(false)
                    },
                )
            }
            val openIntent = android.content.Intent(context, MainActivity::class.java).apply {
                addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
            }
            val openPending = PendingIntent.getActivity(
                context,
                4201,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val hangupPending = PendingIntent.getBroadcast(
                context,
                4202,
                android.content.Intent(context, VoipBridgeService::class.java)
                    .setAction(ACTION_HANGUP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = Notification.Builder(context, CHANNEL_CALL)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_call)
                .setOngoing(ongoing)
                .setContentIntent(openPending)
                .setCategory(Notification.CATEGORY_CALL)
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "Raccrocher",
                        hangupPending,
                    ).build(),
                )
                .build()
            mgr.notify(NOTIFICATION_ID_CALL, notification)
        } catch (e: Exception) {
            Log.e(TAG, "showCallNotification failed: ${e.message}")
        }
    }

    /** Retire la notification d'appel (appel terminé). */
    fun clearCallNotification(context: Context) {
        try {
            val mgr = context.getSystemService(NotificationManager::class.java) ?: return
            mgr.cancel(NOTIFICATION_ID_CALL)
        } catch (e: Exception) {
            Log.e(TAG, "clearCallNotification failed: ${e.message}")
        }
    }

    // ── Sonnerie d'attente (appel sortant) ───────────────────────────────────

    private var ringbackTone: ToneGenerator? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** TONE_SUP_RINGTONE = la cadence « ca sonne chez l'autre » (2 s / 4 s). */
    private val ringbackLoop = object : Runnable {
        override fun run() {
            try {
                ringbackTone?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 6000)
            } catch (e: Exception) {
                Log.w(TAG, "ringback loop: ${e.message}")
            }
            mainHandler.postDelayed(this, 6000)
        }
    }

    /**
     * Sonnerie d'attente de l'appel SORTANT : en VoIP le reseau ne fournit
     * aucun signal « ca sonne chez l'autre », on n'entendait donc rien. Elle
     * passe par le canal vocal (comme une vraie ligne) et s'arrete des que
     * l'appel est repondu.
     */
    fun startRingback(context: Context) {
        if (ringbackTone != null) return
        try {
            ringbackTone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70)
            mainHandler.post(ringbackLoop)
            Log.i(TAG, "sonnerie d'attente active")
        } catch (e: Exception) {
            Log.e(TAG, "startRingback failed: ${e.message}")
        }
    }

    /** Arrete la sonnerie d'attente. Idempotent. */
    fun stopRingback(context: Context) {
        try {
            mainHandler.removeCallbacks(ringbackLoop)
            ringbackTone?.stopTone()
            ringbackTone?.release()
            ringbackTone = null
        } catch (e: Exception) {
            Log.e(TAG, "stopRingback failed: ${e.message}")
        }
    }
}
