package chat.fluffy.fluffychat.video

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.min

/**
 * Compresseur vidéo natif de VOX — remplace `video_compress` (Flutter), qui
 * boucle à vie sans progression ni annulation sur les fichiers lourds.
 *
 * Moteur : Media3 Transformer (l'encodeur natif d'Android, version 1.9.x —
 * API `EditedMediaItem`/`ExportResult`). File FIFO sur un HandlerThread dédié ;
 * un seul Transformer à la fois (le matériel d'encodage est partagé).
 * Progression sondée toutes les 500 ms via ProgressHolder et poussée vers
 * Dart + la notification `video_compression`.
 *
 * Events (EventChannel `eu.devlabz.vox/video_events`), Maps discriminées par
 * `kind` : progress {jobId, percent} / done {jobId, outputPath, width,
 * height, durationMs, sizeBytes, passthrough} / error {jobId, code, message}
 * / cancelled {jobId}. Codes erreur : encoder | unreadable.
 */
object VideoBridge {
    internal val events = VideoEventHub()
}

/**
 * Plan de compression — bornes pures, sans Android, testables.
 */
object CompressionPlan {

    const val MAX_LANDSCAPE_SIDE = 1920
    const val MAX_PORTRAIT_SIDE = 1080
    const val MAX_PASSTHROUGH_BYTES = 25L * 1024 * 1024
    const val VIDEO_BITRATE = 3_500_000
    const val AUDIO_BITRATE = 128_000
    const val TARGET_FRAME_RATE = 30

    /**
     * Taille de sortie dans l'ESPACE ENCODÉ (w x h tels que stockés, rotation
     * non appliquée). [rotated] = la source a une rotation 90/270 : le plafond
     * s'applique aux côtés échangés. Arrondi à pair (exigence encodeur).
     */
    fun outputSize(encW: Int, encH: Int, rotated: Boolean): Pair<Int, Int> {
        if (encW <= 0 || encH <= 0) return encW to encH
        val dispW = if (rotated) encH else encW
        val dispH = if (rotated) encW else encH
        val cap =
            if (dispW >= dispH) MAX_LANDSCAPE_SIDE else MAX_PORTRAIT_SIDE
        val maxDisplaySide = maxOf(dispW, dispH)
        if (maxDisplaySide <= cap) return encW to encH
        val ratio = cap.toDouble() / maxDisplaySide
        val outW = evenDown((encW * ratio).toInt())
        val outH = evenDown((encH * ratio).toInt())
        return outW.coerceAtLeast(2) to outH.coerceAtLeast(2)
    }

    private fun evenDown(v: Int): Int = if (v % 2 == 0) v else v - 1

    fun isCompliant(
        sizeBytes: Long,
        maxDisplaySide: Int,
        videoMime: String?,
        audioMime: String?,
    ): Boolean =
        sizeBytes <= MAX_PASSTHROUGH_BYTES &&
            maxDisplaySide <= MAX_LANDSCAPE_SIDE &&
            videoMime == MimeTypes.VIDEO_H264 &&
            (audioMime == null || audioMime == MimeTypes.AUDIO_AAC)

    /** Cadence de sortie : la source bornée à [TARGET_FRAME_RATE]. */
    fun targetFrameRate(sourceFrameRate: Float): Int {
        val src = sourceFrameRate.takeIf { it > 0f } ?: TARGET_FRAME_RATE.toFloat()
        return min(src, TARGET_FRAME_RATE.toFloat()).toInt().coerceAtLeast(1)
    }
}

class VideoCompressorBridge(private val context: Context) {

    private val outDir = File(context.cacheDir, "video").apply { mkdirs() }
    private val jobs = HashMap<String, JobHandle>()
    private var jobCounter = 0L

    private class JobHandle(
        @Volatile var cancelled: Boolean = false,
        @Volatile var transformer: Transformer? = null,
    )

