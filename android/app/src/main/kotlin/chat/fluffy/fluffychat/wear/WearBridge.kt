package chat.fluffy.fluffychat.wear

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.charset.StandardCharsets

/**
 * Bridge wear côté phone — singleton, sait :
 *  - pousser un DataItem `/wear/rooms` (payload JSON raw) via DataClient.
 *  - notifier la couche Dart quand la watch ping `/wear/rooms/request`.
 *
 * Le payload JSON est produit côté Dart (`lib/utils/wear_bridge.dart`) et passé tel
 * quel via le MethodChannel `chat.fluffy.fluffychat/wear_bridge`. Aucune logique
 * Matrix n'est faite ici — le phone reste source de vérité.
 */
object WearBridge {

    private const val TAG = "WearBridge"
    private const val DATA_PATH = "/wear/rooms"
    private const val PING_PATH = "/wear/rooms/ping"
    private const val WATCH_CAPABILITY = "fluffychat_watch"
    private const val DATA_KEY = "payload"
    private const val UPDATED_KEY = "updatedAt"

    // Plafond d'un vocal lu en RAM depuis un Asset DataLayer (anti-OOM sur Asset
    // forgé/volumineux). 8 Mo = très large pour un message vocal Opus.
    private const val MAX_VOICE_BYTES = 8 * 1024 * 1024

    // Forme d'un uuid watch acceptable comme composant de nom de fichier / de
    // chemin : alphanumérique + tirets uniquement, longueur bornée. Bloque `../`.
    private val UUID_RE = Regex("""^[A-Za-z0-9-]{8,64}$""")

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * log-sensitive-001 — tronque un identifiant sensible (roomId, uuid) avant
     * logging : seuls les 4 premiers caractères restent. Évite de leaker la
     * topologie des rooms Matrix dans logcat.
     */
    private fun String.redact(n: Int = 4): String =
        if (length <= n) this else substring(0, n) + "****"

    /** Callback enregistré par le plugin Flutter pour relayer un ping watch→Dart. */
    @Volatile
    var refreshRequestedCallback: (() -> Unit)? = null

    /** Callback enregistré par le plugin Flutter pour traiter un vocal reçu de la watch. */
    @Volatile
    var voiceReceivedCallback: ((VoiceMessage) -> Unit)? = null

    /** Callback Flutter pour pousser les messages d'une room donnée. */
    @Volatile
    var messagesRequestedCallback: ((String) -> Unit)? = null

