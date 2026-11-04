package chat.fluffy.fluffychat.video

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import chat.fluffy.fluffychat.MainActivity
import chat.fluffy.fluffychat.R

/**
 * Notification de progression de la compression vidéo (canal `video_compression`) :
 * une seule notification, mise à jour à chaque tick, avec l'action Annuler.
 * Silencieuse (IMPORTANCE_LOW), ongoing pendant le job — l'original du modèle
 * `VoipBridge.showCallNotification`, même piège d'icône : notifications_icon
 * (le V blanc 24 dp), jamais le vector monochrome.
 */
class VideoNotification(private val context: Context) {

    private val mgr = context.getSystemService(NotificationManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var currentJobId: String? = null

    /** Câblé par VideoCompressorPlugin : annulation demandée depuis la notif. */
    @Volatile
    var onCancel: ((String) -> Unit)? = null

    private val cancelReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            if (intent?.action != ACTION_CANCEL) return
            val jobId = intent.getStringExtra(EXTRA_JOB_ID) ?: return
            onCancel?.invoke(jobId)
        }
    }

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            mgr?.getNotificationChannel(CHANNEL) == null
        ) {
            mgr?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Compression vidéo",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Progression de la compression des vidéos envoyées"
                    setShowBadge(false)
                    enableVibration(false)
                },
            )
        }
        val filter = IntentFilter(ACTION_CANCEL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(cancelReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(cancelReceiver, filter)
        }
    }


    fun start(fileName: String) {
        show(
            title = "Compression vidéo",
            text = fileName,
            percent = 0,
            indeterminate = true,
            ongoing = true,
        )
    }

    fun progress(percent: Int) {
        val jobId = currentJobId ?: return
        show(
            title = "Compression vidéo — $percent %",
            text = fileNameFor(jobId),
            percent = percent,
            indeterminate = false,
            ongoing = true,
        )
    }

    fun done() {
        show(
            title = "Compression vidéo",
            text = "Prête — $lastFileName",
            percent = 100,
            indeterminate = false,
            ongoing = false,
        )
        main.postDelayed({ clear() }, DISMISS_DELAY_MS)
    }

    fun failed() {
        show(
            title = "Échec de la compression vidéo",
            text = "Appuyez pour ouvrir VoxOne",
            percent = 0,
            indeterminate = false,
            ongoing = false,
        )
    }

    fun clear() {
        mgr?.cancel(NOTIFICATION_ID)
    }

    private var lastFileName: String = ""

    fun rememberFileName(name: String) {
        lastFileName = name
    }

    private fun fileNameFor(jobId: String): String = lastFileName

    private fun show(
        title: String,
        text: String,
        percent: Int,
        indeterminate: Boolean,
        ongoing: Boolean,
    ) {
        val mgr = mgr ?: return
        try {
            val openPending = PendingIntent.getActivity(
                context,
                REQ_OPEN,
                Intent(context, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.notifications_icon)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(openPending)
                .setOngoing(ongoing)
                .setOnlyAlertOnce(true)
                .setGroup(GROUP)
            if (ongoing && currentJobId != null) {
                val cancelPending = PendingIntent.getBroadcast(
                    context,
                    REQ_CANCEL,
                    Intent(ACTION_CANCEL)
                        .setPackage(context.packageName)
                        .putExtra(EXTRA_JOB_ID, currentJobId),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                builder.addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "Annuler",
                        cancelPending,
                    ).build(),
                )
            }
            if (ongoing) builder.setProgress(100, percent, indeterminate)
            else builder.setProgress(0, 0, false)
            mgr.notify(NOTIFICATION_ID, builder.build())
        } catch (e: Exception) {
            Log.w(TAG, "show: ${e.message}")
        }
    }

    companion object {
        const val CHANNEL = "video_compression"
        const val ACTION_CANCEL = "eu.devlabz.vox.video.CANCEL"
        const val EXTRA_JOB_ID = "job_id"
        private const val TAG = "VideoNotif"
        private const val NOTIFICATION_ID = 4711
        private const val GROUP = "video_compression"
        private const val REQ_OPEN = 4712
        private const val REQ_CANCEL = 4713
        private const val DISMISS_DELAY_MS = 4000L
    }
}
