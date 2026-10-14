package chat.fluffy.fluffychat.sms

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * Envois SMS programmés et suppressions de SMS éphémères exécutés par
 * AlarmManager, donc même app tuée / téléphone en Doze (les Timer Dart ne
 * tournent que tant que le moteur Flutter vit).
 *
 * Les jobs sont persistés dans des SharedPreferences privées et ré-armés au
 * boot / après mise à jour. Le résultat des envois est conservé jusqu'à ce que
 * Dart le récupère ([takeResults]) pour mettre à jour sa file.
 */
object ScheduledSmsAlarms {
    const val ACTION_FIRE = "eu.devlabz.vox.SCHEDULED_SMS_FIRE"
    const val RESULT_SENT = "sent"
    const val RESULT_FAILED = "failed"
    const val MAX_ATTEMPTS = 3

    private const val EXTRA_JOB = "job"
    private const val PREFS = "vox_scheduled_sms"
    private const val KEY_JOBS = "jobs"
    private const val KEY_RESULTS = "results"
    private const val KEY_DONE = "done"
    private const val KEY_PENDING = "pending"
    private const val PENDING_TTL_MS = 24 * 60 * 60_000L
    private const val STALE_SENDING_MS = 2 * 60_000L
    private const val MAX_DONE = 200
    private const val RETRY_DELAY_MS = 60_000L
    private const val KIND_SEND = "send"
    private const val KIND_DELETE = "delete"

    private val lock = Any()

    private data class Job(
        val id: String,
        val kind: String,
        val at: Long,
        val address: String? = null,
        val body: String? = null,
        val messageId: Long = 0L,
        val isMms: Boolean = false,
        val attempts: Int = 0,
        /** > 0 : envoi en cours depuis ce timestamp (persisté avant la soumission). */
        val sendingSince: Long = 0L,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("id", id).put("kind", kind).put("at", at)
            .put("address", address).put("body", body)
            .put("messageId", messageId).put("isMms", isMms)
            .put("attempts", attempts).put("sendingSince", sendingSince)

        companion object {
            fun fromJson(o: JSONObject) = Job(
                id = o.getString("id"),
                kind = o.getString("kind"),
                at = o.getLong("at"),
                address = o.optString("address").takeIf { o.has("address") && !o.isNull("address") },
                body = o.optString("body").takeIf { o.has("body") && !o.isNull("body") },
                messageId = o.optLong("messageId"),
                isMms = o.optBoolean("isMms"),
                attempts = o.optInt("attempts"),
                sendingSince = o.optLong("sendingSince"),
            )
        }
    }

    private fun sendKey(id: String) = "$KIND_SEND:$id"
    private fun deleteKey(id: String) = "$KIND_DELETE:$id"

    /** Programme l'envoi. false si cet id a déjà été envoyé (anti-doublon). */
    fun scheduleSend(context: Context, id: String, address: String, body: String, at: Long): Boolean {
        val job = Job(sendKey(id), KIND_SEND, at, address = address, body = body)
        synchronized(lock) {
            if (readDone(context).contains(job.id)) return false
            writeJobs(context, readJobs(context).also { it[job.id] = job })
        }
        arm(context, job)
        return true
    }

    fun scheduleDelete(context: Context, id: String, messageId: Long, isMms: Boolean, at: Long): Boolean {
        if (messageId <= 0L) return false
        val job = Job(deleteKey(id), KIND_DELETE, at, messageId = messageId, isMms = isMms)
        synchronized(lock) { writeJobs(context, readJobs(context).also { it[job.id] = job }) }
        arm(context, job)
        return true
    }

    /** Annule un envoi. false s'il n'était plus en attente (déjà parti/en cours). */
    fun cancelSend(context: Context, id: String): Boolean = cancel(context, sendKey(id))

    fun cancelDelete(context: Context, id: String): Boolean = cancel(context, deleteKey(id))

    private fun cancel(context: Context, key: String): Boolean {
        val removed = synchronized(lock) {
            val jobs = readJobs(context)
            val r = jobs.remove(key) != null
            if (r) writeJobs(context, jobs)
            r
        }
        context.getSystemService(AlarmManager::class.java)?.cancel(pendingIntent(context, key))
        return removed
    }

    /** Résultats des envois (id Dart → sent|failed) depuis le dernier appel. */
    fun takeResults(context: Context): Map<String, String> = synchronized(lock) {
        val prefs = prefs(context)
        val obj = JSONObject(prefs.getString(KEY_RESULTS, null) ?: "{}")
        prefs.edit().remove(KEY_RESULTS).apply()
        obj.keys().asSequence().associateWith { obj.getString(it) }
    }

