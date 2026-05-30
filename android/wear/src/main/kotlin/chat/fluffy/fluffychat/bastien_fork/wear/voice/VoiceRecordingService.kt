package chat.fluffy.fluffychat.bastien_fork.wear.voice

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
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import chat.fluffy.fluffychat.bastien_fork.wear.MainActivity
import chat.fluffy.fluffychat.bastien_fork.wear.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * Foreground service type=microphone qui orchestre l'enregistrement vocal :
 *  - Tient l'app vivante pendant l'enregistrement (anti-Freecess Samsung)
 *  - Wake lock pour éviter écran off pendant record
 *  - Ongoing Activity avec timer "REC mm:ss" + animated dot
 *  - Expose un StateFlow [recordingState] que l'UI Compose collecte
 *
 * Cycle de vie :
 *  - start(roomId) → enregistre, notif visible
 *  - stop() → finalise le fichier, expose RecordingState.Done(file, ms)
 *  - cancel() → supprime fichier, RecordingState.Idle
 */
class VoiceRecordingService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var recorder: VoiceRecorder? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var timerJob: Job? = null
    private var currentRoomId: String? = null

    // rc-wear-notif-headless-upload — quand l'enregistrement est lancé depuis une
    // notification (action "Vocal"), aucune UI n'observe RecordingState.Done pour
    // déclencher l'upload. Dans ce mode, le service upload lui-même au stop. Le flag
    // est aussi porté dans RecordingState.Done pour que RoomDetailScreen n'uploade
    // PAS une seconde fois quand l'app est ouverte (anti double-envoi).
    private var autoUpload: Boolean = false

    // rc-wear-bootstrap-double-start-race — onStartCommand peut être ré-entré
    // (double-tap UI). Le check recorder?.isRecording() n'est pas atomique : deux
    // handleStart() concurrents créaient deux VoiceRecorder sur le même MIC. Ce
    // flag, posé AVANT toute init, ferme la fenêtre.
    @Volatile
    private var isStarting: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val roomId = intent.getStringExtra(EXTRA_ROOM_ID) ?: return START_NOT_STICKY
                val auto = intent.getBooleanExtra(EXTRA_AUTO_UPLOAD, false)
                handleStart(roomId, auto)
            }
            ACTION_STOP -> handleStop()
            ACTION_CANCEL -> handleCancel()
        }
        return START_NOT_STICKY
    }

    @Synchronized
    private fun handleStart(roomId: String, auto: Boolean) {
        if (isStarting || recorder?.isRecording() == true) {
            Log.w(TAG, "already recording/starting, ignore start")
            return
        }
        isStarting = true
        autoUpload = auto
        ensureChannel()
        startForegroundWithNotif(roomId, 0)

        // Wake lock pour éviter écran off / CPU sleep pendant record. On release
        // d'abord un éventuel lock résiduel pour ne pas en fuiter un.
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "FluffyChatWear:VoiceRec"
        ).apply { acquire(VoiceRecorder.MAX_DURATION_MS.toLong() + 5_000) }

        try {
            val rec = VoiceRecorder(this)
            rec.start()
            recorder = rec
            currentRoomId = roomId
            _recordingState.value = RecordingState.Recording(roomId, 0)
            startTimerLoop()
        } catch (t: Throwable) {
            Log.w(TAG, "start failed", t)
            cleanup()
            _recordingState.value = RecordingState.Error(t.message ?: "start failed")
            stopForegroundCompat()
            stopSelf()
        } finally {
            isStarting = false
        }
    }

    private fun handleStop() {
        val rec = recorder ?: return
        timerJob?.cancel()
        timerJob = null
        val result = rec.stop()
        val roomId = currentRoomId ?: ""
        val wasAuto = autoUpload
        cleanup()
        if (result != null) {
            // Mode headless (déclenché depuis une notif) : aucune UI n'observe
            // RecordingState.Done, on lance l'upload nous-mêmes. En mode UI
            // (wasAuto=false), c'est RoomDetailScreen qui upload sur Done — le flag
            // autoUpload dans l'état lui sert à NE PAS doubler l'envoi.
            if (wasAuto && roomId.isNotBlank()) {
                runCatching {
                    VoiceUploader.upload(applicationContext, roomId, result.file, result.durationMs)
                }.onFailure { Log.w(TAG, "headless upload dispatch failed", it) }
            } else if (wasAuto) {
                Log.w(TAG, "headless stop with blank roomId, dropping audio")
                result.file.delete()
            }
            _recordingState.value = RecordingState.Done(
                roomId = roomId,
                file = result.file,
                durationMs = result.durationMs,
                autoUpload = wasAuto
            )
        } else {
            _recordingState.value = RecordingState.Error("stop returned null")
        }
        stopForegroundCompat()
        stopSelf()
    }

    private fun handleCancel() {
        timerJob?.cancel()
        timerJob = null
        recorder?.cancel()
        cleanup()
        _recordingState.value = RecordingState.Idle
        stopForegroundCompat()
        stopSelf()
    }

    private fun cleanup() {
        recorder = null
        autoUpload = false
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun startTimerLoop() {
        timerJob = scope.launch {
            while (true) {
                delay(500)
                val rec = recorder ?: break
                if (!rec.isRecording()) break
                val ms = rec.currentDurationMs()
                _recordingState.value = RecordingState.Recording(currentRoomId ?: "", ms)
                updateNotifTimer(ms)
                if (ms >= VoiceRecorder.MAX_DURATION_MS) {
                    handleStop()
                    break
                }
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "FluffyChat voice recording",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Enregistrement vocal en cours"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }

    private fun startForegroundWithNotif(roomId: String, ms: Int) {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = buildNotifBuilder(openIntent, ms)
        val ongoing = OngoingActivity.Builder(applicationContext, NOTIF_ID, builder)
            .setStaticIcon(R.mipmap.ic_launcher)
            .setTouchIntent(openIntent)
            .setStatus(Status.Builder().addTemplate(formatTimer(ms)).build())
            .build()
        ongoing.apply(applicationContext)

        val notif = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun updateNotifTimer(ms: Int) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        nm.notify(NOTIF_ID, buildNotifBuilder(openIntent, ms).build())
    }

    private fun buildNotifBuilder(openIntent: PendingIntent, ms: Int): NotificationCompat.Builder {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("● Enregistrement")
            .setContentText(formatTimer(ms))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(openIntent)
            .setShowWhen(false)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun formatTimer(ms: Int): String {
        val totalSec = ms / 1000
        val m = totalSec / 60
        val s = totalSec % 60
        return "%d:%02d".format(m, s)
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        cleanup()
    }

    companion object {
        private const val TAG = "VoiceRecordingService"
        private const val CHANNEL_ID = "wear_voice_rec_v1"
        private const val NOTIF_ID = 4243

        private const val ACTION_START = "chat.fluffy.fluffychat.bastien_fork.wear.voice.START"
        private const val ACTION_STOP = "chat.fluffy.fluffychat.bastien_fork.wear.voice.STOP"
        private const val ACTION_CANCEL = "chat.fluffy.fluffychat.bastien_fork.wear.voice.CANCEL"
        private const val EXTRA_ROOM_ID = "roomId"
        private const val EXTRA_AUTO_UPLOAD = "autoUpload"

        private val _recordingState = MutableStateFlow<RecordingState>(RecordingState.Idle)
        val recordingState: StateFlow<RecordingState> = _recordingState.asStateFlow()

        /**
         * @param autoUpload true quand l'enregistrement est lancé sans UI ouverte
         *   (action de notification) : le service déclenche lui-même l'upload au stop.
         *   false en mode UI : RoomDetailScreen observe RecordingState.Done et upload.
         */
        fun start(context: Context, roomId: String, autoUpload: Boolean = false) {
            val intent = Intent(context, VoiceRecordingService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ROOM_ID, roomId)
                putExtra(EXTRA_AUTO_UPLOAD, autoUpload)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, VoiceRecordingService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun cancel(context: Context) {
            val intent = Intent(context, VoiceRecordingService::class.java).apply {
                action = ACTION_CANCEL
            }
            context.startService(intent)
        }

        fun resetState() {
            _recordingState.value = RecordingState.Idle
        }
    }
}

sealed class RecordingState {
    data object Idle : RecordingState()
    data class Recording(val roomId: String, val elapsedMs: Int) : RecordingState()
    data class Done(
        val roomId: String,
        val file: File,
        val durationMs: Int,
        val autoUpload: Boolean = false
    ) : RecordingState()
    data class Error(val message: String) : RecordingState()
}
