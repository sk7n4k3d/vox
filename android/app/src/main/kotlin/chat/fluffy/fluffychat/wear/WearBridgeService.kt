package chat.fluffy.fluffychat.wear

import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import java.util.concurrent.TimeUnit

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
        // Le service est exporté (requis pour être réveillé par GMS) → on REFUSE
        // tout message dont l'émetteur n'est pas un node Wear réellement appairé.
        // Sans ça, un Intent forgé pourrait exfiltrer des messages déchiffrés ou
        // déclencher des actions Matrix au nom de l'utilisateur.
        if (!isTrustedNode(messageEvent.sourceNodeId)) {
            Log.w(TAG, "message ignoré (node non appairé)")
            return
        }
        when {
            path == PATH_REQUEST_ROOMS -> {
                WearBridge.notifyRefreshRequested(applicationContext)
            }
            path.startsWith(PATH_ROOMS_PREFIX) && path.endsWith(PATH_REQUEST_SUFFIX) -> {
                // /wear/rooms/{roomId}/request → la watch demande les messages
                val roomId = path
                    .removePrefix("$PATH_ROOMS_PREFIX/")
                    .removeSuffix(PATH_REQUEST_SUFFIX)
                if (roomId.isNotEmpty() && ROOM_ID_RE.matches(roomId)) {
                    WearBridge.notifyMessagesRequested(applicationContext, roomId)
                } else if (roomId.isNotEmpty()) {
                    Log.w(TAG, "roomId invalide ignoré")
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

            // Même garde d'origine que les messages : le host de l'URI = nodeId
            // émetteur. On n'ingère un vocal que d'un node appairé (sinon envoi
            // Matrix arbitraire / OOM via Asset forgé).
            if (!isTrustedNode(event.dataItem.uri.host)) {
                Log.w(TAG, "voice DataItem ignoré (node non appairé)")
                continue
            }
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
                if (!ROOM_ID_RE.matches(roomId)) {
                    Log.w(TAG, "voice DataItem roomId invalide, skip")
                    continue
                }
                // uuid est concaténé à un nom de fichier (WearBridge) et à un
                // chemin DataItem → un `../` écrit hors du dossier pending. On
                // n'accepte qu'une forme UUID/opaque alphanumérique stricte.
                if (!UUID_RE.matches(uuid)) {
                    Log.w(TAG, "voice DataItem uuid invalide, skip")
                    continue
                }
                // Whitelist du MIME (sinon Content-Type Matrix arbitraire) +
                // clamp de la durée (metadata MSC1767).
                val safeMime = if (mimeType in ALLOWED_VOICE_MIME) mimeType else "audio/ogg"
                val safeDuration = durationMs.coerceIn(0, 600_000)
                WearBridge.handleIncomingVoice(
                    context = applicationContext,
                    uuid = uuid,
                    roomId = roomId,
                    durationMs = safeDuration,
                    mimeType = safeMime,
                    asset = asset
                )
            } catch (t: Throwable) {
                Log.w(TAG, "Failed to handle voice DataItem $path", t)
            }
        }
    }

    /**
     * Vrai si [nodeId] est un node Wear actuellement appairé/connecté. Fail-closed :
     * si l'appel échoue ou si la liste ne contient pas le node, on refuse. Appel
     * bloquant — acceptable, on est sur le thread du WearableListenerService.
     */
    private fun isTrustedNode(nodeId: String?): Boolean {
        if (nodeId.isNullOrEmpty()) return false
        return try {
            Tasks.await(
                Wearable.getNodeClient(applicationContext).connectedNodes,
                5, TimeUnit.SECONDS,
            ).any { it.id == nodeId }
        } catch (t: Throwable) {
            Log.w(TAG, "vérif node appairé échouée → refus", t)
            false
        }
    }

    companion object {
        private const val TAG = "WearBridgeService"

        // Forme d'un room id Matrix `!opaque:server[:port]`. Exclut `/` et `..`
        // → empêche l'injection de path dans le DataItem `/wear/rooms/{id}/messages`.
        private val ROOM_ID_RE = Regex("""^![A-Za-z0-9._=+-]+:[A-Za-z0-9.\-]+(:\d+)?$""")

        // Forme d'un uuid de vocal watch : UUID canonique ou identifiant opaque
        // court alphanumérique (majuscules/minuscules/chiffres/tirets). Exclut
        // `/`, `..` et tout séparateur de chemin.
        private val UUID_RE = Regex("""^[A-Za-z0-9-]{8,64}$""")

        // MIME audio autorisés pour un vocal watch → Content-Type Matrix.
        private val ALLOWED_VOICE_MIME =
            setOf("audio/ogg", "audio/aac", "audio/mp4", "audio/mpeg", "audio/amr", "audio/webm")
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
