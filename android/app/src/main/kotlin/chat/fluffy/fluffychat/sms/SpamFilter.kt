package chat.fluffy.fluffychat.sms

import android.content.Context
import android.util.Log

/**
 * Persistent set of thread ids the local spam filter (Dart side) has flagged.
 *
 * The native notifier fires synchronously on SMS_DELIVER — before Dart ever
 * sees the event — so the only way to keep a known-spam thread silent even when
 * the app is closed is a native, persisted set that [SmsNotifier] consults.
 * Dart classifies a thread and mirrors the verdict here via the plugin; the
 * first message of a brand-new spam thread may still notify once (unknown yet).
 */
object SpamFilter {

    private const val PREFS = "vox_spam"
    private const val KEY_THREADS = "spam_threads"

    fun isSpam(context: Context, threadId: Long): Boolean {
        if (threadId <= 0L) return false
        return try {
            prefs(context).getStringSet(KEY_THREADS, emptySet())
                ?.contains(threadId.toString()) == true
        } catch (e: Exception) {
            Log.w(SmsBridge.TAG, "SpamFilter.isSpam failed: ${e.message}")
            false
        }
    }

    fun mark(context: Context, threadId: Long, spam: Boolean) {
        if (threadId <= 0L) return
        try {
            val p = prefs(context)
            val current = HashSet(p.getStringSet(KEY_THREADS, emptySet()) ?: emptySet())
            if (spam) current.add(threadId.toString()) else current.remove(threadId.toString())
            p.edit().putStringSet(KEY_THREADS, current).apply()
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "SpamFilter.mark failed: ${e.message}")
        }
    }

    fun list(context: Context): List<String> {
        return try {
            prefs(context).getStringSet(KEY_THREADS, emptySet())
                ?.toList()
                ?: emptyList()
        } catch (e: Exception) {
            Log.w(SmsBridge.TAG, "SpamFilter.list failed: ${e.message}")
            emptyList()
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
