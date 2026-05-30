package chat.fluffy.fluffychat.bastien_fork.wear.notif

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import chat.fluffy.fluffychat.bastien_fork.wear.MainActivity
import chat.fluffy.fluffychat.bastien_fork.wear.R
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomEntry
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomsSnapshot

/**
 * Détecte les messages Matrix non lus *nouveaux* à partir des snapshots `/wear/rooms`
 * poussés par le phone, et émet une notification par room concernée avec :
 *   - MessagingStyle (expéditeur + aperçu du dernier message)
 *   - une action "Répondre en vocal" qui lance [VoiceRecordingService] en mode headless
 *     (l'upload est déclenché par le service lui-même au stop, cf. autoUpload)
 *   - un RemoteInput texte (dictée/clavier système Wear) comme fallback rapide
 *
 * ## Détection "nouveau non lu"
 * Le snapshot ne porte PAS de flag "non lu par message" : on a seulement
 * [RoomEntry.unread] (compteur), [RoomEntry.lastEventTs] et [RoomEntry.preview].
 * On persiste, par room, le dernier `lastEventTs` *déjà notifié*. On notifie une
 * room si et seulement si :
 *   - `unread > 0` (il reste des non lus côté phone), ET
 *   - `lastEventTs > lastNotifiedTs(room)` (un message plus récent est arrivé).
 *
 * Limites assumées (cf. rapport) :
 *   - On ne distingue pas les messages individuels : une room qui reçoit 3 messages
 *     d'affilée produit UNE notif (la dernière), pas trois. Acceptable sur montre.
 *   - Si le phone marque la room lue, `unread` retombe à 0 → on annule la notif.
 *   - Pas de notif au tout premier snapshot après install (baseline silencieuse)
 *     pour éviter un flood de "non lus historiques".
 */
object MessageNotifier {

    private const val TAG = "MessageNotifier"
    const val CHANNEL_ID = "wear_messages_v1"

    // Décalage d'ID pour ne pas collisionner avec les NOTIF_ID des foreground
    // services (4242 WearForegroundService, 4243 VoiceRecordingService).
    private const val NOTIF_ID_BASE = 5000

    private const val PREFS_NAME = "wear_msg_notif"
    private const val KEY_BASELINE_DONE = "baseline_done"
    private const val PREFIX_LAST_TS = "lastTs."

    private val prefsLock = Any()

    /**
     * Point d'entrée appelé à chaque snapshot rooms reçu. Idempotent : ne notifie
     * que les rooms dont le dernier event est plus récent que la dernière notif.
     */
    fun onRoomsSnapshot(context: Context, snapshot: RoomsSnapshot) {
        ensureChannel(context)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // Toutes les rooms connues du snapshot (favoris + récents), dédupliquées par id.
        val rooms = (snapshot.favorites + snapshot.recents)
            .associateBy { it.id }
            .values

        // Premier snapshot après (ré)install : on enregistre la baseline sans notifier,
        // sinon on spammerait toutes les rooms ayant un historique non lu.
        val baselineDone = prefs.getBoolean(KEY_BASELINE_DONE, false)
        if (!baselineDone) {
            synchronized(prefsLock) {
                val editor = prefs.edit().putBoolean(KEY_BASELINE_DONE, true)
                for (room in rooms) {
                    editor.putLong(PREFIX_LAST_TS + room.id, room.lastEventTs)
                }
                editor.apply()
            }
            Log.d(TAG, "baseline recorded for ${rooms.size} rooms, no notif emitted")
            return
        }

        for (room in rooms) {
            val lastNotified = prefs.getLong(PREFIX_LAST_TS + room.id, 0L)
            val hasNewer = room.lastEventTs > lastNotified
            val hasUnread = room.unread > 0

            when {
                hasNewer && hasUnread -> {
                    notifyRoom(context, room)
                    persistLastTs(prefs, room.id, room.lastEventTs)
                }
                // Room relue côté phone (unread retombé à 0) → on retire la notif
                // résiduelle et on aligne la baseline pour ne pas re-notifier après.
                !hasUnread -> {
                    cancelRoom(context, room.id)
                    if (room.lastEventTs > lastNotified) {
                        persistLastTs(prefs, room.id, room.lastEventTs)
                    }
                }
            }
        }
    }

    private fun persistLastTs(prefs: SharedPreferences, roomId: String, ts: Long) {
        synchronized(prefsLock) {
            prefs.edit().putLong(PREFIX_LAST_TS + roomId, ts).apply()
        }
    }

