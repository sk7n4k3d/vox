package chat.fluffy.fluffychat.bastien_fork.wear.bridge

import android.util.Log
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomsRepository
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

/**
 * Service réveillé par GMS quand un DataChange ou un Message arrive du phone.
 * Sur Galaxy Watch Ultra en cloud-routed (hops=2), c'est le ping MessageClient
 * envoyé par [WearBridge] qui réveille notre process.
 *
 * Paths gérés :
 *  - `/wear/rooms/ping` → force readCurrent du DataItem rooms
 *  - `/wear/voice/ack/{uuid}` → success ack du phone après upload Matrix
 *  - `/wear/voice/nack/{uuid}` → fail ack du phone
 */
class WearListenerService : WearableListenerService() {

    override fun onCreate() {
        super.onCreate()
        // Si Freecess a tué notre process et que GMS nous réveille pour un message,
        // démarre le fg service pour qu'on reste vivant et reçoive les DataChange.
        WearForegroundService.start(applicationContext)
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            Log.d(TAG, "DataChanged path=${event.dataItem.uri.path} type=${event.type}")
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        Log.d(TAG, "Message path=$path from=${messageEvent.sourceNodeId}")
        when {
            path == PATH_ROOMS_PING -> {
                RoomsRepository.pingFlow.tryEmit(Unit)
            }
            path.startsWith(PATH_VOICE_ACK_PREFIX) -> {
                val uuid = path.removePrefix("$PATH_VOICE_ACK_PREFIX/")
                if (uuid.isNotEmpty()) {
                    VoiceUploader.notifyAck(uuid, success = true)
                }
            }
            path.startsWith(PATH_VOICE_NACK_PREFIX) -> {
                val uuid = path.removePrefix("$PATH_VOICE_NACK_PREFIX/")
                if (uuid.isNotEmpty()) {
                    VoiceUploader.notifyAck(uuid, success = false)
                }
            }
        }
    }

    companion object {
        private const val TAG = "WearListenerService"
        private const val PATH_ROOMS_PING = "/wear/rooms/ping"
        private const val PATH_VOICE_ACK_PREFIX = "/wear/voice/ack"
        private const val PATH_VOICE_NACK_PREFIX = "/wear/voice/nack"
    }
}
