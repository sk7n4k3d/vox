package chat.fluffy.fluffychat.video

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Pont natif ↔ Dart pour la compression vidéo (Media3 Transformer).
 *
 * MethodChannel : `eu.devlabz.vox/video`         (Dart → natif)
 * EventChannel  : `eu.devlabz.vox/video_events`  (natif → Dart)
 *
 * Méthodes :
 *   - start{path, compress} -> {jobId} (immédiat ; le résultat vient en event)
 *   - cancel{jobId}         -> null
 *   - meta{path}            -> {width, height, durationMs, sizeBytes} | null
 *   - thumbnail{path, maxSize} -> ByteArray | null
 *   - cleanup{paths}        -> null (supprime uniquement sous cacheDir/video)
 *
 * La notification « Compression vidéo » (progression + Annuler) vit dans
 * VideoNotification, alimentée par VideoCompressorBridge.
 *
 * Idempotent : [register] peut être rappelé à chaque création d'engine.
 */
class VideoCompressorPlugin private constructor(
    context: Context,
    private val channel: MethodChannel,
    private val eventChannel: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val bridge = sharedBridge(context)

    init {
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        bridge.notify.onCancel = { jobId -> bridge.cancel(jobId) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val path = call.argument<String>("path")
                val compress = call.argument<Boolean>("compress")
                Log.i(TAG, "START CALLED: path=$path compress=$compress")
                if (path.isNullOrBlank()) {
                    result.error("unreadable", "chemin vide", null)
                    return
                }
                val jobId = bridge.start(path)
                Log.i(TAG, "START QUEUED: jobId=$jobId compress=$compress")
                result.success(mapOf("jobId" to jobId))
            }
            "cancel" -> {
                val jobId = call.argument<String>("jobId")
                if (jobId != null) bridge.cancel(jobId)
                result.success(null)
            }
            "meta" -> result.success(
                call.argument<String>("path")?.let { bridge.meta(it) },
            )
            "thumbnail" -> result.success(
                call.argument<String>("path")?.let { p ->
                    bridge.thumbnail(p, call.argument<Int>("maxSize") ?: 720)
                },
            )
            "cleanup" -> {
                @Suppress("UNCHECKED_CAST")
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                bridge.cleanup(paths)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        events?.let { sink ->
            VideoBridge.events.subscribe(this) { event ->
                try {
                    sink.success(event)
                } catch (e: Exception) {
                    Log.w(TAG, "event sink: ${e.message}")
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        VideoBridge.events.unsubscribe(this)
    }

    companion object {
        private const val TAG = "VideoPlugin"

        @Volatile
        private var bridge: VideoCompressorBridge? = null

        private fun sharedBridge(context: Context): VideoCompressorBridge =
            synchronized(this) {
                bridge ?: VideoCompressorBridge(context.applicationContext).also { bridge = it }
            }

        fun register(context: Context, flutterEngine: FlutterEngine) {
            val newChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger, CHANNEL_METHOD)
            val newEventChannel = EventChannel(
                flutterEngine.dartExecutor.binaryMessenger, CHANNEL_EVENTS)

            val plugin = VideoCompressorPlugin(context, newChannel, newEventChannel)
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {
                    VideoBridge.events.unsubscribe(plugin)
                }

                override fun onEngineWillDestroy() {
                    VideoBridge.events.unsubscribe(plugin)
                }
            })
        }

        private const val CHANNEL_METHOD = "eu.devlabz.vox/video"
        private const val CHANNEL_EVENTS = "eu.devlabz.vox/video_events"
    }
}
