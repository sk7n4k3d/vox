package chat.fluffy.fluffychat.wear

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

/**
 * Bridge service côté phone — réveillé par DataItems et MessageClient pings de la watch.
 *
 *  - `/wear/rooms/request` (message) → la watch demande un push frais des rooms
 *  - `/wear/voice/{uuid}` (data) → la watch a uploadé un audio Opus, le phone doit
 *    le lire et l'envoyer en Matrix m.audio via le SDK Dart.
 *
 * Le service DOIT être déclaré dans le manifest sinon le process phone ne sera pas
 * réveillé si tué (cf. recherche pré-implém).
 */
class WearBridgeService : WearableListenerService() {

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        Log.d(TAG, "Message path=$path from=${messageEvent.sourceNodeId}")
        when {
            path == PATH_REQUEST_ROOMS -> {
                WearBridge.notifyRefreshRequested(applicationContext)
            }
            path.startsWith(PATH_ROOMS_PREFIX) && path.endsWith(PATH_REQUEST_SUFFIX) -> {
                // /wear/rooms/{roomId}/request → la watch demande les messages
                val roomId = path
                    .removePrefix("$PATH_ROOMS_PREFIX/")
                    .removeSuffix(PATH_REQUEST_SUFFIX)
                if (roomId.isNotEmpty()) {
                    WearBridge.notifyMessagesRequested(applicationContext, roomId)
                }
            }
        }
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val path = event.dataItem.uri.path ?: continue
            if (!path.startsWith(PATH_VOICE_PREFIX)) continue
            if (path.startsWith(PATH_VOICE_ACK_PREFIX)) continue // skip our own ack items

            Log.d(TAG, "Voice DataItem received: $path")
            try {
                val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                val uuid = dataMap.getString(KEY_UUID) ?: ""
                val roomId = dataMap.getString(KEY_ROOM_ID) ?: ""
                val durationMs = dataMap.getInt(KEY_DURATION_MS, 0)
                val mimeType = dataMap.getString(KEY_MIME_TYPE) ?: "audio/ogg"
                val asset = dataMap.getAsset(KEY_AUDIO)
                if (asset == null || uuid.isEmpty() || roomId.isEmpty()) {
                    Log.w(TAG, "Voice DataItem missing fields, skip")
                    continue
                }
                WearBridge.handleIncomingVoice(
                    context = applicationContext,
                    uuid = uuid,
                    roomId = roomId,
                    durationMs = durationMs,
                    mimeType = mimeType,
                    asset = asset
                )
            } catch (t: Throwable) {
                Log.w(TAG, "Failed to handle voice DataItem $path", t)
            }
        }
    }

    companion object {
        private const val TAG = "WearBridgeService"
        const val PATH_REQUEST_ROOMS = "/wear/rooms/request"
        private const val PATH_ROOMS_PREFIX = "/wear/rooms"
        private const val PATH_REQUEST_SUFFIX = "/request"
        private const val PATH_VOICE_PREFIX = "/wear/voice"
        private const val PATH_VOICE_ACK_PREFIX = "/wear/voice/ack"
        private const val KEY_AUDIO = "audio"
        private const val KEY_UUID = "uuid"
        private const val KEY_ROOM_ID = "roomId"
        private const val KEY_DURATION_MS = "durationMs"
        private const val KEY_MIME_TYPE = "mimeType"
    }
}
