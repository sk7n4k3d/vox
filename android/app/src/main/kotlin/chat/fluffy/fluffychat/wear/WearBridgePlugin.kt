package chat.fluffy.fluffychat.wear

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `chat.fluffy.fluffychat/wear_bridge`.
 *
 * Méthodes appelables depuis Dart :
 *   - `pushRooms(String json)` → publie le DataItem `/wear/rooms`.
 *
 * Events poussés vers Dart :
 *   - `onRefreshRequested()` → la watch a ping, redemander un push.
 */
class WearBridgePlugin private constructor(
    private val context: Context,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler {

    init {
        channel.setMethodCallHandler(this)
        WearBridge.refreshRequestedCallback = {
            Handler(Looper.getMainLooper()).post {
                channel.invokeMethod("onRefreshRequested", null)
            }
        }
        WearBridge.voiceReceivedCallback = { msg ->
            Handler(Looper.getMainLooper()).post {
                channel.invokeMethod(
                    "onVoiceReceived",
                    mapOf(
                        "uuid" to msg.uuid,
                        "roomId" to msg.roomId,
                        "durationMs" to msg.durationMs,
                        "mimeType" to msg.mimeType,
                        "bytes" to msg.bytes
                    )
                )
            }
        }
        // Sprint 2 V3.2 — drain les vocaux watch persistés pendant que
        // Flutter était down. Préserve l'ordre d'arrivée (FIFO par filename
        // timestamp).
        WearBridge.drainPendingVoices(context)
        WearBridge.messagesRequestedCallback = { roomId ->
            Handler(Looper.getMainLooper()).post {
                channel.invokeMethod("onMessagesRequested", mapOf("roomId" to roomId))
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pushRooms" -> {
                val json = call.argument<String>("json")
                if (json.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "json missing", null)
                    return
                }
                WearBridge.pushRoomsJson(context, json)
                result.success(true)
            }
            "ackVoice" -> {
                val uuid = call.argument<String>("uuid")
                val success = call.argument<Boolean>("success") ?: false
                if (uuid.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "uuid missing", null)
                    return
                }
                WearBridge.ackVoice(context, uuid, success)
                result.success(true)
            }
            "pushMessages" -> {
                val roomId = call.argument<String>("roomId")
                val json = call.argument<String>("json")
                if (roomId.isNullOrEmpty() || json.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "roomId or json missing", null)
                    return
                }
                WearBridge.pushMessagesJson(context, roomId, json)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "chat.fluffy.fluffychat/wear_bridge"

        @Volatile
        private var instance: WearBridgePlugin? = null

        /** Idempotent — peut être appelé à chaque création d'engine. */
        fun register(context: Context, engine: FlutterEngine) {
            if (instance != null) return
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            instance = WearBridgePlugin(context.applicationContext, channel)
        }
    }
}
