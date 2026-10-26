package chat.fluffy.fluffychat

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import org.unifiedpush.android.connector.data.PushMessage
import org.unifiedpush.flutter.connector.Plugin
import org.unifiedpush.flutter.connector.UnifiedPushService

/**
 * Why this subclass exists (bug 2026-10-26, Matrix notifications silently dropped).
 *
 * The upstream [UnifiedPushService] only creates the headless Flutter engine that
 * handles pushes while the app has none, when the service is created in a process
 * where no Plugin was ever registered (`Plugin.count == 0`). That counter never
 * decrements. VOX keeps its process alive indefinitely (persistent VoIP foreground
 * service), so after the first UI session the UI engine is destroyed about two
 * minutes after backgrounding, its Plugin collector is cancelled, and every push
 * from then on is emitted into the in-memory flow with no collector: no exception,
 * no log, no notification. Messages only surface when the user next opens the app
 * (flow replay).
 *
 * Delivery therefore failed exactly when the process stayed alive — the new state
 * the VoIP service introduced — and kept working when the OS had killed the process.
 *
 * This subclass restores the intended behavior for the live-process case: on a
 * message with no live collector, start the headless engine (same mechanism and
 * Dart entry point as the fresh-process path) so the push is handled now instead of
 * on next app open. The engine is destroyed after a short idle period so it does
 * not compete with a reopened UI isolate.
 */
class VoxUnifiedPushService : UnifiedPushService() {

    private fun keepBackgroundCollectorAlive() {
        backgroundEngine?.let {
            IDLE_HANDLER.removeCallbacks(destroyBackgroundEngine)
            IDLE_HANDLER.postDelayed(destroyBackgroundEngine, ENGINE_IDLE_MS)
            return
        }
        runCatching {
            val engine = getEngine(applicationContext)
            val registry = engine.plugins
            (registry.get(Plugin::class.java) as? Plugin) ?: Plugin().also { registry.add(it) }
            backgroundEngine = engine
            IDLE_HANDLER.postDelayed(destroyBackgroundEngine, ENGINE_IDLE_MS)
            Log.i(TAG, "no live push collector: started headless engine")
        }.onFailure { Log.w(TAG, "headless engine start failed", it) }
    }

    override fun onMessage(message: PushMessage, instance: String) {
        if (Plugin.calls.subscriptionCount.value == 0) keepBackgroundCollectorAlive()
        super.onMessage(message, instance)
    }

    companion object {
        private const val TAG = "VoxUnifiedPushService"
        private const val ENGINE_IDLE_MS = 60_000L
        private val IDLE_HANDLER = Handler(Looper.getMainLooper())
        private var backgroundEngine: FlutterEngine? = null
        private val destroyBackgroundEngine = Runnable {
            backgroundEngine?.let { runCatching { it.destroy() } }
            backgroundEngine = null
        }
    }
}
