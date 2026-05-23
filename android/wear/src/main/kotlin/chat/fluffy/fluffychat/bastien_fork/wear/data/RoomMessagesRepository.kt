package chat.fluffy.fluffychat.bastien_fork.wear.data

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.Json
import java.nio.charset.StandardCharsets

private const val TAG = "RoomMessagesRepository"
private const val PHONE_CAPABILITY = "fluffychat_phone"
private const val REQUEST_PATH_PREFIX = "/wear/rooms"

/**
 * Stream des messages d'une room donnée. Path DataItem : `/wear/rooms/{roomId}/messages`.
 * Sur subscription, ping le phone via MessageClient pour qu'il re-push frais.
 */
class RoomMessagesRepository(private val context: Context, private val roomId: String) {

    private val dataClient: DataClient by lazy { Wearable.getDataClient(context) }
    private val json = Json { ignoreUnknownKeys = true }
    private val targetPath = "/wear/rooms/$roomId/messages"

    fun snapshots(): Flow<RoomMessagesSnapshot> = callbackFlow {
        val listener = DataClient.OnDataChangedListener { events: DataEventBuffer ->
            events.use { buf ->
                for (event in buf) {
                    if (event.type != DataEvent.TYPE_CHANGED) continue
                    if (event.dataItem.uri.path != targetPath) continue
                    val bytes = DataMapItem.fromDataItem(event.dataItem)
                        .dataMap.getByteArray(KEY_PAYLOAD)
                    val snap = decode(bytes)
                    if (snap != null) trySend(snap)
                }
            }
        }
        dataClient.addListener(listener)
        awaitClose { dataClient.removeListener(listener) }
    }.onStart {
        // demande au phone de re-publier les messages
        requestRefresh()
        // read cached current value
        readCurrent()?.let { emit(it) }
    }

    private suspend fun readCurrent(): RoomMessagesSnapshot? {
        return try {
            val items = dataClient.dataItems.await()
            val match = items.firstOrNull { it.uri.path == targetPath } ?: return null
            val bytes = DataMapItem.fromDataItem(match).dataMap.getByteArray(KEY_PAYLOAD)
            decode(bytes)
        } catch (t: Throwable) {
            Log.w(TAG, "readCurrent failed", t)
            null
        }
    }

    companion object {
        const val KEY_PAYLOAD = "payload"
    }

    private suspend fun requestRefresh() {
        try {
            val info = Wearable.getCapabilityClient(context)
                .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val node = info.nodes.firstOrNull { it.isNearby } ?: info.nodes.firstOrNull()
            if (node == null) {
                Log.w(TAG, "no phone node reachable for messages refresh")
                return
            }
            Wearable.getMessageClient(context)
                .sendMessage(node.id, "$REQUEST_PATH_PREFIX/$roomId/request", ByteArray(0))
                .await()
            Log.d(TAG, "refresh ping sent for $roomId")
        } catch (t: Throwable) {
            Log.w(TAG, "requestRefresh failed for $roomId", t)
        }
    }

    private fun decode(raw: ByteArray?): RoomMessagesSnapshot? {
        if (raw == null || raw.isEmpty()) return null
        return try {
            json.decodeFromString<RoomMessagesSnapshot>(String(raw, StandardCharsets.UTF_8))
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed", t)
            null
        }
    }
}
