package chat.fluffy.fluffychat.bastien_fork.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import chat.fluffy.fluffychat.bastien_fork.wear.bridge.WearForegroundService
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberpunkWearTheme
import chat.fluffy.fluffychat.bastien_fork.wear.ui.WearApp
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WearForegroundService.start(applicationContext)
        // Sprint 2 audit finding-024 — relance les uploads vocaux orphelins
        // (process killé mid-upload). Pas un WorkManager complet (roadmap
        // Sprint 4) mais évite déjà la perte silencieuse d'audios.
        runCatching { VoiceUploader.reEnqueueOrphans(applicationContext) }
        setContent {
            CyberpunkWearTheme {
                WearApp()
            }
        }
    }
}
