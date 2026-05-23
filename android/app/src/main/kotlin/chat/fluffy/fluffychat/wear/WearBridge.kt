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

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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
        Log.d(TAG, "watch requested messages for $roomId")
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
                Log.d(TAG, "pushed ${bytes.size} bytes messages for $roomId")
            } catch (t: Throwable) {
                Log.w(TAG, "pushMessagesJson failed for $roomId", t)
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
        scope.launch {
            try {
                val fdResponse = Wearable.getDataClient(context).getFdForAsset(asset).await()
                val bytes = fdResponse.inputStream.use { it.readAllBytesCompat() }
                Log.d(TAG, "voice bytes received: ${bytes.size} uuid=$uuid")
                voiceReceivedCallback?.invoke(
                    VoiceMessage(
                        uuid = uuid,
                        roomId = roomId,
                        durationMs = durationMs,
                        mimeType = mimeType,
                        bytes = bytes
                    )
                )
            } catch (t: Throwable) {
                Log.w(TAG, "handleIncomingVoice failed uuid=$uuid", t)
            }
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
                        Log.d(TAG, "voice ack message sent to ${node.displayName} uuid=$uuid")
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
                Log.d(TAG, "voice ack DataItem written uuid=$uuid success=$success")
            } catch (t: Throwable) {
                Log.w(TAG, "voice ack DataItem failed uuid=$uuid", t)
            }

            // 3. Cleanup l'asset original côté DataLayer pour pas accumuler
            try {
                val originalUri = android.net.Uri.parse("wear:/wear/voice/$uuid")
                Wearable.getDataClient(context).deleteDataItems(originalUri).await()
            } catch (t: Throwable) {
                Log.d(TAG, "asset cleanup failed (likely already gone) uuid=$uuid")
            }
        }
    }

    private fun InputStream.readAllBytesCompat(): ByteArray {
        val buf = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        var n: Int
        while (this.read(chunk).also { n = it } != -1) {
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
