package chat.fluffy.fluffychat.bastien_fork.wear.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import chat.fluffy.fluffychat.bastien_fork.wear.MainActivity
import chat.fluffy.fluffychat.bastien_fork.wear.R

/**
 * Foreground service permanent qui empêche Samsung Freecess (MARsmini_FreecessController)
 * de geler notre process — sans ça, le DataClient.OnDataChangedListener s'arrête de
 * recevoir les pushs phone dès que l'app n'est plus au foreground.
 *
 * Type `dataSync` (pas `microphone`) car ça tourne en permanence — la vague 2 ajoutera
 * un service `microphone` séparé juste pour l'enregistrement vocal.
 *
 * Ongoing Activity affichée discrètement (status court, icon launcher) pour rester
 * visible sur la watch face sans noyer l'utilisateur.
 */
class WearForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
        Log.d(TAG, "foreground service started")
        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "FluffyChat watch sync",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Maintient la liaison avec ton téléphone."
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("FluffyChat")
            .setContentText("Connecté")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(openIntent)

        val ongoing = OngoingActivity.Builder(applicationContext, NOTIF_ID, builder)
            .setStaticIcon(R.mipmap.ic_launcher)
            .setTouchIntent(openIntent)
            .setStatus(Status.Builder().addTemplate("FluffyChat").build())
            .build()
        ongoing.apply(applicationContext)

        return builder.build()
    }

    companion object {
        private const val TAG = "WearForegroundService"
        private const val CHANNEL_ID = "wear_sync_v1"
        private const val NOTIF_ID = 4242

        fun start(context: Context) {
            val intent = Intent(context, WearForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
