package chat.fluffy.fluffychat.sms

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Notifications SMS riches (MessagingStyle) avec actions Répondre (texte inline
 * via RemoteInput) et Répondre vocal (ouvre la conversation en mode dictée).
 *
 * Une notification par thread, fil de messages conservé (MessagingStyle) pour
 * que plusieurs SMS d'un même expéditeur s'empilent dans la même notif.
 *
 * Réglages lus depuis les SharedPreferences partagées avec Flutter
 * (FlutterSharedPreferences) — clés posées par AppSettings côté Dart :
 *   - chat.fluffy.sms_notifications_enabled (bool, défaut true)
 *   - chat.fluffy.sms_notifications_preview (bool, défaut true)
 *   - chat.fluffy.sms_notifications_sound (bool, défaut true)
 * Le respect du verrou de conversation est passé en paramètre (calculé côté
 * Kotlin à partir de la liste persistée par Dart).
 */
object SmsNotifier {

    const val CHANNEL_ID = "vox_sms"
    const val ACTION_REPLY = "eu.devlabz.vox.SMS_REPLY"
    const val ACTION_MARK_READ = "eu.devlabz.vox.SMS_MARK_READ"
    const val ACTION_VOICE_REPLY = "eu.devlabz.vox.SMS_VOICE_REPLY"
    const val KEY_REPLY_TEXT = "key_reply_text"
    const val EXTRA_THREAD_ID = "thread_id"
    const val EXTRA_ADDRESS = "address"

    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_ENABLED = "flutter.chat.fluffy.sms_notifications_enabled"
    private const val KEY_PREVIEW = "flutter.chat.fluffy.sms_notifications_preview"
    private const val KEY_SOUND = "flutter.chat.fluffy.sms_notifications_sound"
    private const val KEY_LOCKED = "flutter.chat.fluffy.locked_conversations"

    /** Historique court par thread pour reconstruire le MessagingStyle. */
    private val history = HashMap<Long, MutableList<Pair<Long, String>>>() // threadId -> [(ts, body)]