    private val thread = HandlerThread("vox-video").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())

    /** Visible au plugin pour câbler l'action Annuler de la notification. */
    val notify = VideoNotification(context)

    init {
        cleanupOrphans()
    }

    /** Les events EventChannel doivent partir du main thread. */
    private fun emit(event: Map<String, Any?>) {
        main.post { VideoBridge.events.publish(event) }
    }

    /** Enfile le job et renvoie immédiatement son jobId. */
    fun start(path: String): String {
        val jobId = "v${++jobCounter}"
        handler.post { runJob(jobId, path) }
        return jobId
    }

    fun cancel(jobId: String) {
        val handle = synchronized(jobs) { jobs[jobId] }
        if (handle == null) {
            // job déjà terminé ou inconnu : rien à couper côté encoder
            settleCancelled(jobId)
            return
        }
        handle.cancelled = true
        // Transformer exige que ses méthodes tournent sur sa thread applicative
        // (celui du job) — appeler cancel() depuis le main thread lève une
        // IllegalStateException qui avalerait silencieusement l'annulation.
        handler.post {
            try {
                handle.transformer?.cancel()
            } catch (e: Exception) {
                Log.w(TAG, "cancel: ${e.message}")
            }
        }
    }

    fun meta(path: String): Map<String, Any?>? = try {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val w = r.extractMetadata(METADATA_WIDTH)?.toIntOrNull() ?: 0
            val h = r.extractMetadata(METADATA_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = r.extractMetadata(METADATA_ROTATION)?.toIntOrNull() ?: 0
            val duration = r.extractMetadata(METADATA_DURATION)?.toLongOrNull() ?: 0L
            val dims = if (rotation == 90 || rotation == 270) h to w else w to h
            mapOf(
                "width" to dims.first,
                "height" to dims.second,
                "durationMs" to duration,
                "sizeBytes" to File(path).length(),
            )
        } finally {
            r.release()
        }
    } catch (e: Exception) {
        Log.w(TAG, "meta($path): ${e.message}")
        null
    }

    fun thumbnail(path: String, maxSize: Int): ByteArray? = try {
        val r = MediaMetadataRetriever()
        val bmp: Bitmap? = try {
            r.setDataSource(path)
            @Suppress("MagicNumber")
            r.getScaledFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST,
                maxSize.coerceIn(64, 4096),
                maxSize.coerceIn(64, 4096),
            ) ?: r.getFrameAtTime(0)
        } finally {
            r.release()
        }
        bmp?.let {
            val out = ByteArrayOutputStream()
            it.compress(Bitmap.CompressFormat.JPEG, 80, out)
            it.recycle()
            out.toByteArray()
        }
    } catch (e: Exception) {
        Log.w(TAG, "thumbnail($path): ${e.message}")
        null
    }

    /** Supprime uniquement les fichiers sous cacheDir/video (garde traversal). */
    fun cleanup(paths: List<String>) {
        val root = outDir.canonicalPath
        for (raw in paths) {
            try {
                val f = File(raw)
                if (f.canonicalPath.startsWith("$root${File.separatorChar}") && f.isFile) {
                    f.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "cleanup($raw): ${e.message}")
            }
        }
    }

    private fun cleanupOrphans() {
        val cutoff = System.currentTimeMillis() - ORPHAN_TTL_MS
        outDir.listFiles()
            ?.filter { it.lastModified() < cutoff }
            ?.forEach { it.delete() }
    }

    private fun runJob(jobId: String, path: String) {
        val handle = JobHandle()
        synchronized(jobs) { jobs[jobId] = handle }
        notify.currentJobId = jobId
        notify.rememberFileName(
            File(path).name.substringBeforeLast('.')
                .ifBlank { "vidéo" }.take(48),
        )
        var resolved: ResolvedInput? = null
        try {
            resolved = resolveInput(jobId, path)
                ?: return settleError(jobId, "unreadable", "fichier illisible")
            val srcFile = resolved.file
            val probe = probeTracks(srcFile.absolutePath)
                ?: run {
                    if (resolved.isTemp) srcFile.delete()
                    return settleError(jobId, "unreadable", "piste vidéo absente")
                }
            if (CompressionPlan.isCompliant(
                    srcFile.length(),
                    maxOf(probe.displayWidth, probe.displayHeight),
                    probe.videoMime,
                    probe.audioMime,
                )
            ) {
                val out = File(outDir, "$jobId.mp4")
                if (!srcFile.copyToOrFalse(out)) {
                    return settleError(jobId, "unreadable", "copie impossible")
                }
                if (resolved.isTemp) srcFile.delete()
                settleDone(jobId, out, passthrough = true)
                return
            }
            transform(jobId, handle, srcFile, resolved.isTemp, probe)
        } catch (e: Exception) {
            Log.e(TAG, "runJob($jobId)", e)
            settleError(jobId, "encoder", e.message ?: "erreur interne")
        }
    }

    private class ResolvedInput(val file: File, val isTemp: Boolean)

    /** content:// et fichiers partagés sont copiés dans le cache ; sinon tel quel. */
    private fun resolveInput(jobId: String, path: String): ResolvedInput? = try {
        if (path.startsWith("content://") || path.startsWith("file://")) {
            val uri = path.toUri()
            val target = File(outDir, "${jobId}_in.part")
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
            target.takeIf { it.isFile && it.length() > 0 }
                ?.let { ResolvedInput(it, isTemp = true) }
        } else {
            val f = File(path)
            if (f.isFile && f.canRead()) ResolvedInput(f, isTemp = false) else null
        }
    } catch (e: Exception) {
        Log.w(TAG, "resolveInput($path): ${e.message}")
        null
    }

    private class Probe(
        val encWidth: Int,
        val encHeight: Int,
        val rotated: Boolean,
        val videoMime: String?,
        val audioMime: String?,
        val displayWidth: Int,
        val displayHeight: Int,
        val frameRate: Float,
    )

    private fun probeTracks(path: String): Probe? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var videoMime: String? = null
            var audioMime: String? = null
            var w = 0
            var h = 0
            var rotation = 0
            var frameRate = 0f
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoMime == null) {
                    videoMime = mime
                    w = format.getInteger(MediaFormat.KEY_WIDTH)
                    h = format.getInteger(MediaFormat.KEY_HEIGHT)
                    if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        rotation = format.getInteger(MediaFormat.KEY_ROTATION)
                    }
                    if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        frameRate = try {
                            format.getFloat(MediaFormat.KEY_FRAME_RATE)
                        } catch (_: ClassCastException) {
                            format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                        }
                    }
                } else if (mime.startsWith("audio/") && audioMime == null) {
                    audioMime = mime
                }
            }
            if (videoMime == null || w <= 0 || h <= 0) return null
            val rotated = rotation == 90 || rotation == 270
            val display = if (rotated) h to w else w to h
            return Probe(
                w, h, rotated, videoMime, audioMime,
                display.first, display.second, frameRate,
            )
        } catch (e: Exception) {
            Log.w(TAG, "probeTracks($path): ${e.message}")
            return null
        } finally {
            runCatching { extractor.release() }
        }
    }

    private fun transform(
        jobId: String,
        handle: JobHandle,
        src: File,
        srcIsTemp: Boolean,
        probe: Probe,
    ) {
        val outFile = File(outDir, "$jobId.mp4")
        val (encW, encH) =
            CompressionPlan.outputSize(probe.encWidth, probe.encHeight, probe.rotated)
        // Les effets s'appliquent AVANT la rotation : la cible de
        // Presentation est la taille d'affichage, pas la taille encodée.
        val dispW = if (probe.rotated) encH else encW
        val dispH = if (probe.rotated) encW else encH
        val scale = Presentation.createForWidthAndHeight(
            dispW,
            dispH,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )
        val mediaItem = MediaItem.fromUri(Uri.fromFile(src))
        val edited = EditedMediaItem.Builder(mediaItem)
            .setEffects(Effects(listOf(), listOf(scale)))
            .build()
        val transformer = Transformer.Builder(context)
            .setLooper(thread.looper)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(
                DefaultEncoderFactory.Builder(context)
                    .setEnableFallback(true)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder()
                            .setBitrate(CompressionPlan.VIDEO_BITRATE)
                            .build(),
                    )
                    .setRequestedAudioEncoderSettings(
                        AudioEncoderSettings.Builder()
                            .setBitrate(CompressionPlan.AUDIO_BITRATE)
                            .build(),
                    )
                    .build(),
            )
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
                    if (handle.cancelled) {
                        settleCancelled(jobId)
                        if (srcIsTemp) src.delete()
                        return
                    }
                    settleDone(jobId, File(outDir, "$jobId.mp4"), passthrough = false)
                    if (srcIsTemp) src.delete()
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException,
                ) {
                    if (handle.cancelled) {
                        settleCancelled(jobId)
                    } else {
                        Log.w(TAG, "transform error $jobId: ${exception.message}")
                        settleError(jobId, "encoder", exception.message ?: "encodeur")
                    }
                    if (srcIsTemp) src.delete()
                }
            })
            .build()
        handle.transformer = transformer
        try {
            notify.start(File(src.absolutePath).name)
            transformer.start(edited, outFile.absolutePath)
            pollProgress(jobId, transformer)
        } catch (e: Exception) {
            Log.e(TAG, "transform($jobId)", e)
            if (handle.cancelled) settleCancelled(jobId) else {
                settleError(jobId, "encoder", e.message ?: "transformer")
            }
        }
    }

    /** Sonde sur la thread du job (looper courant) : `getProgress` l'exige. */
    private fun pollProgress(jobId: String, transformer: Transformer) {
        val holder = ProgressHolder()
        val polling = Handler(Looper.myLooper()!!)
        val runnable = object : Runnable {
            override fun run() {
                if (isSettled(jobId)) return
                val state = try {
                    transformer.getProgress(holder)
                } catch (e: Exception) {
                    Transformer.PROGRESS_STATE_UNAVAILABLE
                }
                if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                    notify.progress(holder.progress)
                    emit(
                        mapOf(
                            "kind" to "progress",
                            "jobId" to jobId,
                            "percent" to holder.progress,
                        ),
                    )
                }
                if (!isSettled(jobId)) polling.postDelayed(this, PROGRESS_POLL_MS)
            }
        }
        polling.post(runnable)
    }

    private fun isSettled(jobId: String): Boolean =
        synchronized(jobs) { !jobs.containsKey(jobId) }

    private fun settleDone(jobId: String, file: File, passthrough: Boolean) {
        val m = meta(file.absolutePath)
        emit(
            mapOf(
                "kind" to "done",
                "jobId" to jobId,
                "outputPath" to file.absolutePath,
                "width" to (m?.get("width") ?: 0),
                "height" to (m?.get("height") ?: 0),
                "durationMs" to (m?.get("durationMs") ?: 0),
                "sizeBytes" to file.length(),
                "passthrough" to passthrough,
            ),
        )
        notify.done()
        forget(jobId)
    }

    private fun settleError(jobId: String, code: String, message: String) {
        emit(
            mapOf(
                "kind" to "error",
                "jobId" to jobId,
                "code" to code,
                "message" to message,
            ),
        )
        notify.failed()
        forget(jobId)
    }

    private fun settleCancelled(jobId: String) {
        emit(mapOf("kind" to "cancelled", "jobId" to jobId))
        File(outDir, "$jobId.mp4").delete()
        File(outDir, "${jobId}_in.part").delete()
        notify.clear()
        forget(jobId)
    }

    private fun forget(jobId: String) {
        synchronized(jobs) { jobs.remove(jobId) }
    }

    companion object {
        private const val TAG = "VideoBridge"
        private const val METADATA_WIDTH = MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
        private const val METADATA_HEIGHT = MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
        private const val METADATA_ROTATION = MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
        private const val METADATA_DURATION = MediaMetadataRetriever.METADATA_KEY_DURATION
        const val PROGRESS_POLL_MS = 500L
        const val ORPHAN_TTL_MS = 24L * 60 * 60 * 1000
    }
}

private fun File.copyToOrFalse(target: File): Boolean = try {
    copyTo(target, overwrite = true)
    true
} catch (e: Exception) {
    false
}
