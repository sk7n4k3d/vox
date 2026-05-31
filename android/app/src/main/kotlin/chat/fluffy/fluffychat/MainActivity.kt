package chat.fluffy.fluffychat

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

import android.content.Context

import chat.fluffy.fluffychat.wear.WearBridgePlugin
import chat.fluffy.fluffychat.sms.SmsBridgePlugin

class MainActivity : FlutterActivity() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // do nothing, because the engine was been configured in provideEngine
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

    companion object {
        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false)
            engine = eng
            WearBridgePlugin.register(context, eng)
            SmsBridgePlugin.register(context, eng)
            return eng
        }
    }
}
