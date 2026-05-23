package chat.fluffy.fluffychat.bastien_fork.wear.voice

import android.content.Context
import android.os.ParcelFileDescriptor
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Upload un fichier audio vocal vers le phone via DataClient Asset.
 *
 * Pattern hybride pour l'ack (cf. recherche pré-implém) :
 *  - Phone répond via MessageClient.sendMessage `/wear/voice/ack/{uuid}` (RPC rapide)
 *  - [WearListenerService.onMessageReceived] capte le path et appelle [notifyAck]
 *  - Watch attend l'ack via CompletableDeferred (pas de polling)
 *  - Filet : DataItem ack côté phone aussi, mais l'ack par message arrive en premier
 *
 * Timeout : 20 s (cloud-routed sain : ~1-3 s). Au-delà, on suppose que l'audio est
 * bien arrivé mais l'ack dort — message "Confirmation différée" plutôt qu'erreur.
 */
object VoiceUploader {

    private const val TAG = "VoiceUploader"
    private const val PATH_VOICE = "/wear/voice"
    private const val KEY_AUDIO = "audio"
    private const val KEY_ROOM_ID = "roomId"
    private const val KEY_DURATION_MS = "durationMs"
    private const val KEY_CREATED_AT = "createdAt"
    private const val KEY_MIME_TYPE = "mimeType"
    private const val KEY_UUID = "uuid"

    private const val MAX_RETRIES = 3
    private const val UPLOAD_TIMEOUT_MS = 30_000L
    private const val ACK_TIMEOUT_MS = 20_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingAcks = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()

    private val _state = MutableStateFlow<UploadState>(UploadState.Idle)
    val state: StateFlow<UploadState> = _state.asStateFlow()

    fun upload(context: Context, roomId: String, file: File, durationMs: Int) {
        val uuid = UUID.randomUUID().toString()
        _state.value = UploadState.Uploading(uuid = uuid, attempt = 1)

        // Pre-register le slot d'ack AVANT de putDataItem (sinon race condition)
        val ackDeferred = CompletableDeferred<Boolean>()
        pendingAcks[uuid] = ackDeferred

        scope.launch {
            var success = false
            for (attempt in 1..MAX_RETRIES) {
                _state.value = UploadState.Uploading(uuid = uuid, attempt = attempt)
                val ok = withTimeoutOrNull(UPLOAD_TIMEOUT_MS) {
                    runCatching { putAsset(context, uuid, roomId, file, durationMs) }
                        .onFailure { Log.w(TAG, "putAsset attempt=$attempt failed", it) }
                        .isSuccess
                }
                if (ok == true) { success = true; break }
                Log.w(TAG, "upload attempt $attempt failed/timeout, retrying…")
                delay(2_000L * attempt)
            }

            if (!success) {
                _state.value = UploadState.Error(uuid = uuid, message = "Envoi échoué")
                pendingAcks.remove(uuid)
                file.delete()
                return@launch
            }

            // Wait for ack via MessageClient listener (no polling)
            _state.value = UploadState.WaitingAck(uuid = uuid)
            val acked = withTimeoutOrNull(ACK_TIMEOUT_MS) { ackDeferred.await() }
            pendingAcks.remove(uuid)

            _state.value = when (acked) {
                true -> UploadState.Success(uuid = uuid)
                false -> UploadState.Error(uuid = uuid, message = "Échec côté téléphone")
                null -> UploadState.Error(uuid = uuid, message = "Audio envoyé, confirmation différée")
            }
            file.delete()
        }
    }

    /**
     * Appelé par [WearListenerService] quand un message `/wear/voice/ack/{uuid}`
     * ou `/wear/voice/nack/{uuid}` arrive du phone.
     */
    fun notifyAck(uuid: String, success: Boolean) {
        val deferred = pendingAcks.remove(uuid)
        if (deferred != null) {
            Log.d(TAG, "ack delivered for uuid=$uuid success=$success")
            deferred.complete(success)
        } else {
            Log.d(TAG, "ack for uuid=$uuid arrived but no pending slot (already timed out or ignored)")
        }
    }

    private suspend fun putAsset(
        context: Context,
        uuid: String,
        roomId: String,
        file: File,
        durationMs: Int
    ) {
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val asset = Asset.createFromFd(fd)
        val req = PutDataMapRequest.create("$PATH_VOICE/$uuid").apply {
            dataMap.putAsset(KEY_AUDIO, asset)
            dataMap.putString(KEY_UUID, uuid)
            dataMap.putString(KEY_ROOM_ID, roomId)
            dataMap.putInt(KEY_DURATION_MS, durationMs)
            dataMap.putLong(KEY_CREATED_AT, System.currentTimeMillis())
            dataMap.putString(KEY_MIME_TYPE, "audio/ogg")
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(context).putDataItem(req).await()
        Log.d(TAG, "asset put for uuid=$uuid (${file.length()} bytes)")
    }

    fun reset() {
        _state.value = UploadState.Idle
    }
}

sealed class UploadState {
    data object Idle : UploadState()
    data class Uploading(val uuid: String, val attempt: Int) : UploadState()
    data class WaitingAck(val uuid: String) : UploadState()
    data class Success(val uuid: String) : UploadState()
    data class Error(val uuid: String, val message: String) : UploadState()
}
