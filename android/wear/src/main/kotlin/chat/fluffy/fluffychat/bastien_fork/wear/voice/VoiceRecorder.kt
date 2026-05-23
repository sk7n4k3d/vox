package chat.fluffy.fluffychat.bastien_fork.wear.voice

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import java.io.File
import java.util.UUID

/**
 * Encapsule MediaRecorder pour enregistrer un message vocal en Opus dans un container Ogg.
 *
 * Choix techniques :
 *  - OutputFormat.OGG + AudioEncoder.OPUS (API 29+, Wear OS 5 = Android 14 OK)
 *  - Sample rate 24 kHz mono (sweet spot voix, 480 KB pour 120 s)
 *  - Bitrate 32 kbps (intelligibilité Telegram/WhatsApp-style)
 *  - Durée max 120 s — au-delà force stop
 *
 * NB : MediaRecorder est synchrone et bloque le thread appelant pour start/stop.
 * À appeler depuis un coroutine IO ou un service séparé, pas le main thread Compose.
 */
class VoiceRecorder(private val context: Context) {

    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var startTimeMs: Long = 0L

    /** Démarre l'enregistrement. Retourne le fichier de sortie (encore en cours d'écriture). */
    fun start(): File {
        if (recorder != null) {
            throw IllegalStateException("Recorder already running")
        }
        val dir = File(context.cacheDir, "voice").apply { mkdirs() }
        val file = File(dir, "rec_${UUID.randomUUID()}.ogg")
        outputFile = file

        val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }

        rec.setAudioSource(MediaRecorder.AudioSource.MIC)
        rec.setOutputFormat(MediaRecorder.OutputFormat.OGG)
        rec.setAudioEncoder(MediaRecorder.AudioEncoder.OPUS)
        rec.setAudioSamplingRate(SAMPLE_RATE)
        rec.setAudioChannels(1)
        rec.setAudioEncodingBitRate(BIT_RATE)
        rec.setMaxDuration(MAX_DURATION_MS)
        rec.setOutputFile(file.absolutePath)

        rec.setOnInfoListener { _, what, _ ->
            if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                Log.d(TAG, "max duration reached, auto-stop")
                // Le système stop le recorder de lui-même quand maxDuration atteint.
            }
        }
        rec.setOnErrorListener { _, what, extra ->
            Log.w(TAG, "MediaRecorder error what=$what extra=$extra")
        }

        rec.prepare()
        rec.start()
        startTimeMs = System.currentTimeMillis()
        recorder = rec
        Log.d(TAG, "recording started → ${file.absolutePath}")
        return file
    }

    /** Stop, return outputFile + duration ms. Idempotent. */
    fun stop(): RecordingResult? {
        val rec = recorder ?: return null
        val file = outputFile ?: return null
        recorder = null
        outputFile = null
        val durationMs = (System.currentTimeMillis() - startTimeMs).toInt().coerceAtMost(MAX_DURATION_MS)
        return try {
            rec.stop()
            rec.release()
            Log.d(TAG, "recording stopped, ${file.length()} bytes, ${durationMs}ms")
            RecordingResult(file = file, durationMs = durationMs)
        } catch (t: Throwable) {
            Log.w(TAG, "stop failed, cleanup", t)
            rec.runCatching { release() }
            file.delete()
            null
        }
    }

    /** Cancel = stop + delete file. */
    fun cancel() {
        val file = outputFile
        stop()
        file?.delete()
        Log.d(TAG, "recording cancelled")
    }

    /** Durée actuelle si recorder actif, sinon 0. */
    fun currentDurationMs(): Int {
        if (recorder == null) return 0
        return (System.currentTimeMillis() - startTimeMs).toInt()
    }

    fun isRecording(): Boolean = recorder != null

    companion object {
        private const val TAG = "VoiceRecorder"
        const val SAMPLE_RATE = 24_000
        const val BIT_RATE = 32_000
        const val MAX_DURATION_MS = 120_000
    }
}

data class RecordingResult(
    val file: File,
    val durationMs: Int
)
