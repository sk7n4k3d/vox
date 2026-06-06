package chat.fluffy.fluffychat

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

import android.content.Context
import android.content.Intent
import android.os.Bundle

import chat.fluffy.fluffychat.wear.WearBridgePlugin
import chat.fluffy.fluffychat.sms.SmsBridgePlugin

class MainActivity : FlutterFragmentActivity() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleSmsIntent(intent)
    }

    /**
     * Hook Flutter officiel : reçoit l'engine RÉELLEMENT utilisé par cette
     * Activity. `super` exécute GeneratedPluginRegistrant (plugins pub.dev :
     * local_auth, secure_storage…). On y enregistre EN PLUS nos plugins natifs
     * custom (Wear + SMS) sur CE même engine — sinon leurs MethodChannel n'ont
     * aucun handler et tous les appels Dart lèvent une MissingPluginException
     * (« VOX n'est pas l'app SMS par défaut » alors que le rôle est accordé).
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WearBridgePlugin.register(applicationContext, flutterEngine)
        SmsBridgePlugin.register(applicationContext, flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSmsIntent(intent)
    }

    /**
     * Capte un intent qui pointe vers une conversation SMS (tap notif, action
     * "Vocal", ou ouverture sms:/smsto: par une autre app) et le pousse vers
     * Flutter pour qu'il ouvre la bonne conversation.
     */
    private fun handleSmsIntent(intent: Intent?) {
        if (intent == null) return
        val data = intent.data
        val scheme = data?.scheme
        val isSmsScheme = scheme == "sms" || scheme == "smsto" ||
            scheme == "mms" || scheme == "mmsto"
        val threadId = intent.getLongExtra("thread_id", -1L)
        val address = intent.getStringExtra("address")
            ?: data?.schemeSpecificPart?.takeIf { isSmsScheme }
        if (threadId <= 0L && address.isNullOrBlank()) return
        SmsBridgePlugin.setPendingSmsIntent(
            threadId = if (threadId > 0L) threadId else -1L,
            address = address,
            voiceReply = intent.getBooleanExtra("voice_reply", false),
        )
    }

    override fun onResume() {
        super.onResume()
        // Donne au plugin SMS l'Activity courante pour startActivityForResult
        // (RoleManager.createRequestRoleIntent / ACTION_CHANGE_DEFAULT).
        SmsBridgePlugin.attachActivity(this)
    }

    override fun onPause() {
        SmsBridgePlugin.attachActivity(null)
        super.onPause()
    }

    // NB : l'enregistrement des plugins natifs (Wear + SMS) se fait dans
    // configureFlutterEngine ci-dessus, sur l'engine réellement utilisé par
    // l'Activity. L'ancien pattern `provideEngine`/cached-engine n'était appelé
    // que par FcmPushService (actuellement commenté) — retiré car code mort qui
    // dupliquait l'enregistrement. Si le push background est réactivé, lui
    // donner son propre engine et y rappeler les `register` à ce moment-là.
}
