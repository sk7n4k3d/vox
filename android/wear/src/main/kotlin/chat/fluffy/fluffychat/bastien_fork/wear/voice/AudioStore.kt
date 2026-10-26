package chat.fluffy.fluffychat.bastien_fork.wear.voice

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.tasks.await
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets

/** État d'écoute d'un vocal côté montre. */
sealed interface AudioState {
    /** Demande envoyée au phone, tronçons en cours. */
    data object Requesting : AudioState

    /** Fichier écrit sur disk, prêt à jouer. */
    data class Ready(val file: File) : AudioState

    /** Échec (hors portée, trop long, corrompu…) — reason affiché dans la bulle. */
    data class Failed(val reason: String) : AudioState
}

/**
 * Magasin des vocaux téléchargés à la demande depuis le phone pour écoute
 * locale sur la montre (bug terrain 2026-10-26 : le tap sur un vocal ouvrait
 * une page phone cassée au lieu de jouer le son ici).
 *
 * Flux : [requestAudio] → MessageClient `/wear/audio/request` {roomId,eventId}
 * → le phone déchiffre et renvoie des frames `/wear/audio/chunk`
 * `eventId|seq|final|b64` (base64 découpé à 60 000 car. = multiple de 4, donc
 * chaque frame se décode indépendamment) → assemblage → `filesDir/audio/`
 * → état [AudioState.Ready].
 */
object AudioStore {

    private const val TAG = "AudioStore"
    private const val PHONE_CAPABILITY = "fluffychat_phone"
    private const val REQUEST_PATH = "/wear/audio/request"

    // Garde-fou anti-OOM : le phone plafonne déjà à ~900 ko, on refuse au-delà
    // d'1,6 Mo assemblé (payload d'un node compromis ou rejeu en boucle).
    private const val MAX_AUDIO_BYTES = 1_600_000

    // Rétention des fichiers écoutés : 7 jours, purge à chaque écriture.
    private const val RETENTION_MS = 7L * 24 * 3600 * 1000

    private val buffers = java.util.concurrent.ConcurrentHashMap<String, ByteArrayOutputStream>()

    // Prochain seq attendu par eventId — MessageClient peut relivrer un cadre
    // après reconnexion BT ; l'accepter deux fois corromprait l'Ogg.
    private val nextSeq = java.util.concurrent.ConcurrentHashMap<String, Int>()

    /** eventId → état de transfert/lecture, observé par les bulles. */
    val states = MutableStateFlow<Map<String, AudioState>>(emptyMap())

    fun cachedFile(context: Context, eventId: String): File? =
        File(audioDir(context), safeName(eventId) + ".ogg")
            .takeIf { it.exists() && it.length() > 0 }

    /** Demande le contenu d'un vocal au phone (no-op si déjà en cache/demandé). */
    suspend fun requestAudio(context: Context, roomId: String, eventId: String) {
        if (eventId.isBlank()) return
        if (cachedFile(context, eventId) != null) return
        if (states.value[eventId] is AudioState.Requesting) return
        states.value = states.value + (eventId to AudioState.Requesting)
        try {
            val info = Wearable.getCapabilityClient(context)
                .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val node = info.nodes.firstOrNull { it.isNearby } ?: info.nodes.firstOrNull()
            if (node == null) {
                fail(eventId, "Téléphone hors portée")
                return
            }
            val payload = org.json.JSONObject()
                .put("roomId", roomId)
                .put("eventId", eventId)
                .toString()
            Wearable.getMessageClient(context)
                .sendMessage(node.id, REQUEST_PATH, payload.toByteArray(StandardCharsets.UTF_8))
                .await()
            Log.d(TAG, "audio request sent for ${eventId.redact()}")
        } catch (t: Throwable) {
            Log.w(TAG, "requestAudio failed", t)
            fail(eventId, "Envoi échoué")
        }
    }

    /** Frame `/wear/audio/chunk` reçue du phone : `eventId|seq|final|b64chunk`. */
    fun onChunk(context: Context, payload: ByteArray) {
        val parts = String(payload, StandardCharsets.UTF_8).split("|", limit = 4)
        if (parts.size != 4) return
        val (eventId, seqStr, finalStr, chunkB64) = parts
        if (eventId.isBlank() || eventId.length > 255) return
        val seq = seqStr.toIntOrNull() ?: return
        if (seq != nextSeq.getOrDefault(eventId, 0)) {
            Log.w(TAG, "cadre hors ordre ignoré pour ${eventId.redact()}: $seq")
            return
        }
        val bytes = try {
            java.util.Base64.getDecoder().decode(chunkB64)
        } catch (t: Throwable) {
            fail(eventId, "Tronçon corrompu")
            return
        }
        val buf = buffers.getOrPut(eventId) { ByteArrayOutputStream() }
        var full: ByteArray? = null
        synchronized(buf) {
            if (buf.size() + bytes.size > MAX_AUDIO_BYTES) {
                buffers.remove(eventId)
                nextSeq.remove(eventId)
                return fail(eventId, "Vocal trop volumineux")
            }
            buf.write(bytes)
            if (finalStr == "1") {
                full = buf.toByteArray()
                buffers.remove(eventId)
                nextSeq.remove(eventId)
            } else {
                nextSeq[eventId] = seq + 1
            }
        }
        val done = full
        if (done != null) persist(context, eventId, done, seq)
    }

    /** Le phone n'a pas pu servir le vocal (message `/wear/audio/error/{id}`). */
    fun onPhoneError(eventId: String, reason: String) {
        buffers.remove(eventId)
        nextSeq.remove(eventId)
        fail(eventId, reason.ifBlank { "Phone indisponible" })
    }

    private fun persist(context: Context, eventId: String, bytes: ByteArray, lastSeq: Int) {
        try {
            val dir = audioDir(context)
            pruneOld(dir)
            val target = File(dir, safeName(eventId) + ".ogg")
            val tmp = File(dir, target.name + ".part")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            states.value = states.value + (eventId to AudioState.Ready(target))
            Log.d(TAG, "audio ready ${eventId.redact()}: ${bytes.size} o en ${lastSeq + 1} tronçons")
        } catch (t: Throwable) {
            Log.w(TAG, "audio persist failed", t)
            fail(eventId, "Écriture impossible")
        }
    }

    private fun fail(eventId: String, reason: String) {
        buffers.remove(eventId)
        nextSeq.remove(eventId)
        states.value = states.value + (eventId to AudioState.Failed(reason))
    }

    private fun audioDir(context: Context): File =
        File(context.filesDir, "audio").apply { if (!exists()) mkdirs() }

    private fun pruneOld(dir: File) {
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        runCatching {
            dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
        }
    }

    private fun safeName(eventId: String): String =
        eventId.filter { it.isLetterOrDigit() || it == '-' || it == '_' }

    private fun String.redact(n: Int = 6): String =
        if (length <= n) this else substring(0, n) + "****"
}
