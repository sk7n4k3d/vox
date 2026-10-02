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
import com.google.mlkit.nl.smartreply.SmartReply
import com.google.mlkit.nl.smartreply.SmartReplySuggestion
import com.google.mlkit.nl.smartreply.SmartReplySuggestionResult
import com.google.mlkit.nl.smartreply.TextMessage
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

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
    const val ACTION_COPY_OTP = "eu.devlabz.vox.SMS_COPY_OTP"
    const val ACTION_VOICE_REPLY = "eu.devlabz.vox.SMS_VOICE_REPLY"
    const val KEY_REPLY_TEXT = "key_reply_text"
    const val EXTRA_THREAD_ID = "thread_id"
    const val EXTRA_ADDRESS = "address"
    const val EXTRA_OTP_CODE = "otp_code"

    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_ENABLED = "flutter.chat.fluffy.sms_notifications_enabled"
    private const val KEY_PREVIEW = "flutter.chat.fluffy.sms_notifications_preview"
    private const val KEY_SOUND = "flutter.chat.fluffy.sms_notifications_sound"
    private const val KEY_LOCKED = "flutter.chat.fluffy.locked_conversations"

    private const val MAX_CONTEXT_MESSAGES = 8
    private const val MAX_SUGGESTIONS = 3
    private const val MAX_SUGGESTION_LENGTH = 80
    private const val LLM_CONTEXT_MESSAGES = 6

    /**
     * Historique court par thread pour reconstruire le MessagingStyle.
     *
     * Muté depuis le main thread ([SmsDeliverReceiver]) ET depuis Dispatchers.IO
     * ([SmsBridge.ingestDownloadedMms]) → map concurrente + synchronisation sur la
     * liste interne (add/trim concurrents corrompaient l'entrée HashMap).
     */
    private data class HistoryEntry(
        val timestamp: Long,
        val displayBody: String,
        val fullBody: String,
        val isLocal: Boolean,
    )

    private val history =
        ConcurrentHashMap<Long, MutableList<HistoryEntry>>() // threadId -> entries

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

        // Historique du thread (MessagingStyle), borné à 8 messages. La liste est
        // partagée main/IO → on la mute et la snapshotte sous le verrou de la liste.
        val msgs = history.getOrPut(threadId) { mutableListOf() }
        val recentMsgs = synchronized(msgs) {
            msgs.add(HistoryEntry(timestamp, shownBody, body, isLocal = false))
            while (msgs.size > 8) msgs.removeAt(0)
            msgs.toList()
        }

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
        recentMsgs.forEachIndexed { index, entry ->
            val message = NotificationCompat.MessagingStyle.Message(
                entry.displayBody,
                entry.timestamp,
                person,
            )
            // Attach the image only to the most recent message (this MMS).
            if (index == recentMsgs.lastIndex && imageUri != null) {
                message.setData(imageMime ?: "image/jpeg", imageUri)
            }
            style.addMessage(message)
        }

        val replyAction = buildReplyAction(
            context = context,
            threadId = threadId,
            address = address,
            locked = locked,
            choices = if (locked) emptyArray() else {
                llmRepliesFor(context, threadId, recentMsgs) ?: quickRepliesFor(body)
            },
        )
        val markReadAction = buildMarkReadAction(context, threadId)
        // Code OTP/2FA détecté dans le corps → action « Copier le code » (jamais
        // sur une conversation verrouillée, par sécurité).
        val otpCode = if (locked) null else OtpExtractor.extract(body)

        // Conversations API — sharing shortcut long-lived pour ce thread.
        // Prérequis pour que la notif apparaisse dans la section "Conversations"
        // et pour débloquer les bulles (Android 11+).
        val shortcutId = "sms_$threadId"
        runCatching {
            val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(senderName)
                .setLongLived(true)
                .setPerson(person)
                // ShortcutInfo EXIGE une action sur l'intent, sinon
                // pushDynamicShortcut lève IllegalArgumentException (avalée par le
                // runCatching) → le shortcut n'est jamais publié et la notif
                // n'apparaît pas en "conversation". On force ACTION_VIEW.
                .setIntent(
                    buildAppIntent(context, threadId, address)
                        .setAction(Intent.ACTION_VIEW),
                )
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
            .apply {
                // Action « Copier le code » en premier quand un OTP est détecté.
                if (otpCode != null) {
                    addAction(buildCopyOtpAction(context, threadId, otpCode))
                }
            }
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
        LlmSuggestions.invalidate(threadId)
        NotificationManagerCompat.from(context).cancel(threadId.toInt())
    }

    /**
     * Génère de manière asynchrone (ML Kit on-device, PAS GMS) jusqu'à
     * [MAX_SUGGESTIONS] suggestions de réponses rapides pour le thread
     * [threadId], puis appelle [onSuggestions] (sur un thread interne ML Kit)
     * avec la liste filtrée (vide en cas d'échec, de statut non SUCCESS, ou de
     * fil français).
     *
     * ML Kit Smart Reply n'est entraîné que pour l'anglais : sur un fil détecté
     * comme français on court-circuite volontairement (liste vide) pour laisser
     * la place aux réponses rapides FR de [quickRepliesFor], plutôt que
     * d'exposer des suggestions génériques. Aucune suggestion figée n'est
     * injectée quand ML Kit ne renvoie rien.
     *
     * @param threadId identifiant du thread SMS.
     * @param senderId identifiant opaque de l'expéditeur (numéro ou address) —
     *                 utilisé par ML Kit pour distinguer les participants
     *                 distants.
     * @param onSuggestions callback appelé avec la liste de
     *                      [SmartReplySuggestion] (max [MAX_SUGGESTIONS], peut
     *                      être vide).
     */
    fun suggestRepliesAsync(
        threadId: Long,
        senderId: String,
        onSuggestions: (List<SmartReplySuggestion>) -> Unit,
    ) {
        val msgs = history[threadId] ?: run {
            onSuggestions(emptyList())
            return
        }
        // Snapshot sous verrou : la liste peut être mutée en parallèle (main/IO).
        val snapshot = synchronized(msgs) { msgs.toList() }
        val last = snapshot.lastOrNull()
        if (last != null && looksFrench(last.fullBody)) {
            onSuggestions(emptyList())
            return
        }
        // Conversation ML Kit : 8 derniers messages, ordre chronologique, corps
        // complet, local/remote marqué par HistoryEntry.isLocal.
        val conversation = snapshot
            .sortedBy { it.timestamp }
            .takeLast(MAX_CONTEXT_MESSAGES)
            .map { entry ->
                if (entry.isLocal) {
                    TextMessage.createForLocalUser(entry.fullBody, entry.timestamp)
                } else {
                    TextMessage.createForRemoteUser(entry.fullBody, entry.timestamp, senderId)
                }
            }
        SmartReply.getClient().suggestReplies(conversation)
            .addOnSuccessListener { result ->
                val suggestions = if (result.status == SmartReplySuggestionResult.STATUS_SUCCESS) {
                    filterSuggestions(result.suggestions)
                } else {
                    emptyList()
                }
                onSuggestions(suggestions)
            }
            .addOnFailureListener {
                onSuggestions(emptyList())
            }
    }

    /** Retire doublons/vides/trop longues et plafonne à [MAX_SUGGESTIONS]. */
    private fun filterSuggestions(
        raw: List<SmartReplySuggestion>,
    ): List<SmartReplySuggestion> {
        val seen = HashSet<String>()
        val out = ArrayList<SmartReplySuggestion>(MAX_SUGGESTIONS)
        for (suggestion in raw) {
            val text = suggestion.text.trim()
            if (text.isEmpty() || text.length > MAX_SUGGESTION_LENGTH) continue
            if (!seen.add(text.lowercase(Locale.ROOT))) continue
            out.add(suggestion)
            if (out.size == MAX_SUGGESTIONS) break
        }
        return out
    }

    /**
     * Tente des suggestions LLM pour cette notification. Renvoie null si le LLM
     * est désactivé, indisponible ou n'a rien produit d'exploitable — l'appelant
     * retombe alors sur [quickRepliesFor]. Bloquante et bornée (voir
     * [LlmSuggestions]) : appelée depuis notifyIncoming sur Dispatchers.IO.
     */
    private fun llmRepliesFor(
        context: Context,
        threadId: Long,
        recentMsgs: List<HistoryEntry>,
    ): Array<String>? {
        val transcript = recentMsgs
            .takeLast(LLM_CONTEXT_MESSAGES)
            .joinToString("\n") { entry ->
                val who = if (entry.isLocal) "Moi" else "Contact"
                "$who: ${entry.fullBody}"
            }
        val replies = LlmSuggestions.suggest(context, threadId, transcript)
        return replies.takeIf { it.isNotEmpty() }?.toTypedArray()
    }

    /**
     * Réponses rapides contextuelles pour l'action « Répondre » de la notif.
     *
     * ML Kit n'étant fiable qu'en anglais, on préfère ici un petit jeu de
     * réponses dérivé du contenu du dernier SMS plutôt que des libellés figés
     * identiques pour tous les fils. Liste vide quand la langue n'est pas
     * reconnue comme française (mieux vaut la saisie libre qu'un hors-sujet).
     */
    private fun quickRepliesFor(body: String): Array<String> {
        if (!looksFrench(body)) return emptyArray()
        val t = body.lowercase(Locale.ROOT)
        return when {
            FRENCH_THANKS.any { t.contains(it) } ->
                arrayOf("De rien", "👍", "Avec plaisir")
            t.contains("?") || FRENCH_QUESTION.any { t.contains(it) } ->
                arrayOf("Oui", "Non", "Je te rappelle")
            FRENCH_ETA.any { t.contains(it) } ->
                arrayOf("J'arrive", "Je te rappelle", "👍")
            else ->
                arrayOf("👍", "D'accord", "J'arrive")
        }
    }

    /** Détection basique : accents ou marqueurs fonctionnels français. */
    private fun looksFrench(text: String): Boolean {
        if (text.isBlank()) return false
        if (text.any { it in "àâäéèêëîïôöùûüçœÀÂÄÉÈÊËÎÏÔÖÙÛÜÇŒ" }) return true
        val lower = " ${text.lowercase(Locale.ROOT)} "
        return FRENCH_MARKERS.count { lower.contains(it) } >= 2
    }

    private val FRENCH_MARKERS = listOf(
        "bonjour", "salut", "coucou", "merci", "stp", "s'il te plaît",
        "je ", "tu ", "nous ", "vous ", " on ", "est-ce", " demain",
        "aujourd'hui", " ce soir", " pour ", " avec ", " que ",
        " qui ", " quoi", " comment", " quand", " où ", " combien",
        " bien ", " très ", " oui", " pas ", " plus ",
    )

    private val FRENCH_THANKS = listOf("merci", "thanks")
    private val FRENCH_QUESTION = listOf("quand", "heure", "où", "combien", "peux-tu", "peux tu")
    private val FRENCH_ETA = listOf("rdv", "rendez", "arriv", "retard", "route")

    private fun buildReplyAction(
        context: Context,
        threadId: Long,
        address: String,
        locked: Boolean,
        choices: Array<String> = emptyArray(),
    ): NotificationCompat.Action {
        val remoteInputBuilder = RemoteInput.Builder(KEY_REPLY_TEXT)
            .setLabel("Répondre")
        // Suggestions contextuelles uniquement (voir quickRepliesFor). Liste
        // vide → aucune choice : mieux vaut la saisie libre qu'un libellé
        // toujours identique et hors contexte.
        if (choices.isNotEmpty()) remoteInputBuilder.setChoices(choices)
        val remoteInput = remoteInputBuilder.build()
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

    private fun buildCopyOtpAction(
        context: Context,
        threadId: Long,
        code: String,
    ): NotificationCompat.Action {
        val intent = Intent(context, SmsReplyReceiver::class.java).apply {
            action = ACTION_COPY_OTP
            setPackage(context.packageName)
            putExtra(EXTRA_THREAD_ID, threadId)
            putExtra(EXTRA_OTP_CODE, code)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            (threadId * 4 + 1).toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_save,
            "Copier $code",
            pi,
        ).build()
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
