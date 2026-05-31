package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Pont natif ↔ Dart pour la couche SMS de VOX.
 *
 * MethodChannel  : `eu.devlabz.vox/sms`        (appels Dart → natif)
 * EventChannel   : `eu.devlabz.vox/sms_events` (SMS entrants natif → Dart)
 *
 * Méthodes (MethodChannel) :
 *   - isDefaultSmsApp()                         -> Boolean
 *   - requestDefaultSmsRole()                   -> Boolean (true = intent lancé)
 *   - listConversations()                       -> List<Map> {threadId,address,displayName,snippet,date,unreadCount}
 *   - listMessages(threadId: Int|Long)          -> List<Map> {id,address,body,date,isFromMe,type,status,read}
 *   - sendSms(address: String, body: String)    -> Long? (rowId) | null si échec
 *   - markRead(threadId: Int|Long)              -> Int (nb lignes mises à jour)
 *
 * Events (EventChannel) : à chaque SMS entrant, un Map est poussé :
 *   { address: String, body: String, date: Long, threadId: Long }
 *
 * Idempotent : [register] peut être appelé à chaque création d'engine sans effet de bord.
 */
class SmsBridgePlugin private constructor(
    private val context: Context,
    private val channel: MethodChannel,
    private val eventChannel: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())

    /** Activity courante, injectée par MainActivity, requise pour ACTION_REQUEST_ROLE (startActivityForResult). */
    @Volatile
    private var activity: Activity? = null

    private var eventSink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        // Branche le callback SMS entrant vers l'EventChannel.
        SmsBridge.onSmsReceived = { payload ->
            main.post { eventSink?.success(payload) }
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
            "isDefaultSmsApp" -> result.success(isDefaultSmsApp())

            "requestDefaultSmsRole" -> result.success(requestDefaultSmsRole())

            "listConversations" -> scope.launch {
                val data = SmsBridge.listConversations(context)
                replyOnMain(result) { it.success(data) }
            }

            "listMessages" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                scope.launch {
                    val data = SmsBridge.listMessages(context, threadId)
                    replyOnMain(result) { it.success(data) }
                }
            }

            "sendSms" -> {
                val address = call.argument<String>("address")
                val body = call.argument<String>("body")
                if (address.isNullOrEmpty() || body == null) {
                    result.error("BAD_ARGS", "address or body missing", null)
                    return
                }
                scope.launch {
                    val rowId = SmsBridge.sendSms(context, address, body)
                    replyOnMain(result) { it.success(rowId) }
                }
            }

            "markRead" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                scope.launch {
                    val updated = SmsBridge.markRead(context, threadId)
                    replyOnMain(result) { it.success(updated) }
                }
            }

            else -> result.notImplemented()
        }
    }

    /** Le MethodChannel.Result DOIT être appelé sur le thread main. */
    private inline fun replyOnMain(result: MethodChannel.Result, crossinline block: (MethodChannel.Result) -> Unit) {
        main.post { block(result) }
    }

    // ── Rôle app SMS par défaut ────────────────────────────────────────────────

    private fun isDefaultSmsApp(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val rm = context.getSystemService(RoleManager::class.java)
                rm != null && rm.isRoleAvailable(RoleManager.ROLE_SMS) && rm.isRoleHeld(RoleManager.ROLE_SMS)
            } else {
                context.packageName == Telephony.Sms.getDefaultSmsPackage(context)
            }
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "isDefaultSmsApp failed: ${e.message}")
            false
        }
    }

    /**
     * Lance la demande de rôle app SMS par défaut.
     *  - API 29+ : RoleManager.createRequestRoleIntent(ROLE_SMS) via startActivityForResult.
     *  - < 29    : Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT avec EXTRA_PACKAGE_NAME.
     *
     * @return true si un intent a pu être lancé, false sinon (pas d'Activity, rôle indispo, déjà défaut).
     */
    private fun requestDefaultSmsRole(): Boolean {
        if (isDefaultSmsApp()) return true
        val act = activity
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val rm = context.getSystemService(RoleManager::class.java) ?: return false
                if (!rm.isRoleAvailable(RoleManager.ROLE_SMS)) {
                    Log.w(SmsBridge.TAG, "ROLE_SMS indisponible sur cet appareil")
                    return false
                }
                val intent = rm.createRequestRoleIntent(RoleManager.ROLE_SMS)
                if (act != null) {
                    act.startActivityForResult(intent, REQUEST_CODE_SET_DEFAULT_SMS)
                } else {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                }
                true
            } else {
                @Suppress("DEPRECATION")
                val intent = Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
                    putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, context.packageName)
                }
                if (act != null) {
                    act.startActivityForResult(intent, REQUEST_CODE_SET_DEFAULT_SMS)
                } else {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                }
                true
            }
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "requestDefaultSmsRole failed: ${e.message}")
            false
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "eu.devlabz.vox/sms"
        private const val EVENT_CHANNEL = "eu.devlabz.vox/sms_events"
        const val REQUEST_CODE_SET_DEFAULT_SMS = 0x5A11 // arbitraire

        @Volatile
        private var instance: SmsBridgePlugin? = null

        /** Idempotent — peut être appelé à chaque création d'engine. */
        fun register(context: Context, engine: FlutterEngine) {
            if (instance != null) return
            val messenger = engine.dartExecutor.binaryMessenger
            val channel = MethodChannel(messenger, METHOD_CHANNEL)
            val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
            instance = SmsBridgePlugin(context.applicationContext, channel, eventChannel)
        }

        /** À appeler depuis MainActivity pour permettre startActivityForResult (ACTION_REQUEST_ROLE). */
        fun attachActivity(activity: Activity?) {
            instance?.bindActivity(activity)
        }
    }
}

/** Extrait un argument numérique de thread (Dart envoie int ou long selon la taille). */
private fun MethodCall.longArg(name: String): Long? {
    return when (val v = argument<Any>(name)) {
        is Number -> v.toLong()
        is String -> v.toLongOrNull()
        else -> null
    }
}
