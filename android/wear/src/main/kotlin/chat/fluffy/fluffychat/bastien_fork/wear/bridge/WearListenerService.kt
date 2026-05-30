package chat.fluffy.fluffychat.bastien_fork.wear.bridge

import android.util.Log
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomsRepository
import chat.fluffy.fluffychat.bastien_fork.wear.notif.MessageNotifier
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

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

    // Scope court-vécu pour les readCurrent headless (ping). WearableListenerService
    // est détruit après chaque livraison : on annule le scope dans onDestroy.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        // Si Freecess a tué notre process et que GMS nous réveille pour un message,
        // démarre le fg service pour qu'on reste vivant et reçoive les DataChange.
        WearForegroundService.start(applicationContext)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Lit le DataItem rooms courant et alimente [MessageNotifier]. Appelé sur ping
     * MessageClient (cloud-routed) où le DataChange peut ne pas être livré ici.
     */
    private fun notifyFromCurrentRooms() {
        scope.launch {
            val snapshot = runCatching {
                val items = Wearable.getDataClient(applicationContext).dataItems.await()
                val match = items.firstOrNull { it.uri.path == RoomsRepository.PATH }
                val bytes = match?.let {
                    DataMapItem.fromDataItem(it).dataMap.getByteArray(RoomsRepository.KEY)
                        ?: it.data
                }
                items.release()
                RoomsRepository.decodeSnapshot(bytes)
            }.onFailure { Log.w(TAG, "notifyFromCurrentRooms read failed", it) }.getOrNull()
            if (snapshot != null) {
                runCatching { MessageNotifier.onRoomsSnapshot(applicationContext, snapshot) }
                    .onFailure { Log.w(TAG, "notify pipeline failed (ping)", it) }
            }
        }
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        // GMS réveille ce service même app fermée (intent-filter DATA_CHANGED sur
        // /wear/rooms). C'est le point d'entrée headless pour notifier les nouveaux
        // messages : on décode le snapshot rooms et on délègue à MessageNotifier.
        dataEvents.use { buf ->
            for (event in buf) {
                val path = event.dataItem.uri.path
                Log.d(TAG, "DataChanged path=$path type=${event.type}")
                if (event.type != DataEvent.TYPE_CHANGED) continue
                if (path != RoomsRepository.PATH) continue
                val bytes = runCatching {
                    DataMapItem.fromDataItem(event.dataItem)
                        .dataMap.getByteArray(RoomsRepository.KEY)
                }.getOrNull() ?: event.dataItem.data
                val snapshot = RoomsRepository.decodeSnapshot(bytes) ?: continue
                runCatching { MessageNotifier.onRoomsSnapshot(applicationContext, snapshot) }
                    .onFailure { Log.w(TAG, "notify pipeline failed", it) }
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        Log.d(TAG, "Message path=$path from=${messageEvent.sourceNodeId}")
        when {
            path == PATH_ROOMS_PING -> {
                RoomsRepository.pingFlow.tryEmit(Unit)
                // En cloud-routed (hops=2), le DataChange peut ne jamais arriver à ce
                // service alors que le DataItem est bien à jour. Le ping force un
                // readCurrent headless pour alimenter MessageNotifier même app fermée.
                notifyFromCurrentRooms()
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
