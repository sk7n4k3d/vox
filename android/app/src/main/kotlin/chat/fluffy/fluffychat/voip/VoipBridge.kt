package chat.fluffy.fluffychat.voip

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

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

    // ── Focus audio ──────────────────────────────────────────────────────────

    private var focusRequest: AudioFocusRequest? = null

    /**
     * Prend le focus audio pour couper la musique pendant l'appel.
     * @return true si le focus est obtenu (ou déjà tenu par nous).
     */
    fun acquireAudioFocus(context: Context): Boolean = try {
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

    /** Démarre la sonnerie (son par défaut du système + vibration). Idempotent. */
    fun startRinging(context: Context, video: Boolean) {
        if (ringing) return
        ringing = true
        try {
            val uri = RingtoneManager.getDefaultUri(
                if (video) RingtoneManager.TYPE_RINGTONE else RingtoneManager.TYPE_RINGTONE,
            )
            val player = RingtoneManager.getRingtone(context, uri)
            if (player != null) {
                player.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
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
            RingtoneManager.getRingtone(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
                ?.stop()
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
}