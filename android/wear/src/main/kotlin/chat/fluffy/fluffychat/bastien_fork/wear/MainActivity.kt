package chat.fluffy.fluffychat.bastien_fork.wear

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import chat.fluffy.fluffychat.bastien_fork.wear.bridge.WearForegroundService
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberpunkWearTheme
import chat.fluffy.fluffychat.bastien_fork.wear.ui.WearApp
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader

class MainActivity : ComponentActivity() {

    // Deep-link demandé par une notif (tap sur le corps) : roomId à ouvrir au
    // démarrage. mutableStateOf pour que onNewIntent (activité déjà vivante grâce
    // à FLAG_ACTIVITY_CLEAR_TOP) puisse re-router vers une autre room.
    private val pendingRoomId = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WearForegroundService.start(applicationContext)
        // Sprint 2 audit finding-024 — relance les uploads vocaux orphelins
        // (process killé mid-upload). Pas un WorkManager complet (roadmap
        // Sprint 4) mais évite déjà la perte silencieuse d'audios.
        runCatching { VoiceUploader.reEnqueueOrphans(applicationContext) }

        pendingRoomId.value = extractRoomId(intent)

        setContent {
            CyberpunkWearTheme {
                WearApp(
                    initialRoomId = pendingRoomId.value,
                    onInitialRoomConsumed = { pendingRoomId.value = null }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractRoomId(intent)?.let { pendingRoomId.value = it }
    }

    private fun extractRoomId(intent: Intent?): String? =
        if (intent?.action == ACTION_OPEN_ROOM) {
            intent.getStringExtra(EXTRA_ROOM_ID)?.takeIf { it.isNotEmpty() }
        } else null

    companion object {
        const val ACTION_OPEN_ROOM =
            "chat.fluffy.fluffychat.bastien_fork.wear.OPEN_ROOM"
        const val EXTRA_ROOM_ID = "roomId"
    }
}
