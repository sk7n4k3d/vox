package chat.fluffy.fluffychat.bastien_fork.wear.data

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.transform
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.Json
import java.nio.charset.StandardCharsets

private const val TAG = "RoomsRepository"
private const val ROOMS_PATH = "/wear/rooms"
private const val ROOMS_KEY = "payload"

class RoomsRepository(private val context: Context) {

    private val dataClient: DataClient by lazy { Wearable.getDataClient(context) }
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Flow qui :
     *  - émet d'abord le snapshot persisté côté GMS (read initial)
     *  - relaie les onDataChanged subséquents sur le même path
     *  - relaie aussi les pings MessageClient `/wear/rooms/ping` reçus par
     *    [WearListenerService] (forcent un readCurrent même si le DataLayer
     *    n'a pas encore propagé le DataItem en cloud-routed mode hops=2)
     */
    fun snapshots(): Flow<RoomsSnapshot> = callbackFlow {
        val listener = DataClient.OnDataChangedListener { events: DataEventBuffer ->
            events.use { buf ->
                for (event in buf) {
                    if (event.type != DataEvent.TYPE_CHANGED) continue
                    if (event.dataItem.uri.path != ROOMS_PATH) continue
                    val snap = decode(event.dataItem.data)
                    if (snap != null) trySend(snap)
                }
            }
        }
        dataClient.addListener(listener)
        awaitClose { dataClient.removeListener(listener) }
    }.let { dataFlow ->
        merge(
            dataFlow,
            pingFlow.transform { _ ->
                readCurrent()?.let { emit(it) }
            }
        )
    }.onStart {
        readCurrent()?.let { emit(it) }
    }

    private suspend fun readCurrent(): RoomsSnapshot? {
        return try {
            val items = dataClient.dataItems.await()
            val match = items.firstOrNull { it.uri.path == ROOMS_PATH } ?: return null
            decode(DataMapItem.fromDataItem(match).dataMap.getByteArray(ROOMS_KEY) ?: match.data)
        } catch (t: Throwable) {
            Log.w(TAG, "readCurrent failed", t)
            null
        }
    }

    private fun decode(raw: ByteArray?): RoomsSnapshot? {
        if (raw == null || raw.isEmpty()) return null
        // wear-006 — borne la taille AVANT String()/decodeFromString : un DataItem
        // corrompu ou malformé (bug phone, corruption transit) avec un payload
        // géant ferait un OOM. 512 KB couvre largement une liste de rooms.
        if (raw.size > MAX_PAYLOAD_BYTES) {
            Log.w(TAG, "rooms DataItem too large: ${raw.size} bytes, dropping")
            return null
        }
        return try {
            json.decodeFromString<RoomsSnapshot>(String(raw, StandardCharsets.UTF_8))
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed (${raw.size} bytes)", t)
            null
        }
    }

    companion object {
        /** Path du DataItem rooms, partagé avec les listeners headless. */
        const val PATH = ROOMS_PATH
        const val KEY = ROOMS_KEY

        /** Garde-fou OOM sur les payloads DataItem entrants (cf. decode). */
        private const val MAX_PAYLOAD_BYTES = 512 * 1024

        private val sharedJson = Json { ignoreUnknownKeys = true }

        /**
         * Décodage statique réutilisable hors instance (ex: [WearListenerService]
         * réveillé par GMS qui décode le DataItem rooms pour [MessageNotifier]).
         * Applique le même garde-fou taille que [decode].
         */
        fun decodeSnapshot(raw: ByteArray?): RoomsSnapshot? {
            if (raw == null || raw.isEmpty()) return null
            if (raw.size > MAX_PAYLOAD_BYTES) {
                Log.w(TAG, "rooms DataItem too large: ${raw.size} bytes, dropping (static)")
                return null
            }
            return try {
                sharedJson.decodeFromString<RoomsSnapshot>(String(raw, StandardCharsets.UTF_8))
            } catch (t: Throwable) {
                Log.w(TAG, "static decode failed (${raw.size} bytes)", t)
                null
            }
        }

        /**
         * Signal global émis par [WearListenerService] quand un ping MessageClient
         * `/wear/rooms/ping` arrive du phone. Force tous les repos actifs à relire
         * le DataItem (utile en mode cloud-routed où le DataChange peut être lent).
         */
        val pingFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
    }
}
