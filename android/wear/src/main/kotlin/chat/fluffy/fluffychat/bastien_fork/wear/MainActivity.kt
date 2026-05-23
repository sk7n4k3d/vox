package chat.fluffy.fluffychat.bastien_fork.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import chat.fluffy.fluffychat.bastien_fork.wear.bridge.WearForegroundService
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberpunkWearTheme
import chat.fluffy.fluffychat.bastien_fork.wear.ui.WearApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WearForegroundService.start(applicationContext)
        setContent {
            CyberpunkWearTheme {
                WearApp()
            }
        }
    }
}