    /**
     * Ré-arme tous les jobs (boot, mise à jour, permission d'alarme exacte).
     * Un envoi resté « en cours » (processus tué pendant [fire]) a pu partir :
     * on le signale en échec à Dart plutôt que de risquer un doublon.
     */
    fun rearmAll(context: Context, processRestarted: Boolean) {
        val now = System.currentTimeMillis()
        val toArm = synchronized(lock) {
            val jobs = readJobs(context)
            var changed = false
            for (j in jobs.values.toList()) {
                val interrupted = j.sendingSince > 0L &&
                    (processRestarted || now - j.sendingSince > STALE_SENDING_MS)
                if (!interrupted) continue
                changed = true
                if (j.kind == KIND_SEND) {
                    jobs.remove(j.id)
                    recordResult(context, j.id.removePrefix("$KIND_SEND:"), RESULT_FAILED)
                } else {
                    jobs[j.id] = j.copy(sendingSince = 0L)
                }
            }
            if (changed) writeJobs(context, jobs)
            jobs.values.filter { it.sendingSince == 0L }
        }
        toArm.forEach { arm(context, it) }
        Log.i(SmsBridge.TAG, "ScheduledSmsAlarms: ${toArm.size} job(s) ré-armé(s)")
    }

    /**
     * Résultat SENT d'une part (via [SmsSentReceiver]). Un SMS programmé n'est
     * rapporté « sent » à Dart qu'une fois toutes ses parts acceptées par le modem.
     */
    fun onSmsSent(context: Context, rowId: Long, ok: Boolean) = synchronized(lock) {
        val pending = readPending(context)
        val e = pending.optJSONObject(rowId.toString())
            ?: JSONObject().put("ts", System.currentTimeMillis())
        if (ok) e.put("ok", e.optInt("ok") + 1) else e.put("failed", true)
        pending.put(rowId.toString(), e)
        settlePending(context, pending, rowId.toString())
    }

    private fun trackSubmitted(context: Context, rowId: Long, dartId: String, parts: Int) {
        val pending = readPending(context)
        val e = pending.optJSONObject(rowId.toString())
            ?: JSONObject().put("ts", System.currentTimeMillis())
        e.put("dart", dartId).put("parts", parts)
        pending.put(rowId.toString(), e)
        settlePending(context, pending, rowId.toString())
    }

    private fun settlePending(context: Context, pending: JSONObject, key: String) {
        val e = pending.getJSONObject(key)
        val dartId = e.optString("dart").takeIf { e.has("dart") }
        if (dartId != null) {
            when {
                e.optBoolean("failed") -> {
                    recordResult(context, dartId, RESULT_FAILED)
                    // Permettre une reprogrammation manuelle du même message.
                    writeDone(context, readDone(context).also { it.remove(sendKey(dartId)) })
                    pending.remove(key)
                }
                e.optInt("ok") >= e.optInt("parts", 1) -> {
                    recordResult(context, dartId, RESULT_SENT)
                    pending.remove(key)
                }
            }
        }
        // Les SMS non programmés passent aussi ici : purger les entrées orphelines.
        val now = System.currentTimeMillis()
        pending.keys().asSequence().toList().forEach { k ->
            if (now - (pending.optJSONObject(k)?.optLong("ts") ?: 0L) > PENDING_TTL_MS) pending.remove(k)
        }
        prefs(context).edit().putString(KEY_PENDING, pending.toString()).commit()
    }

    private fun readPending(context: Context) =
        JSONObject(prefs(context).getString(KEY_PENDING, null) ?: "{}")

