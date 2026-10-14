package chat.fluffy.fluffychat.voip

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Pont natif ↔ Dart pour la couche VoIP de VOX.
 *
 * MethodChannel : `eu.devlabz.vox/voip`        (Dart → natif)
 * EventChannel  : `eu.devlabz.vox/voip_events`  (natif → Dart)
 *
 * Méthodes (MethodChannel) :
 *   - startPersistentService()   -> Boolean : maintient VOX connecté pour les appels entrants
 *   - stopPersistentService()    -> Boolean
 *   - setAudioRoute(route)       -> Boolean : "speaker" | "wired" | "bluetooth"
 *   - currentAudioRoute()        -> String  : la route active
 *   - acquireAudioFocus()        -> Boolean : coupe la musique pendant l'appel
 *   - abandonAudioFocus()        -> Boolean
 *   - startRinging(video)        -> Boolean
 *   - stopRinging()              -> Boolean
 *   - requestCallPermissions()   -> Boolean : RECORD_AUDIO + CAMERA
 *   - isCallPermissionGranted(p)-> Boolean : nom court "audio" | "camera"
 *   - isIgnoringBatteryOptimizations()    -> Boolean
 *   - requestIgnoreBatteryOptimizations() -> Boolean
 *   - nativeLog(message)         -> null
 *
 * Events (EventChannel) — une Map, discriminée par `kind` :
 *   - { kind: "incoming_call", callId, roomId, callerName, video }
 *   - { kind: "audio_route", route }
 *   - { kind: "service_killed" }
 *
 * Idempotent : [register] peut être rappelé à chaque création d'engine sans effet de bord.
 */
class VoipBridgePlugin private constructor(
    private val context: Context,
    private val channel: MethodChannel,
    private val eventChannel: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())

    /** Activity courante, injectée par MainActivity, requise pour les demandes de permission. */
    @Volatile
    private var activity: Activity? = null

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        VoipBridge.onIncomingCall = { payload ->
            main.post { eventSink?.success(HashMap<String, Any?>(payload).apply { put("kind", "incoming_call") }) }
        }
        VoipBridge.onAudioRouteChanged = { route ->
            main.post { eventSink?.success(mapOf("kind" to "audio_route", "route" to route)) }
        }
        VoipBridge.onServiceKilled = {
            main.post { eventSink?.success(mapOf("kind" to "service_killed")) }
        }
    }

    fun bindActivity(act: Activity?) {
        activity = act
    }

    // ── EventChannel ──────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── MethodChannel ─────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "nativeLog" -> {
                Log.i(VoipBridge.TAG, "[Dart] ${call.argument<String>("message")}")
                result.success(null)
            }

            "startPersistentService" -> {
                VoipBridge.startPersistent(context)
                result.success(true)
            }

            "stopPersistentService" -> {
                VoipBridge.stopPersistent(context)
                result.success(true)
            }

            "setAudioRoute" -> {
                val route = call.argument<String>("route")
                if (route.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "route missing", null)
                    return
                }
                result.success(VoipBridge.setAudioRoute(context, route))
            }

            "currentAudioRoute" -> result.success(VoipBridge.currentAudioRoute(context))

            "acquireAudioFocus" -> result.success(VoipBridge.acquireAudioFocus(context))

            "abandonAudioFocus" -> {
                VoipBridge.abandonAudioFocus(context)
                result.success(true)
            }

            "startRinging" -> {
                VoipBridge.startRinging(context, call.argument<Boolean>("video") ?: false)
                result.success(true)
            }

            "stopRinging" -> {
                VoipBridge.stopRinging(context)
                result.success(true)
            }

            "requestCallPermissions" -> result.success(requestCallPermissions())

            "isCallPermissionGranted" -> {
                val name = call.argument<String>("permission")
                result.success(isCallPermissionGranted(name))
            }

            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())

            "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())

            else -> result.notImplemented()
        }
    }

    // ── Permissions ──────────────────────────────────────────────────────────

    /**
     * Demande RECORD_AUDIO + CAMERA. La réponse est ensuite lue via
     * [isCallPermissionGranted] : l'utilisateur peut mettre quelques secondes.
     */
    private fun requestCallPermissions(): Boolean {
        val act = activity ?: return false
        return try {
            ActivityCompat.requestPermissions(
                act,
                arrayOf(
                    android.Manifest.permission.RECORD_AUDIO,
                    android.Manifest.permission.CAMERA,
                ),
                REQ_CALL_PERMS,
            )
            true
        } catch (e: Exception) {
            Log.w(VoipBridge.TAG, "requestCallPermissions failed: ${e.message}")
            false
        }
    }

    /** @param name "audio" | "camera" ; toute autre valeur → false. */
    private fun isCallPermissionGranted(name: String?): Boolean = try {
        when (name) {
            "audio" -> ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
            "camera" -> ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.CAMERA,
            ) == PackageManager.PERMISSION_GRANTED
            else -> false
        }
    } catch (e: Exception) {
        Log.w(VoipBridge.TAG, "isCallPermissionGranted failed: ${e.message}")
        false
    }

    // ── Exemption d'optimisation batterie ─────────────────────────────────────
    // Sans exemption, Android suspend le service permanent en Doze → plus aucun appel
    // entrant. Même approche que le pont SMS.

    private fun isIgnoringBatteryOptimizations(): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        pm?.isIgnoringBatteryOptimizations(context.packageName) ?: false
    } catch (e: Exception) {
        Log.e(VoipBridge.TAG, "isIgnoringBatteryOptimizations failed: ${e.message}")
        false
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
            }
            val act = activity
            if (act != null) {
                act.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            true
        } catch (e: Exception) {
            Log.e(VoipBridge.TAG, "requestIgnoreBatteryOptimizations failed: ${e.message}")
            false
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "eu.devlabz.vox/voip"
        private const val EVENT_CHANNEL = "eu.devlabz.vox/voip_events"
        const val REQ_CALL_PERMS = 4212

        @Volatile
        private var instance: VoipBridgePlugin? = null

        /**
         * Ré-enregistre les canaux sur l'engine fourni. DOIT re-bind à chaque
         * `configureFlutterEngine` : sur un Pixel Fold, plier/déplier recrée l'Activity
         * → un NOUVEL engine, et l'ancien `instance` pointerait vers un binaryMessenger
         * mort (→ MissingPluginException).
         */
        fun register(context: Context, engine: FlutterEngine) {
            val messenger = engine.dartExecutor.binaryMessenger
            val channel = MethodChannel(messenger, METHOD_CHANNEL)
            val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
            val previousActivity = instance?.activity
            instance = VoipBridgePlugin(context.applicationContext, channel, eventChannel)
            instance?.bindActivity(previousActivity)
        }

        /** À appeler depuis MainActivity pour pouvoir demander des permissions. */
        fun attachActivity(activity: Activity?) {
            instance?.bindActivity(activity)
        }
    }
}