    fun pushRoomsJson(context: Context, json: String) {
        scope.launch {
            try {
                val bytes = json.toByteArray(StandardCharsets.UTF_8)
                val req = PutDataMapRequest.create(DATA_PATH).apply {
                    dataMap.putByteArray(DATA_KEY, bytes)
                    dataMap.putLong(UPDATED_KEY, System.currentTimeMillis())
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(req).await()
                Log.d(TAG, "pushed ${bytes.size} bytes to $DATA_PATH")
                pingWatch(context)
            } catch (t: Throwable) {
                Log.w(TAG, "pushRoomsJson failed", t)
            }
        }
    }

    /**
     * Ping immédiat de la watch via MessageClient — la watch reçoit le ping en cloud
     * 1-3 s, ce qui la réveille pour forcer un readCurrent() du DataItem propagé.
     * Sans ce ping, la propagation DataItem en mode cloud-routed (hops=2, isNearby=false)
     * peut prendre 5-30 s.
     */
    private suspend fun pingWatch(context: Context) {
        try {
            val info = Wearable.getCapabilityClient(context)
                .getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val nodes = info.nodes
            if (nodes.isEmpty()) {
                Log.d(TAG, "ping skipped — no watch node reachable")
                return
            }
            val messageClient = Wearable.getMessageClient(context)
            for (node in nodes) {
                try {
                    messageClient.sendMessage(node.id, PING_PATH, ByteArray(0)).await()
                    Log.d(TAG, "ping sent to ${node.displayName}")
                } catch (t: Throwable) {
                    Log.w(TAG, "ping failed for ${node.displayName}", t)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "pingWatch lookup failed", t)
        }
    }

    fun notifyRefreshRequested(context: Context) {
        Log.d(TAG, "watch requested refresh")
        refreshRequestedCallback?.invoke()
    }

    fun notifyMessagesRequested(context: Context, roomId: String) {
        Log.d(TAG, "watch requested messages for ${roomId.redact()}")
        messagesRequestedCallback?.invoke(roomId)
    }

    /**
     * Push les messages d'une room sur path `/wear/rooms/{roomId}/messages`.
     * Appelé par Dart via MethodChannel `pushMessages`.
     */
    fun pushMessagesJson(context: Context, roomId: String, json: String) {
        scope.launch {
            try {
                val bytes = json.toByteArray(StandardCharsets.UTF_8)
                val req = PutDataMapRequest.create("/wear/rooms/$roomId/messages").apply {
                    dataMap.putByteArray(DATA_KEY, bytes)
                    dataMap.putLong(UPDATED_KEY, System.currentTimeMillis())
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(req).await()
                Log.d(TAG, "pushed ${bytes.size} bytes messages for ${roomId.redact()}")
            } catch (t: Throwable) {
                Log.w(TAG, "pushMessagesJson failed for ${roomId.redact()}", t)
            }
        }
    }

    /**
     * Lit l'audio depuis l'Asset DataLayer (FD blocking → bytes) puis push à Dart.
     * À exécuter dans un coroutine IO.
     */
    fun handleIncomingVoice(
        context: Context,
        uuid: String,
        roomId: String,
        durationMs: Int,
        mimeType: String,
        asset: Asset
    ) {
        // Ceinture + bretelles : le service valide déjà, mais un appel direct
        // (autre chemin) ne doit pas pouvoir injecter un uuid de traversée.
        if (!UUID_RE.matches(uuid)) {
            Log.w(TAG, "handleIncomingVoice: uuid invalide, rejeté")
            return
        }
        scope.launch {
            try {
                // wear-002 — GetFdForAssetResponse détient un ParcelFileDescriptor
                // interne ; fermer seulement l'inputStream ne le libère PAS. Le
                // response implémente Releasable : release() en finally libère le
                // PFD sur toutes les sorties (sinon fuite de fd côté phone → EMFILE
                // après N pertes réseau).
                val fdResponse = Wearable.getDataClient(context).getFdForAsset(asset).await()
                val bytes = try {
                    fdResponse.inputStream.use { it.readAllBytesCompat() }
                } finally {
                    fdResponse.release()
                }
                Log.d(TAG, "voice bytes received: ${bytes.size} uuid=${uuid.redact()}")
                val msg = VoiceMessage(
                    uuid = uuid,
                    roomId = roomId,
                    durationMs = durationMs,
                    mimeType = mimeType,
                    bytes = bytes
                )
                // Sprint 2 V3.2 bug fix — quand Flutter n'est pas attaché (app
                // killée/background), persister le vocal sur disk pour drain
                // dès que Flutter wake. Sans ça les vocaux watch sont silently
                // dropped et arrivent jamais à Matrix.
                val cb = voiceReceivedCallback
                if (cb != null) {
                    cb(msg)
                } else {
                    Log.w(TAG, "voiceReceivedCallback null, persisting voice ${uuid.redact()} for later drain")
                    persistPendingVoice(context, msg)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "handleIncomingVoice failed uuid=${uuid.redact()}", t)
            }
        }
    }

    /**
     * Drain les vocaux pending sur disk vers le callback Flutter, par ordre
     * d'arrivée (filename = `{ts}_{uuid}.bin`). Appelé par WearBridgePlugin
     * dès que Flutter attache son callback.
     */
    fun drainPendingVoices(context: Context) {
        scope.launch {
            try {
                val dir = pendingVoicesDir(context)
                if (!dir.exists()) return@launch
                val files = dir.listFiles { f -> f.name.endsWith(".bin") }
                    ?.sortedBy { it.name } ?: return@launch
                Log.d(TAG, "drainPendingVoices: ${files.size} pending")
                for (f in files) {
                    val msg = readPendingVoice(f) ?: continue
                    voiceReceivedCallback?.invoke(msg) ?: break
                    f.delete()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "drainPendingVoices failed", t)
            }
        }
    }

    private fun pendingVoicesDir(context: Context): File {
        val d = File(context.filesDir, "wear_voice_pending")
        if (!d.exists()) d.mkdirs()
        return d
    }

    /**
     * Disk format compact: 4-byte LE int (header length) + header JSON UTF-8
     * (uuid/roomId/durationMs/mimeType) + raw audio bytes. Filename starts
     * with `System.currentTimeMillis()` so the sort order = FIFO d'arrivée.
     */
    private fun persistPendingVoice(context: Context, msg: VoiceMessage) {
        try {
            // org.json échappe correctement uuid/roomId/mimeType (un `"` ou `,`
            // dans une valeur cassait le JSON concaténé et permettait, au relire,
            // de rediriger le vocal vers une autre room).
            val header = org.json.JSONObject()
                .put("uuid", msg.uuid)
                .put("roomId", msg.roomId)
                .put("durationMs", msg.durationMs)
                .put("mimeType", msg.mimeType)
                .toString()
            val headerBytes = header.toByteArray(StandardCharsets.UTF_8)
            val ts = System.currentTimeMillis()
            val file = File(pendingVoicesDir(context), "${ts}_${msg.uuid}.bin")
            file.outputStream().use { out ->
                val lenBuf = java.nio.ByteBuffer.allocate(4)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .putInt(headerBytes.size)
                    .array()
                out.write(lenBuf)
                out.write(headerBytes)
                out.write(msg.bytes)
            }
            Log.d(TAG, "persisted voice ${msg.uuid.redact()} to ${file.absolutePath}")
        } catch (t: Throwable) {
            Log.w(TAG, "persistPendingVoice failed for ${msg.uuid.redact()}", t)
        }
    }

    private fun readPendingVoice(file: File): VoiceMessage? {
        return try {
            val raw = file.readBytes()
            if (raw.size < 4) return null
            val headerLen = java.nio.ByteBuffer.wrap(raw, 0, 4)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN).int
            if (headerLen <= 0 || headerLen > raw.size - 4) return null
            val header = String(raw, 4, headerLen, StandardCharsets.UTF_8)
            val audioBytes = raw.copyOfRange(4 + headerLen, raw.size)
            val obj = org.json.JSONObject(header)
            val uuid = obj.optString("uuid").ifEmpty { return null }
            val roomId = obj.optString("roomId").ifEmpty { return null }
            val durationMs = obj.optInt("durationMs", 0)
            val mimeType = obj.optString("mimeType", "audio/ogg")
            VoiceMessage(uuid, roomId, durationMs, mimeType, audioBytes)
        } catch (t: Throwable) {
            Log.w(TAG, "readPendingVoice failed for ${file.name}", t)
            null
        }
    }

    /**
     * Confirme à la watch que le vocal a été uploadé sur Matrix.
     *
     * Pattern hybride (cf. recherche pré-implém) :
     *  - MessageClient.sendMessage = ack RPC rapide (~1-3 s en cloud-routed)
     *  - DataItem `/wear/voice/ack/{uuid}` = filet de sécu (buffered si watch offline)
     */
    fun ackVoice(context: Context, uuid: String, success: Boolean) {
        // uuid arbitraire côté Dart → même whitelist que l'ingestion : il est
        // concaténé au path DataItem, on refuse un uuid malformé.
        if (!UUID_RE.matches(uuid)) {
            Log.w(TAG, "ackVoice: uuid invalide, ignoré")
            return
        }
        scope.launch {
            // 1. RPC rapide via MessageClient — pas de coalescing, livraison directe
            try {
                val info = Wearable.getCapabilityClient(context)
                    .getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                    .await()
                val nodes = info.nodes
                val path = if (success) "/wear/voice/ack/$uuid" else "/wear/voice/nack/$uuid"
                for (node in nodes) {
                    try {
                        Wearable.getMessageClient(context).sendMessage(node.id, path, ByteArray(0)).await()
                        Log.d(TAG, "voice ack message sent to ${node.displayName} uuid=${uuid.redact()}")
                    } catch (t: Throwable) {
                        Log.w(TAG, "voice ack message failed for ${node.displayName}", t)
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "voice ack capability lookup failed", t)
            }

            // 2. Filet de sécu via DataItem (buffered offline)
            try {
                val req = PutDataMapRequest.create("/wear/voice/ack/$uuid").apply {
                    dataMap.putString("uuid", uuid)
                    dataMap.putBoolean("success", success)
                    dataMap.putLong("ackedAt", System.currentTimeMillis())
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(req).await()
                Log.d(TAG, "voice ack DataItem written uuid=${uuid.redact()} success=$success")
            } catch (t: Throwable) {
                Log.w(TAG, "voice ack DataItem failed uuid=${uuid.redact()}", t)
            }

            // 3. Cleanup l'asset original côté DataLayer pour pas accumuler
            try {
                val originalUri = android.net.Uri.parse("wear:/wear/voice/$uuid")
                Wearable.getDataClient(context).deleteDataItems(originalUri).await()
            } catch (t: Throwable) {
                Log.d(TAG, "asset cleanup failed (likely already gone) uuid=${uuid.redact()}")
            }
        }
    }

    private fun InputStream.readAllBytesCompat(): ByteArray {
        val buf = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        var total = 0
        var n: Int
        while (this.read(chunk).also { n = it } != -1) {
            total += n
            if (total > MAX_VOICE_BYTES) {
                throw java.io.IOException("voice payload > $MAX_VOICE_BYTES o, rejeté")
            }
            buf.write(chunk, 0, n)
        }
        return buf.toByteArray()
    }
}

data class VoiceMessage(
    val uuid: String,
    val roomId: String,
    val durationMs: Int,
    val mimeType: String,
    val bytes: ByteArray
)