    private fun notifyRoom(context: Context, room: RoomEntry) {
        val nm = NotificationManagerCompat.from(context)
        // Respecte le refus runtime de POST_NOTIFICATIONS (Wear OS 4+/API 33+).
        if (!nm.areNotificationsEnabled()) {
            Log.d(TAG, "notifications disabled, skip ${room.id.redact()}")
            return
        }

        val notifId = notifId(room.id)
        val preview = room.preview.ifBlank { "Nouveau message" }

        // Person : pour un DM, le sender = nom de la room ; sinon on garde le nom de
        // la room comme conversation et l'aperçu porte déjà l'expéditeur côté phone.
        val sender = Person.Builder()
            .setName(room.name.ifBlank { "Message" })
            .setKey(room.id)
            .build()

        val style = NotificationCompat.MessagingStyle(
            Person.Builder().setName("Moi").build(),
        )
            .setConversationTitle(room.name.ifBlank { null })
            .setGroupConversation(!room.isDirect)
            .addMessage(
                preview,
                room.lastEventTs.takeIf { it > 0 } ?: System.currentTimeMillis(),
                sender,
            )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setStyle(style)
            .setContentTitle(room.name.ifBlank { "Message" })
            .setContentText(preview)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openRoomIntent(context, room.id, notifId))
            .setDeleteIntent(dismissIntent(context, room.id, notifId))
            .addAction(voiceReplyAction(context, room.id, notifId))
            .addAction(textReplyAction(context, room.id, notifId))

        try {
            nm.notify(notifId, builder.build())
            Log.d(TAG, "notified room=${room.id.redact()} unread=${room.unread}")
        } catch (se: SecurityException) {
            // areNotificationsEnabled() peut mentir si la permission a été révoquée
            // entre le check et le notify(). On avale proprement.
            Log.w(TAG, "notify denied for ${room.id.redact()}", se)
        }
    }

    fun cancelRoom(context: Context, roomId: String) {
        NotificationManagerCompat.from(context).cancel(notifId(roomId))
    }

    // --- PendingIntents ------------------------------------------------------

    private fun openRoomIntent(context: Context, roomId: String, notifId: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_ROOM
            putExtra(MainActivity.EXTRA_ROOM_ID, roomId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context,
            notifId, // requestCode unique par room → pas d'écrasement d'extra
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun voiceReplyAction(context: Context, roomId: String, notifId: Int): NotificationCompat.Action {
        val intent = NotificationActionReceiver.voiceReplyIntent(context, roomId, notifId)
        val pi = PendingIntent.getBroadcast(
            context,
            notifId, // requestCode distinct des autres actions via offset interne
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Action.Builder(
            R.mipmap.ic_launcher,
            "Vocal",
            pi
        ).build()
    }

    private fun textReplyAction(context: Context, roomId: String, notifId: Int): NotificationCompat.Action {
        val remoteInput = RemoteInput.Builder(NotificationActionReceiver.KEY_TEXT_REPLY)
            .setLabel("Répondre")
            .build()
        val intent = NotificationActionReceiver.textReplyIntent(context, roomId, notifId)
        // RemoteInput exige un PendingIntent MUTABLE pour que le système y injecte
        // le résultat de la saisie/dictée.
        val pi = PendingIntent.getBroadcast(
            context,
            notifId + REQUEST_OFFSET_TEXT,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
        return NotificationCompat.Action.Builder(
            R.mipmap.ic_launcher,
            "Texte",
            pi
        ).addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(true)
            .build()
    }

    private fun dismissIntent(context: Context, roomId: String, notifId: Int): PendingIntent {
        val intent = NotificationActionReceiver.dismissIntent(context, roomId, notifId)
        return PendingIntent.getBroadcast(
            context,
            notifId + REQUEST_OFFSET_DISMISS,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // --- Infra ---------------------------------------------------------------

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Nouveaux messages Matrix"
            setShowBadge(true)
            enableVibration(true)
        }
        nm.createNotificationChannel(channel)
    }

    /** ID de notif stable par room (hash borné + base) pour pouvoir update/cancel. */
    private fun notifId(roomId: String): Int =
        NOTIF_ID_BASE + (roomId.hashCode() and 0x7FFFFF)

    private fun String.redact(n: Int = 4): String =
        if (length <= n) this else substring(0, n) + "****"

    // Offsets de requestCode pour garder des PendingIntent distincts par action
    // sur une même notif (sinon FLAG_UPDATE_CURRENT écraserait les extras).
    private const val REQUEST_OFFSET_TEXT = 0x1000000
    private const val REQUEST_OFFSET_DISMISS = 0x2000000
}
