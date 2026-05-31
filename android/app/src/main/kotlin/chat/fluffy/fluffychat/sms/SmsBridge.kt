package chat.fluffy.fluffychat.sms

import android.app.PendingIntent
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Couche native SMS de VOX — Étape 1.
 *
 * Singleton sans état métier (le provider Telephony EST l'état). Expose :
 *  - lecture des conversations / messages depuis le content provider Telephony,
 *  - envoi d'un SMS (multipart) via [SmsManager] avec PendingIntents SENT/DELIVERED,
 *  - marquage d'un thread comme lu,
 *  - un callback [onSmsReceived] que [SmsDeliverReceiver] déclenche à chaque SMS entrant,
 *    relayé vers Dart par [SmsBridgePlugin].
 *
 * Toutes les I/O ContentResolver tournent sur [Dispatchers.IO]. Les curseurs sont
 * systématiquement fermés via `use {}`.
 *
 * Compatible GrapheneOS : aucune dépendance Play Services. Tout est dans
 * android.telephony / android.provider.Telephony (API standard).
 */
object SmsBridge {

    const val TAG = "SmsBridge"

    /**
     * Callback poussé à chaque SMS entrant (après écriture dans l'inbox du provider).
     * Branché par [SmsBridgePlugin] vers le MethodChannel Dart. Null si Flutter pas attaché.
     *
     * Map : { address, body, date (epoch ms), threadId }
     */
    @Volatile
    var onSmsReceived: ((Map<String, Any?>) -> Unit)? = null

    // ── Actions PendingIntent SENT / DELIVERED ────────────────────────────────
    const val ACTION_SMS_SENT = "eu.devlabz.vox.SMS_SENT"
    const val ACTION_SMS_DELIVERED = "eu.devlabz.vox.SMS_DELIVERED"
    const val EXTRA_ROW_ID = "row_id"

    // ── Redaction des numéros pour les logs (garde 4 derniers chiffres) ───────
    fun redact(address: String?): String {
        if (address.isNullOrEmpty()) return "<empty>"
        if (address.length <= 4) return "***"
        return "***" + address.takeLast(4)
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Lecture : conversations
    // ──────────────────────────────────────────────────────────────────────────

    private const val CONV_SCAN_LIMIT = 200

    /**
     * Liste les threads SMS, le plus récent en premier.
     *
     * On scanne content://sms (DATE DESC) et on garde la première ligne rencontrée
     * par threadId (= la plus récente). Les ROMs OEM ignorent parfois LIMIT dans le
     * sortOrder, donc on coupe manuellement à [CONV_SCAN_LIMIT] threads distincts.
     *
     * @return liste de maps { threadId, address, displayName, snippet, date, unreadCount }
     */
    suspend fun listConversations(context: Context): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            val byThread = LinkedHashMap<Long, MutableMap<String, Any?>>()
            // unreadCount agrégé par thread (compté sur tout le scan, pas juste la 1re ligne)
            val unreadByThread = HashMap<Long, Int>()

            try {
                context.contentResolver.query(
                    Telephony.Sms.CONTENT_URI,
                    arrayOf(
                        Telephony.Sms.THREAD_ID,
                        Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY,
                        Telephony.Sms.DATE,
                        Telephony.Sms.READ,
                        Telephony.Sms.TYPE,
                    ),
                    null,
                    null,
                    "${Telephony.Sms.DATE} DESC LIMIT ${CONV_SCAN_LIMIT * 8}",
                )?.use { c ->
                    val idxThread = c.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
                    val idxAddr = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                    val idxBody = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
                    val idxDate = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
                    val idxRead = c.getColumnIndexOrThrow(Telephony.Sms.READ)
                    val idxType = c.getColumnIndexOrThrow(Telephony.Sms.TYPE)
                    while (c.moveToNext()) {
                        val threadId = c.getLong(idxThread)
                        val read = c.getInt(idxRead)
                        val type = c.getInt(idxType)
                        if (read == 0 && type == Telephony.Sms.MESSAGE_TYPE_INBOX) {
                            unreadByThread[threadId] = (unreadByThread[threadId] ?: 0) + 1
                        }
                        if (byThread.containsKey(threadId)) continue
                        if (byThread.size >= CONV_SCAN_LIMIT) continue
                        val address = c.getString(idxAddr) ?: ""
                        byThread[threadId] = mutableMapOf(
                            "threadId" to threadId,
                            "address" to address,
                            "displayName" to null,
                            "snippet" to (c.getString(idxBody) ?: ""),
                            "date" to c.getLong(idxDate),
                            "unreadCount" to 0,
                        )
                    }
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "listConversations: READ_SMS denied: ${e.message}")
                return@withContext emptyList()
            } catch (e: Exception) {
                Log.e(TAG, "listConversations failed: ${e.message}")
                return@withContext emptyList()
            }

            // Patch unreadCount + résolution displayName (best-effort, READ_CONTACTS optionnel)
            for ((threadId, conv) in byThread) {
                conv["unreadCount"] = unreadByThread[threadId] ?: 0
                val address = conv["address"] as? String
                if (!address.isNullOrBlank()) {
                    conv["displayName"] = resolveContactName(context, address)
                }
            }

            byThread.values
                .sortedByDescending { (it["date"] as? Long) ?: 0L }
                .toList()
        }

    // ──────────────────────────────────────────────────────────────────────────
    // Lecture : messages d'un thread
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Liste les messages SMS d'un thread, du plus ancien au plus récent.
     *
     * @return liste de maps { id, address, body, date, isFromMe, type, status, read }
     */
    suspend fun listMessages(context: Context, threadId: Long): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext emptyList()
            val out = ArrayList<Map<String, Any?>>()
            try {
                context.contentResolver.query(
                    Telephony.Sms.CONTENT_URI,
                    arrayOf(
                        Telephony.Sms._ID,
                        Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY,
                        Telephony.Sms.DATE,
                        Telephony.Sms.TYPE,
                        Telephony.Sms.STATUS,
                        Telephony.Sms.READ,
                    ),
                    "${Telephony.Sms.THREAD_ID}=?",
                    arrayOf(threadId.toString()),
                    "${Telephony.Sms.DATE} ASC",
                )?.use { c ->
                    val idxId = c.getColumnIndexOrThrow(Telephony.Sms._ID)
                    val idxAddr = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                    val idxBody = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
                    val idxDate = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
                    val idxType = c.getColumnIndexOrThrow(Telephony.Sms.TYPE)
                    val idxStatus = c.getColumnIndexOrThrow(Telephony.Sms.STATUS)
                    val idxRead = c.getColumnIndexOrThrow(Telephony.Sms.READ)
                    while (c.moveToNext()) {
                        val type = c.getInt(idxType)
                        out += mapOf(
                            "id" to c.getLong(idxId),
                            "address" to (c.getString(idxAddr) ?: ""),
                            "body" to (c.getString(idxBody) ?: ""),
                            "date" to c.getLong(idxDate),
                            "isFromMe" to (type != Telephony.Sms.MESSAGE_TYPE_INBOX),
                            "type" to type,
                            "status" to c.getInt(idxStatus),
                            "read" to (c.getInt(idxRead) == 1),
                        )
                    }
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "listMessages($threadId): READ_SMS denied: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "listMessages($threadId) failed: ${e.message}")
            }
            out
        }

    // ──────────────────────────────────────────────────────────────────────────
    // Envoi
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Envoie un SMS à [address]. Découpe automatiquement en parts (multipart) si long.
     *
     * Insère d'abord la ligne dans content://sms (boîte d'envoi) — obligatoire quand on
     * est l'app par défaut, car personne d'autre ne le fera — puis envoie via SmsManager
     * avec un PendingIntent SENT par part et DELIVERED par part. Le rowId est porté dans
     * l'extra de chaque intent pour que [SmsSentReceiver] puisse mettre à jour le statut.
     *
     * @return le rowId inséré (> 0) en cas de succès, ou null en cas d'échec.
     */
    suspend fun sendSms(context: Context, address: String, body: String): Long? =
        withContext(Dispatchers.IO) {
            try {
                val sms = obtainSmsManager(context)
                val parts = sms.divideMessage(body)

                // 1. Persister dans le provider (boîte d'envoi). C'est notre responsabilité
                //    en tant qu'app par défaut. La ligne passe ensuite SENT/FAILED via le receiver.
                val rowId = insertOutbox(context, address, body)

                // 2. PendingIntents par part. requestCode unique par (rowId, index) pour
                //    éviter l'écrasement de PendingIntents distincts.
                val sentIntents = ArrayList<PendingIntent>(parts.size)
                val deliveredIntents = ArrayList<PendingIntent>(parts.size)
                for (i in parts.indices) {
                    sentIntents += buildPendingIntent(context, ACTION_SMS_SENT, rowId, i, 0)
                    deliveredIntents += buildPendingIntent(context, ACTION_SMS_DELIVERED, rowId, i, 0x40000)
                }

                sms.sendMultipartTextMessage(address, null, parts, sentIntents, deliveredIntents)
                Log.i(TAG, "sendSms → ${redact(address)} (${parts.size} part(s), row=$rowId)")
                rowId.takeIf { it > 0 }
            } catch (e: SecurityException) {
                Log.e(TAG, "sendSms → ${redact(address)}: SEND_SMS denied: ${e.message}")
                null
            } catch (e: Exception) {
                Log.e(TAG, "sendSms → ${redact(address)} failed: ${e.message}")
                null
            }
        }

    private fun insertOutbox(context: Context, address: String, body: String): Long {
        return try {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, address)
                put(Telephony.Sms.BODY, body)
                put(Telephony.Sms.DATE, System.currentTimeMillis())
                put(Telephony.Sms.READ, 1)
                put(Telephony.Sms.SEEN, 1)
                put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_OUTBOX)
            }
            val uri: Uri? = context.contentResolver.insert(Telephony.Sms.CONTENT_URI, values)
            uri?.lastPathSegment?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            Log.e(TAG, "insertOutbox failed: ${e.message}")
            0L
        }
    }

    private fun buildPendingIntent(
        context: Context,
        action: String,
        rowId: Long,
        partIndex: Int,
        requestCodeOffset: Int,
    ): PendingIntent {
        val intent = Intent(action).apply {
            setPackage(context.packageName)
            putExtra(EXTRA_ROW_ID, rowId)
        }
        val requestCode = (rowId.toInt() shl 4) + partIndex + requestCodeOffset
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /**
     * SmsManager via le bon chemin selon l'API :
     *  - API 31+ : getSystemService(SmsManager) (getDefault déprécié).
     *  - < 31    : SmsManager.getDefault().
     */
    @Suppress("DEPRECATION")
    private fun obtainSmsManager(context: Context): SmsManager =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            SmsManager.getDefault()
        }

    // ──────────────────────────────────────────────────────────────────────────
    // Marquer un thread comme lu
    // ──────────────────────────────────────────────────────────────────────────

    /** Passe READ=1 et SEEN=1 sur tous les SMS non lus du thread. @return nb de lignes mises à jour. */
    suspend fun markRead(context: Context, threadId: Long): Int =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext 0
            try {
                val values = ContentValues().apply {
                    put(Telephony.Sms.READ, 1)
                    put(Telephony.Sms.SEEN, 1)
                }
                context.contentResolver.update(
                    Telephony.Sms.CONTENT_URI,
                    values,
                    "${Telephony.Sms.THREAD_ID}=? AND ${Telephony.Sms.READ}=0",
                    arrayOf(threadId.toString()),
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "markRead($threadId): write denied (default app?): ${e.message}")
                0
            } catch (e: Exception) {
                Log.e(TAG, "markRead($threadId) failed: ${e.message}")
                0
            }
        }

    // ──────────────────────────────────────────────────────────────────────────
    // Helpers internes (utilisés aussi par SmsDeliverReceiver)
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Insère un SMS entrant dans l'inbox du provider. Appelé par [SmsDeliverReceiver]
     * (obligatoire quand on est app par défaut : l'OS ne l'écrit plus pour nous).
     *
     * @return l'Uri de la ligne insérée, ou null.
     */
    fun insertInbox(context: Context, sender: String, body: String, timestamp: Long): Uri? {
        return try {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, sender)
                put(Telephony.Sms.BODY, body)
                put(Telephony.Sms.DATE, timestamp)
                put(Telephony.Sms.DATE_SENT, timestamp)
                put(Telephony.Sms.READ, 0)
                put(Telephony.Sms.SEEN, 0)
                put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
            }
            context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values)
        } catch (e: SecurityException) {
            Log.e(TAG, "insertInbox: write denied (default app role missing?): ${e.message}")
            null
        } catch (e: Exception) {
            Log.e(TAG, "insertInbox failed: ${e.message}")
            null
        }
    }

    /** Récupère le threadId d'une ligne SMS insérée (pour enrichir le callback Dart). */
    fun threadIdForSms(context: Context, smsUri: Uri): Long {
        return try {
            context.contentResolver.query(
                smsUri,
                arrayOf(Telephony.Sms.THREAD_ID),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getLong(0) else 0L
            } ?: 0L
        } catch (e: Exception) {
            Log.w(TAG, "threadIdForSms failed: ${e.message}")
            0L
        }
    }

    /**
     * Résout le nom de contact pour un numéro. Best-effort : si READ_CONTACTS n'est pas
     * accordé (ou indisponible sur GrapheneOS profil sans contacts), renvoie null sans planter.
     */
    private fun resolveContactName(context: Context, address: String): String? {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(address),
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.takeIf { it.isNotBlank() } else null
            }
        } catch (e: SecurityException) {
            null // READ_CONTACTS non accordé — non bloquant
        } catch (e: Exception) {
            Log.w(TAG, "resolveContactName failed: ${e.message}")
            null
        }
    }
}