    /**
     * Thread actuellement affiché au premier plan (posé par Dart via
     * setActiveSmsThread), ou -1. On ne notifie pas une conversation déjà
     * ouverte à l'écran.
     */
    @Volatile
    var activeThreadId: Long = -1L

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val sound = prefBool(context, KEY_SOUND, true)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "SMS",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Messages SMS / MMS"
            enableVibration(true)
            if (!sound) setSound(null, null)
        }
        mgr.createNotificationChannel(channel)
    }

    /**
     * Affiche/actualise la notification d'un SMS entrant. No-op si désactivé.
     * @param senderName nom affiché (contact ou numéro).
     * @param photoPath chemin local de la photo de contact (peut être null).
     */
    fun notifyIncoming(
        context: Context,
        threadId: Long,
        address: String,
        senderName: String,
        body: String,
        photoPath: String?,
        timestamp: Long,
        /** Local path of an attached image to preview inline (MMS), or null. */
        imagePath: String? = null,
        imageMime: String? = null,
    ) {
        if (!prefBool(context, KEY_ENABLED, true)) return
        // Conversation déjà ouverte au premier plan → pas de notif.
        if (threadId == activeThreadId) return
        if (ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        ) {
            return
        }
        ensureChannel(context)

        val locked = isLocked(context, threadId)
        val showPreview = prefBool(context, KEY_PREVIEW, true) && !locked
        val shownBody = if (showPreview) body else "Nouveau message"

        // Historique du thread (MessagingStyle), borné à 8 messages.
        val msgs = history.getOrPut(threadId) { mutableListOf() }
        msgs.add(timestamp to shownBody)
        while (msgs.size > 8) msgs.removeAt(0)

        val person = Person.Builder()
            .setName(senderName)
            .apply {
                if (!locked && photoPath != null) {
                    runCatching {
                        BitmapFactory.decodeFile(photoPath)?.let {
                            setIcon(IconCompat.createWithBitmap(it))
                        }
                    }
                }
            }
            .build()

        // Content URI (FileProvider) for the attached image, granted read to the
        // system UI so MessagingStyle can render it inline. Only when previews
        // are allowed (respects the lock + preview settings).
        val imageUri: android.net.Uri? = if (showPreview && imagePath != null) {
            runCatching {
                androidx.core.content.FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    java.io.File(imagePath),
                )
            }.getOrNull()
        } else {
            null
        }

        val style = NotificationCompat.MessagingStyle(
            Person.Builder().setName("Moi").build(),
        )
            .setConversationTitle(
                if (locked) "Conversation verrouillée" else senderName,
            )
            .setGroupConversation(false)
        msgs.forEachIndexed { index, (ts, text) ->
            val message = NotificationCompat.MessagingStyle.Message(text, ts, person)
            // Attach the image only to the most recent message (this MMS).
            if (index == msgs.lastIndex && imageUri != null) {
                message.setData(imageMime ?: "image/jpeg", imageUri)
            }
            style.addMessage(message)
        }

        val replyAction = buildReplyAction(context, threadId, address, locked)
        val markReadAction = buildMarkReadAction(context, threadId)

        // Conversations API — sharing shortcut long-lived pour ce thread.
        // Prérequis pour que la notif apparaisse dans la section "Conversations"
        // et pour débloquer les bulles (Android 11+).
        val shortcutId = "sms_$threadId"
        runCatching {
            val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(senderName)
                .setLongLived(true)
                .setPerson(person)
                .setIntent(buildAppIntent(context, threadId, address))
                .setCategories(setOf("androidx.core.content.pm.category.SHARE_TARGET"))
                .build()
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
        }

        val notif = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(
                context.resources.getIdentifier(
                    "notifications_icon", "drawable", context.packageName,
                ).takeIf { it != 0 } ?: android.R.drawable.sym_action_email,
            )
            .setStyle(style)
            .setContentIntent(buildOpenIntent(context, threadId, address))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .addAction(replyAction)
            .addAction(markReadAction)
            .setShortcutId(shortcutId)
            .setLocusId(LocusIdCompat(shortcutId))
            .apply { if (!prefBool(context, KEY_SOUND, true)) setSilent(true) }
            .build()

        runCatching {
            NotificationManagerCompat.from(context).notify(threadId.toInt(), notif)
        }
    }

    /** Retire la notif d'un thread (après lecture / ouverture). */
    fun cancel(context: Context, threadId: Long) {
        history.remove(threadId)
        NotificationManagerCompat.from(context).cancel(threadId.toInt())
    }

    private fun buildReplyAction(
        context: Context,
        threadId: Long,
        address: String,
        locked: Boolean,
    ): NotificationCompat.Action {
        val remoteInput = RemoteInput.Builder(KEY_REPLY_TEXT)
            .setLabel("Répondre")
            .setChoices(arrayOf("👍", "OK", "J'arrive", "Je rappelle", "Merci"))
            .build()
        val intent = Intent(context, SmsReplyReceiver::class.java).apply {
            action = ACTION_REPLY
            setPackage(context.packageName)
            putExtra(EXTRA_THREAD_ID, threadId)
            putExtra(EXTRA_ADDRESS, address)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            (threadId * 4).toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Répondre",
            pi,
        ).addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(!locked)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .build()
    }

    private fun buildMarkReadAction(
        context: Context,
        threadId: Long,
    ): NotificationCompat.Action {
        val intent = Intent(context, SmsReplyReceiver::class.java).apply {
            action = ACTION_MARK_READ
            setPackage(context.packageName)
            putExtra(EXTRA_THREAD_ID, threadId)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            (threadId * 4 + 2).toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_view,
            "Marquer lu",
            pi,
        ).setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .build()
    }

    private fun buildOpenIntent(
        context: Context,
        threadId: Long,
        address: String,
    ): PendingIntent {
        return PendingIntent.getActivity(
            context,
            (threadId * 4 + 3).toInt(),
            buildAppIntent(context, threadId, address),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildAppIntent(context: Context, threadId: Long, address: String): Intent {
        // Cible MainActivity explicitement (pas de dépendance à un intent-filter
        // VIEW). singleTask → onNewIntent côté MainActivity capte les extras.
        return Intent().apply {
            setClassName(context.packageName, "chat.fluffy.fluffychat.MainActivity")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_THREAD_ID, threadId)
            putExtra(EXTRA_ADDRESS, address)
        }
    }

    /** Lit la liste des conversations verrouillées (persistée par Dart). */
    private fun isLocked(context: Context, threadId: Long): Boolean {
        return try {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_LOCKED, null) ?: return false
            // Dart persiste une List<String> sérialisée JSON par flutter_secure_storage
            // OU SharedPreferences ; ici on gère le cas JSON array de String.
            val cleaned = raw.removePrefix("!").let {
                if (it.startsWith("[")) it else "[]"
            }
            val arr = JSONArray(cleaned)
            val target = "sms:$threadId"
            (0 until arr.length()).any { arr.optString(it) == target }
        } catch (e: Exception) {
            false
        }
    }

    private fun prefBool(context: Context, key: String, default: Boolean): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.contains(key)) default else prefs.getBoolean(key, default)
        } catch (e: Exception) {
            default
        }
    }

    // Réservé : sérialisation éventuelle de l'historique si besoin de survie process.
    @Suppress("unused")
    private fun serializeHistory(): String = JSONObject().toString()
}