    internal suspend fun fire(context: Context, key: String) {
        // Marquage « en cours » persisté sous verrou AVANT l'envoi : deux
        // déclenchements concurrents ne peuvent pas envoyer deux fois, et un envoi
        // interrompu par la mort du processus reste visible pour [rearmAll].
        val job = synchronized(lock) {
            val jobs = readJobs(context)
            val j = jobs[key] ?: return
            if (j.sendingSince > 0L) return
            val claimed = j.copy(sendingSince = System.currentTimeMillis())
            jobs[key] = claimed
            writeJobs(context, jobs)
            claimed
        }
        when (job.kind) {
            KIND_DELETE -> {
                SmsBridge.deleteMessage(context, job.messageId, job.isMms)
                synchronized(lock) { writeJobs(context, readJobs(context).also { it.remove(key) }) }
            }
            KIND_SEND -> {
                val address = job.address
                val body = job.body
                val rowId = if (address != null && body != null) {
                    SmsBridge.sendSms(context, address, body)
                } else {
                    null
                }
                val dartId = key.removePrefix("$KIND_SEND:")
                when {
                    rowId != null -> synchronized(lock) {
                        writeJobs(context, readJobs(context).also { it.remove(key) })
                        writeDone(context, readDone(context).also { it.add(key) })
                        if (rowId > 0L) {
                            trackSubmitted(context, rowId, dartId, SmsBridge.partCount(context, body!!))
                        } else {
                            // Non persisté → pas de callback SENT exploitable.
                            recordResult(context, dartId, RESULT_SENT)
                        }
                    }
                    job.attempts + 1 < MAX_ATTEMPTS -> {
                        val retry = job.copy(
                            attempts = job.attempts + 1,
                            at = System.currentTimeMillis() + RETRY_DELAY_MS,
                            sendingSince = 0L,
                        )
                        synchronized(lock) {
                            writeJobs(context, readJobs(context).also { it[key] = retry })
                        }
                        arm(context, retry)
                    }
                    else -> synchronized(lock) {
                        writeJobs(context, readJobs(context).also { it.remove(key) })
                        recordResult(context, dartId, RESULT_FAILED)
                    }
                }
            }
        }
    }

    private fun arm(context: Context, job: Job) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val pi = pendingIntent(context, job.id)
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        try {
            if (exact) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, job.at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, job.at, pi)
            }
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, job.at, pi)
        }
    }

    private fun pendingIntent(context: Context, key: String): PendingIntent {
        val intent = Intent(context, ScheduledSmsReceiver::class.java).apply {
            action = ACTION_FIRE
            // data unique par job : les extras ne comptent pas dans filterEquals.
            data = Uri.Builder().scheme("vox-sched").opaquePart(key).build()
            putExtra(EXTRA_JOB, key)
        }
        return PendingIntent.getBroadcast(
            context, key.hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    internal fun jobKey(intent: Intent): String? = intent.getStringExtra(EXTRA_JOB)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readJobs(context: Context): MutableMap<String, Job> {
        val arr = JSONArray(prefs(context).getString(KEY_JOBS, null) ?: "[]")
        val out = LinkedHashMap<String, Job>()
        for (i in 0 until arr.length()) {
            runCatching { Job.fromJson(arr.getJSONObject(i)) }.getOrNull()?.let { out[it.id] = it }
        }
        return out
    }

    private fun writeJobs(context: Context, jobs: Map<String, Job>) {
        val arr = JSONArray()
        jobs.values.forEach { arr.put(it.toJson()) }
        prefs(context).edit().putString(KEY_JOBS, arr.toString()).commit()
    }

    private fun readDone(context: Context): MutableList<String> {
        val arr = JSONArray(prefs(context).getString(KEY_DONE, null) ?: "[]")
        return MutableList(arr.length()) { arr.getString(it) }
    }

    private fun writeDone(context: Context, done: List<String>) {
        prefs(context).edit()
            .putString(KEY_DONE, JSONArray(done.takeLast(MAX_DONE)).toString())
            .apply()
    }

    private fun recordResult(context: Context, dartId: String, result: String) {
        val prefs = prefs(context)
        val obj = JSONObject(prefs.getString(KEY_RESULTS, null) ?: "{}")
        obj.put(dartId, result)
        prefs.edit().putString(KEY_RESULTS, obj.toString()).apply()
    }
}

/** Déclenché par AlarmManager (PendingIntent explicite, non exporté). */
class ScheduledSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ScheduledSmsAlarms.ACTION_FIRE) return
        val key = ScheduledSmsAlarms.jobKey(intent) ?: return
        val app = context.applicationContext
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                ScheduledSmsAlarms.fire(app, key)
            } catch (e: Exception) {
                Log.e(SmsBridge.TAG, "ScheduledSmsReceiver: ${e.message}")
            } finally {
                pending.finish()
            }
        }
    }
}

/** Les alarmes ne survivent pas au reboot ni à une mise à jour de l'app. */
class ScheduledSmsBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> ScheduledSmsAlarms.rearmAll(
                context.applicationContext,
                processRestarted = intent.action != AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            )
        }
    }
}
