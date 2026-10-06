package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.util.Log
import chat.fluffy.fluffychat.media.MediaExporter
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
 *                                                  (inclut désormais les threads MMS-only)
 *   - listMessages(threadId: Int|Long)          -> List<Map> {id,address,body,date,isFromMe,type,status,read,
 *                                                              isMms:Bool, attachments:List<{partId,mimeType,fileName}>}
 *                                                  (SMS + MMS fusionnés, triés par date ; attachments vide pour les SMS)
 *   - sendSms(address: String, body: String)    -> Long? (rowId) | null si échec
 *   - sendMms(address: String, body: String?, imagePath: String?)
 *                                               -> Long? (mmsId Outbox) | null si échec. Best-effort carrier.
 *   - loadMmsPart(partId: Int|Long)             -> String? (path du fichier cache écrit) | null si échec
 *   - exportMediaFile(filePath, mimeType, displayName) -> String? (URI MediaStore) | null
 *   - markRead(threadId: Int|Long)              -> Int (nb lignes mises à jour)
 *
 * Events (EventChannel) : à chaque message entrant, un Map est poussé avec un champ `kind` :
 *   - SMS : { kind:"sms", address: String, body: String, date: Long, threadId: Long }
 *   - MMS : { kind:"mms", mimeType: String, date: Long }
 *           (best-effort : signale qu'un MMS arrive ; Dart doit refresh listMessages peu après,
 *            le download du corps est asynchrone — cf. MmsDeliverReceiver)
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

    // @Volatile : écrit sur le main thread (onListen/onCancel) mais potentiellement
    // lu depuis le thread d'un BroadcastReceiver (onSmsReceived) → garantir la
    // visibilité de la dernière valeur.
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        // Branche le callback SMS entrant vers l'EventChannel.
        // Le payload SMS conserve son schéma Étape 1 ; on ajoute juste `kind="sms"` (additif).
        SmsBridge.onSmsReceived = { payload ->
            val enriched = HashMap<String, Any?>(payload).apply { put("kind", "sms") }
            main.post { eventSink?.success(enriched) }
        }

        // Branche le callback MMS entrant (WAP_PUSH) vers le même EventChannel avec `kind="mms"`.
        // Best-effort : signale juste « un MMS arrive », Dart doit refresh peu après (cf.
        // MmsDeliverReceiver — le download du corps est asynchrone, géré par la stack système).
        SmsBridge.onMmsReceived = { payload ->
            val enriched = HashMap<String, Any?>(payload).apply { put("kind", "mms") }
            main.post { eventSink?.success(enriched) }
        }
    }

    fun bindActivity(act: Activity?) {
        activity = act
    }

    /** Pousse un event "open_conversation" à Flutter via l'EventChannel SMS. */
    fun pushIntentEvent(payload: Map<String, Any?>) {
        main.post { eventSink?.success(payload) }
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
                android.util.Log.i(SmsBridge.TAG, "[Dart] ${call.argument<String>("message")}")
                result.success(null)
            }

            "isDefaultSmsApp" -> result.success(isDefaultSmsApp())

            "requestDefaultSmsRole" -> result.success(requestDefaultSmsRole())

            "isIgnoringBatteryOptimizations" ->
                result.success(isIgnoringBatteryOptimizations())

            "requestIgnoreBatteryOptimizations" ->
                result.success(requestIgnoreBatteryOptimizations())

            // Réseau actif en Wi-Fi ? Sert au réglage « réessayer seulement en
            // Wi-Fi » de la file d'envoi du webhook.
            "isOnWifi" -> result.success(isOnWifi())

            // Retire la notification d'un thread (appelé quand Dart ouvre/lit la conv).
            "cancelSmsNotification" -> {
                val threadId = call.longArg("threadId")
                if (threadId != null) SmsNotifier.cancel(context, threadId)
                result.success(null)
            }

            // Mémorise le thread actuellement affiché au premier plan (ou -1) pour
            // que SmsNotifier ne notifie pas une conversation déjà ouverte.
            "setActiveSmsThread" -> {
                val threadId = call.longArg("threadId") ?: -1L
                SmsNotifier.activeThreadId = threadId
                result.success(null)
            }

            // Consomme l'intent SMS en attente (tap notif / Vocal) au démarrage.
            "getPendingSmsIntent" -> {
                val pending = pendingSmsIntent
                pendingSmsIntent = null
                result.success(pending)
            }

            "listConversations" -> launchReply(result) {
                SmsBridge.listConversations(context)
            }

            "listContacts" -> launchReply(result) {
                SmsBridge.listContacts(context)
            }

            "listMessages" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                val limit = (call.argument<Number>("limit"))?.toInt() ?: 0
                val beforeMs = call.longArg("beforeMs") ?: 0L
                launchReply(result) {
                    SmsBridge.listMessages(context, threadId, limit, beforeMs)
                }
            }

            "sendSms" -> {
                val address = call.argument<String>("address")
                val body = call.argument<String>("body")
                if (address.isNullOrEmpty() || body == null) {
                    result.error("BAD_ARGS", "address or body missing", null)
                    return
                }
                launchReply(result) { SmsBridge.sendSms(context, address, body) }
            }

            "markRead" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                launchReply(result) { SmsBridge.markRead(context, threadId) }
            }

            "deleteMessage" -> {
                val id = call.longArg("id")
                val isMms = call.argument<Boolean>("isMms") ?: false
                if (id == null) {
                    result.error("BAD_ARGS", "id missing", null)
                    return
                }
                launchReply(result) { SmsBridge.deleteMessage(context, id, isMms) }
            }

            "deleteConversation" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                launchReply(result) { SmsBridge.deleteConversation(context, threadId) }
            }

            "loadMmsPart" -> {
                val partId = call.longArg("partId")
                if (partId == null) {
                    result.error("BAD_ARGS", "partId missing", null)
                    return
                }
                launchReply(result) { SmsBridge.loadMmsPart(context, partId) }
            }

            // Parts d'un MMS (partId + type MIME + nom) : le webhook en dérive le
            // média à archiver, avant de lire chaque part via loadMmsPart.
            "listMmsParts" -> launchReply(result) {
                val mmsId = call.longArg("mmsId")
                if (mmsId == null || mmsId <= 0) {
                    emptyList<Map<String, Any?>>()
                } else {
                    SmsBridge.listMmsParts(context, mmsId)
                }
            }

            // Exposes a local image/video file to the public MediaStore gallery
            // (Pictures/VOX, Movies/VOX). Returns the media URI, or null when the
            // export is unavailable (API < 29), disabled, or already done.
            "exportMediaFile" -> {
                val filePath = call.argument<String>("filePath")
                val mimeType = call.argument<String>("mimeType")
                val displayName = call.argument<String>("displayName")
                val dateTakenMs = call.argument<Number>("dateTakenMs")?.toLong()
                if (filePath.isNullOrEmpty() || mimeType.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "filePath or mimeType missing", null)
                    return
                }
                Log.i(SmsBridge.TAG, "exportMediaFile: dateTakenMs=$dateTakenMs")
                launchReply(result) {
                    if (!MediaExporter.isEnabled(context)) return@launchReply null
                    MediaExporter.export(
                        context,
                        filePath,
                        mimeType,
                        displayName ?: filePath.substringAfterLast('/'),
                        dateTakenMs,
                    )
                }
            }

            // Nom du contact associé à une adresse (champ « contact » du
            // webhook). Null si l'adresse n'est pas dans les contacts.
            "resolveContactName" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrEmpty()) {
                    launchReply(result) { null }
                } else {
                    launchReply(result) {
                        SmsBridge.lookupContact(context, address).name
                    }
                }
            }

            // Balaye TOUTES les parts image/vidéo de TOUS les MMS (content://mms/part)
            // et les copie dans la galerie, sans ouvrir de conversation. Retourne
            // le nombre de parts nouvellement exportées.
            "exportAllMmsMedia" -> launchReply(result) {
                if (!MediaExporter.isEnabled(context)) return@launchReply 0
                SmsBridge.exportAllMmsMedia(
                    context,
                    call.argument<Number>("threadId")?.toLong(),
                )
            }

            // ── Blocage de numéros (blacklist système BlockedNumberContract) ──────
            "isBlocked" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "address missing", null)
                    return
                }
                launchReply(result) { BlockedNumbers.isBlocked(context, address) }
            }

            "blockNumber" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "address missing", null)
                    return
                }
                launchReply(result) { BlockedNumbers.block(context, address) }
            }

            "unblockNumber" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "address missing", null)
                    return
                }
                launchReply(result) { BlockedNumbers.unblock(context, address) }
            }

            "listBlockedNumbers" -> {
                launchReply(result) { BlockedNumbers.list(context) }
            }

            // ── Export / backup JSON (Documents de l'app, sans permission) ────────
            "exportSms" -> {
                val threadId = call.longArg("threadId") ?: 0L
                launchReply(result) { SmsBridge.exportSms(context, threadId) }
            }

            // ── Filtre spam local (set natif persistant consulté par SmsNotifier) ──
            "markThreadSpam" -> {
                val threadId = call.longArg("threadId")
                if (threadId == null) {
                    result.error("BAD_ARGS", "threadId missing", null)
                    return
                }
                val spam = call.argument<Boolean>("spam") ?: true
                launchReply(result) {
                    SpamFilter.mark(context, threadId, spam)
                    null
                }
            }

            "listSpamThreads" -> {
                launchReply(result) { SpamFilter.list(context) }
            }

            "sendMms" -> {
                val address = call.argument<String>("address")
                val body = call.argument<String>("body")          // nullable
                val imagePath = call.argument<String>("imagePath") // nullable
                if (address.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "address missing", null)
                    return
                }
                if (body.isNullOrEmpty() && imagePath.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "need body or imagePath", null)
                    return
                }
                launchReply(result) { SmsBridge.sendMms(context, address, body, imagePath) }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Lance [work] sur [scope] et route TOUJOURS une réponse au Result (succès
     * ou erreur), sur le main thread. Sans le try/catch, une exception dans
     * `work` (SecurityException/SQLiteException du ContentResolver, etc.)
     * laissait le Future Dart pending pour toujours → hang silencieux de l'UI.
     */
    private inline fun <T> launchReply(
        result: MethodChannel.Result,
        crossinline work: suspend () -> T,
    ) {
        scope.launch {
            try {
                val data = work()
                replyOnMain(result) { it.success(data) }
            } catch (e: Throwable) {
                Log.e(SmsBridge.TAG, "SMS method failed: ${e.message}")
                replyOnMain(result) { it.error("SMS_ERR", e.message, null) }
            }
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

    // ── Exemption d'optimisation batterie (Doze) ───────────────────────────────
    // Indispensable pour une app SMS par défaut : sans exemption, en Doze profond
    // / standby bucket bas, Android DIFFÈRE le réveil du process pour le broadcast
    // SMS_DELIVER → SMS reçus en retard ou ratés quand l'app est fermée (Matrix y
    // échappe via son push FCM). Même approche que Signal / QKSMS.

    /** True si le réseau actif est un Wi-Fi (« réessayer seulement en Wi-Fi »). */
    private fun isOnWifi(): Boolean = try {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        if (cm == null) {
            false
        } else {
            val network = cm.activeNetwork
            val caps = if (network == null) null else cm.getNetworkCapabilities(network)
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    } catch (e: Exception) {
        Log.w(SmsBridge.TAG, "isOnWifi failed: ${e.message}")
        false
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            pm?.isIgnoringBatteryOptimizations(context.packageName) ?: false
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "isIgnoringBatteryOptimizations failed: ${e.message}")
            false
        }
    }

    /**
     * Ouvre le prompt système « ignorer l'optimisation batterie » pour VOX. Intent
     * direct [android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS]
     * (autorisé hors Play Store ; VOX est sideloadée), nécessite la permission
     * REQUEST_IGNORE_BATTERY_OPTIMIZATIONS dans le manifest.
     * @return true si déjà exempté, ou si l'intent a pu être lancé.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            val intent = Intent(
                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            ).apply { data = android.net.Uri.parse("package:${context.packageName}") }
            val act = activity
            if (act != null) {
                act.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            true
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "requestIgnoreBatteryOptimizations failed: ${e.message}")
            false
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "eu.devlabz.vox/sms"
        private const val EVENT_CHANNEL = "eu.devlabz.vox/sms_events"
        const val REQUEST_CODE_SET_DEFAULT_SMS = 0x5A11 // arbitraire

        @Volatile
        private var instance: SmsBridgePlugin? = null

        /**
         * Intent SMS en attente (tap notif / action Vocal / ouverture sms:) que
         * Flutter consomme au démarrage via getPendingSmsIntent. Si l'app est
         * déjà ouverte, on le pousse aussi en direct via l'EventChannel.
         */
        @Volatile
        private var pendingSmsIntent: Map<String, Any?>? = null

        /**
         * Ré-enregistre les canaux sur l'engine fourni. DOIT re-bind à chaque
         * `configureFlutterEngine` : sur un Pixel Fold, plier/déplier recrée
         * l'Activity → un NOUVEL engine, et l'ancien `instance` pointerait vers
         * un binaryMessenger mort (→ MissingPluginException). On préserve
         * l'Activity déjà attachée pour ne pas perdre le startActivityForResult.
         */
        fun register(context: Context, engine: FlutterEngine) {
            val messenger = engine.dartExecutor.binaryMessenger
            val channel = MethodChannel(messenger, METHOD_CHANNEL)
            val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
            val previousActivity = instance?.activity
            instance = SmsBridgePlugin(context.applicationContext, channel, eventChannel)
            instance?.bindActivity(previousActivity)
        }

        /** À appeler depuis MainActivity pour permettre startActivityForResult (ACTION_REQUEST_ROLE). */
        fun attachActivity(activity: Activity?) {
            instance?.bindActivity(activity)
        }

        /** Stocke l'intent SMS entrant et, si l'app tourne, le pousse à Flutter. */
        fun setPendingSmsIntent(threadId: Long, address: String?, voiceReply: Boolean) {
            val payload = mapOf(
                "kind" to "open_conversation",
                "threadId" to threadId,
                "address" to (address ?: ""),
                "voiceReply" to voiceReply,
            )
            pendingSmsIntent = payload
            // Pousse en direct si un sink est branché (app déjà au premier plan).
            instance?.pushIntentEvent(payload)
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
