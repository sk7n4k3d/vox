package chat.fluffy.fluffychat.sms

import android.app.PendingIntent
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.UUID

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

    /**
     * Callback poussé à la réception d'un MMS entrant (WAP_PUSH_DELIVER).
     * Best-effort : le download/parse réel du PDU est fait par la stack Android quand on
     * détient ROLE_SMS, et atterrit dans content://mms de façon asynchrone. Ce callback sert
     * juste à signaler à Dart « un MMS arrive, refresh la liste bientôt ».
     *
     * Map : { mimeType (du WAP push), date (epoch ms) }
     */
    @Volatile
    var onMmsReceived: ((Map<String, Any?>) -> Unit)? = null

    // ── Actions PendingIntent SENT / DELIVERED ────────────────────────────────
    const val ACTION_SMS_SENT = "eu.devlabz.vox.SMS_SENT"
    const val ACTION_SMS_DELIVERED = "eu.devlabz.vox.SMS_DELIVERED"
    const val ACTION_MMS_SENT = "eu.devlabz.vox.MMS_SENT"
    const val EXTRA_ROW_ID = "row_id"
    const val EXTRA_MMS_ID = "mms_id"
    const val EXTRA_TXN_ID = "txn_id"

    // Plafonds compression image MMS sortant (≈ contraintes carrier).
    private const val MAX_IMAGE_BYTES = 1_000_000
    private const val MAX_IMAGE_W = 1920
    private const val MAX_IMAGE_H = 1080

    // content://mms/part — URI des parts MMS (text/images). Pas d'API publique typée fiable < API 29.
    private val MMS_PART_URI: Uri = Uri.parse("content://mms/part")

    // Types d'adresse MMS (PduHeaders) : FROM=137, TO=151.
    private const val MMS_ADDR_TYPE_FROM = 137
    private const val MMS_ADDR_TYPE_TO = 151

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

            // ── Passe MMS : fusionne les threads qui ont des MMS (y compris MMS-only). ──
            // content://mms expose DATE en SECONDES (pas en ms comme SMS). On normalise en ms.
            try {
                context.contentResolver.query(
                    Telephony.Mms.CONTENT_URI,
                    arrayOf(
                        Telephony.Mms._ID,
                        Telephony.Mms.THREAD_ID,
                        Telephony.Mms.DATE,
                        Telephony.Mms.READ,
                        Telephony.Mms.MESSAGE_BOX,
                        Telephony.Mms.SUBJECT,
                    ),
                    null,
                    null,
                    "${Telephony.Mms.DATE} DESC LIMIT ${CONV_SCAN_LIMIT * 8}",
                )?.use { c ->
                    val idxId = c.getColumnIndexOrThrow(Telephony.Mms._ID)
                    val idxThread = c.getColumnIndexOrThrow(Telephony.Mms.THREAD_ID)
                    val idxDate = c.getColumnIndexOrThrow(Telephony.Mms.DATE)
                    val idxRead = c.getColumnIndexOrThrow(Telephony.Mms.READ)
                    val idxBox = c.getColumnIndexOrThrow(Telephony.Mms.MESSAGE_BOX)
                    val idxSubject = c.getColumnIndexOrThrow(Telephony.Mms.SUBJECT)
                    while (c.moveToNext()) {
                        val threadId = c.getLong(idxThread)
                        val mmsId = c.getLong(idxId)
                        val dateMs = c.getLong(idxDate) * 1000L
                        val read = c.getInt(idxRead)
                        val box = c.getInt(idxBox)
                        if (read == 0 && box == Telephony.Mms.MESSAGE_BOX_INBOX) {
                            unreadByThread[threadId] = (unreadByThread[threadId] ?: 0) + 1
                        }
                        val existing = byThread[threadId]
                        if (existing != null) {
                            // Ce MMS est-il plus récent que le snippet courant ? Si oui, il devient le snippet.
                            if (dateMs > ((existing["date"] as? Long) ?: 0L)) {
                                existing["date"] = dateMs
                                existing["snippet"] = mmsSnippet(context, mmsId, c.getString(idxSubject))
                            }
                        } else {
                            if (byThread.size >= CONV_SCAN_LIMIT) continue
                            val address = mmsSenderAddress(context, mmsId) ?: ""
                            byThread[threadId] = mutableMapOf(
                                "threadId" to threadId,
                                "address" to address,
                                "displayName" to null,
                                "snippet" to mmsSnippet(context, mmsId, c.getString(idxSubject)),
                                "date" to dateMs,
                                "unreadCount" to 0,
                            )
                        }
                    }
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "listConversations(mms): READ_SMS denied: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "listConversations(mms) failed: ${e.message}")
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

    /** Snippet d'un MMS pour la liste : sujet si présent, sinon 1re part text/plain, sinon "[MMS]". */
    private fun mmsSnippet(context: Context, mmsId: Long, subject: String?): String {
        val subj = subject?.takeUnless { it.isBlank() || it == "NoSubject" }
        if (subj != null) return subj
        val text = mmsFirstText(context, mmsId)
        return text?.takeIf { it.isNotBlank() } ?: "[MMS]"
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Lecture : messages d'un thread
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Liste les messages d'un thread (SMS **et** MMS fusionnés), du plus ancien au plus récent.
     *
     * Format SMS (inchangé, rétro-compatible Étape 1) :
     *   { id, address, body, date, isFromMe, type, status, read, isMms=false, attachments=[] }
     * Format MMS (additif) :
     *   { id, address, body, date, isFromMe, type, status, read, isMms=true,
     *     attachments=[ { partId, mimeType, fileName }, … ] }
     *
     * Le champ `id` reste l'`_ID` de la ligne dans sa table respective. `isMms` permet à Dart
     * de distinguer la table d'origine ; `attachments` est toujours présent (vide pour les SMS).
     */
    suspend fun listMessages(context: Context, threadId: Long): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext emptyList()
            val out = ArrayList<Map<String, Any?>>()

            // ── SMS ──
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
                            "isMms" to false,
                            "attachments" to emptyList<Map<String, Any?>>(),
                        )
                    }
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "listMessages($threadId): READ_SMS denied: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "listMessages($threadId) failed: ${e.message}")
            }

            // ── MMS ──
            out += listMms(context, threadId)

            // Fusion triée par date ASC (les SMS sont en ms, on a normalisé les MMS en ms aussi).
            out.sortedBy { (it["date"] as? Long) ?: 0L }
        }

    /**
     * Lit les MMS d'un thread + leurs parts. DATE du provider MMS est en SECONDES → normalisée ms.
     * Pour chaque MMS : `body` = concat des parts text/plain ; `attachments` = parts non-texte/non-smil.
     */
    private fun listMms(context: Context, threadId: Long): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        try {
            context.contentResolver.query(
                Telephony.Mms.CONTENT_URI,
                arrayOf(
                    Telephony.Mms._ID,
                    Telephony.Mms.DATE,
                    Telephony.Mms.MESSAGE_BOX,
                    Telephony.Mms.READ,
                    Telephony.Mms.SUBJECT,
                    Telephony.Mms.MESSAGE_TYPE,
                ),
                "${Telephony.Mms.THREAD_ID}=?",
                arrayOf(threadId.toString()),
                "${Telephony.Mms.DATE} ASC",
            )?.use { c ->
                val idxId = c.getColumnIndexOrThrow(Telephony.Mms._ID)
                val idxDate = c.getColumnIndexOrThrow(Telephony.Mms.DATE)
                val idxBox = c.getColumnIndexOrThrow(Telephony.Mms.MESSAGE_BOX)
                val idxRead = c.getColumnIndexOrThrow(Telephony.Mms.READ)
                val idxSubject = c.getColumnIndexOrThrow(Telephony.Mms.SUBJECT)
                while (c.moveToNext()) {
                    val mmsId = c.getLong(idxId)
                    val box = c.getInt(idxBox)
                    val isFromMe = box == Telephony.Mms.MESSAGE_BOX_SENT ||
                        box == Telephony.Mms.MESSAGE_BOX_OUTBOX
                    val (text, attachments) = mmsParts(context, mmsId)
                    val subject = c.getString(idxSubject)?.takeUnless { it.isBlank() || it == "NoSubject" }
                    val body = listOfNotNull(subject, text.takeIf { it.isNotBlank() }).joinToString("\n")
                    val address = if (isFromMe) "" else (mmsSenderAddress(context, mmsId) ?: "")
                    out += mapOf(
                        "id" to mmsId,
                        "address" to address,
                        "body" to body,
                        "date" to c.getLong(idxDate) * 1000L,
                        "isFromMe" to isFromMe,
                        // Mappe la box MMS vers une sémantique type proche des SMS pour Dart.
                        "type" to if (isFromMe) Telephony.Sms.MESSAGE_TYPE_SENT
                                  else Telephony.Sms.MESSAGE_TYPE_INBOX,
                        "status" to 0,
                        "read" to (c.getInt(idxRead) == 1),
                        "isMms" to true,
                        "attachments" to attachments,
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "listMms($threadId): READ_SMS denied: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "listMms($threadId) failed: ${e.message}")
        }
        return out
    }

    /**
     * Lit toutes les parts d'un MMS.
     * @return Pair(texte concaténé des parts text/plain, liste d'attachments {partId,mimeType,fileName}).
     * Les parts application/smil et text/plain ne sont PAS exposées comme attachments.
     */
    private fun mmsParts(context: Context, mmsId: Long): Pair<String, List<Map<String, Any?>>> {
        val text = StringBuilder()
        val attachments = ArrayList<Map<String, Any?>>()
        try {
            context.contentResolver.query(
                MMS_PART_URI,
                arrayOf(
                    Telephony.Mms.Part._ID,
                    Telephony.Mms.Part.CONTENT_TYPE,
                    Telephony.Mms.Part.NAME,
                    Telephony.Mms.Part.FILENAME,
                    Telephony.Mms.Part.TEXT,
                    Telephony.Mms.Part._DATA,
                ),
                "${Telephony.Mms.Part.MSG_ID}=?",
                arrayOf(mmsId.toString()),
                null,
            )?.use { c ->
                val idxId = c.getColumnIndexOrThrow(Telephony.Mms.Part._ID)
                val idxCt = c.getColumnIndexOrThrow(Telephony.Mms.Part.CONTENT_TYPE)
                val idxName = c.getColumnIndexOrThrow(Telephony.Mms.Part.NAME)
                val idxFile = c.getColumnIndexOrThrow(Telephony.Mms.Part.FILENAME)
                val idxText = c.getColumnIndexOrThrow(Telephony.Mms.Part.TEXT)
                val idxData = c.getColumnIndexOrThrow(Telephony.Mms.Part._DATA)
                while (c.moveToNext()) {
                    val partId = c.getLong(idxId)
                    val mime = c.getString(idxCt) ?: ""
                    when {
                        mime == "application/smil" -> { /* présentation, ignorée */ }
                        mime == "text/plain" -> {
                            val data = c.getString(idxData)
                            val t = if (data != null) readMmsPartText(context, partId)
                                    else c.getString(idxText)
                            if (!t.isNullOrEmpty()) text.append(t)
                        }
                        else -> {
                            val fileName = c.getString(idxName)
                                ?: c.getString(idxFile)
                                ?: "part_$partId"
                            attachments += mapOf(
                                "partId" to partId,
                                "mimeType" to mime,
                                "fileName" to fileName,
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "mmsParts($mmsId) failed: ${e.message}")
        }
        return text.toString() to attachments
    }

    /** Concat des parts text/plain d'un MMS (pour le snippet conv-list). Null si aucune. */
    private fun mmsFirstText(context: Context, mmsId: Long): String? {
        val (text, _) = mmsParts(context, mmsId)
        return text.takeIf { it.isNotBlank() }
    }

    /** Lit le contenu d'une part text/plain via le flux (cas où _data pointe un fichier). */
    private fun readMmsPartText(context: Context, partId: Long): String? {
        return try {
            val uri = ContentUris.withAppendedId(MMS_PART_URI, partId)
            context.contentResolver.openInputStream(uri)?.use { input ->
                InputStreamReader(input, Charsets.UTF_8).readText()
            }
        } catch (e: Exception) {
            Log.w(TAG, "readMmsPartText($partId) failed: ${e.message}")
            null
        }
    }

    /** Adresse de l'expéditeur d'un MMS (table addr, type=FROM=137). Null si introuvable. */
    private fun mmsSenderAddress(context: Context, mmsId: Long): String? {
        return try {
            val addrUri = Uri.parse("${Telephony.Mms.CONTENT_URI}/$mmsId/addr")
            context.contentResolver.query(
                addrUri,
                arrayOf("address", "type"),
                "type=?",
                arrayOf(MMS_ADDR_TYPE_FROM.toString()),
                null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.takeIf { it.isNotBlank() && it != "insert-address-token" }
                } else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "mmsSenderAddress($mmsId) failed: ${e.message}")
            null
        }
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
    // MMS : lecture d'une part (image) → fichier cache, et envoi
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Charge le contenu binaire d'une part MMS et l'écrit dans un fichier cache lisible par Dart.
     *
     * On NE renvoie pas les bytes via le channel (les images MMS peuvent peser plusieurs Mo,
     * le passage MethodChannel serait coûteux). On écrit dans cacheDir/mms_parts/ et on renvoie
     * le path absolu — Dart lit le fichier directement.
     *
     * Idempotent : si le fichier existe déjà (même partId + même extension), on le réutilise.
     *
     * @return path absolu du fichier, ou null en cas d'échec.
     */
    suspend fun loadMmsPart(context: Context, partId: Long): String? =
        withContext(Dispatchers.IO) {
            if (partId <= 0L) return@withContext null
            try {
                val ext = mmsPartExtension(context, partId)
                val dir = File(context.cacheDir, "mms_parts").apply { mkdirs() }
                val outFile = File(dir, "part_$partId$ext")
                if (outFile.exists() && outFile.length() > 0) {
                    return@withContext outFile.absolutePath
                }
                val uri = ContentUris.withAppendedId(MMS_PART_URI, partId)
                context.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outFile).use { fos ->
                        val buf = ByteArray(8192)
                        while (true) {
                            val n = input.read(buf)
                            if (n <= 0) break
                            fos.write(buf, 0, n)
                        }
                    }
                } ?: run {
                    Log.w(TAG, "loadMmsPart($partId): null input stream")
                    return@withContext null
                }
                outFile.absolutePath
            } catch (e: Exception) {
                Log.e(TAG, "loadMmsPart($partId) failed: ${e.message}")
                null
            }
        }

    /** Devine l'extension d'une part depuis son content-type (pour un nom de fichier cache propre). */
    private fun mmsPartExtension(context: Context, partId: Long): String {
        val mime = try {
            context.contentResolver.query(
                MMS_PART_URI,
                arrayOf(Telephony.Mms.Part.CONTENT_TYPE),
                "${Telephony.Mms.Part._ID}=?",
                arrayOf(partId.toString()),
                null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: Exception) {
            null
        } ?: ""
        return when {
            mime.startsWith("image/jpeg") || mime.startsWith("image/jpg") -> ".jpg"
            mime.startsWith("image/png") -> ".png"
            mime.startsWith("image/gif") -> ".gif"
            mime.startsWith("image/webp") -> ".webp"
            mime.startsWith("video/mp4") -> ".mp4"
            mime.startsWith("audio/") -> ".aud"
            else -> ".bin"
        }
    }

    /**
     * Envoie un MMS contenant une image (et un body texte optionnel) à [address].
     *
     * Flow : lire/compresser l'image → composer un PDU m-send-req ([MmsPduComposer]) → écrire le
     * PDU dans cacheDir/mms_out/ → insérer une ligne Outbox + parts dans content://mms (pour que
     * la conv-list reflète l'envoi) → [SmsManager.sendMultimediaMessage] avec un PendingIntent.
     *
     * Best-effort : compatible carrier standard, mais l'envoi MMS dépend du MMSC (APN). Si l'image
     * est introuvable ou le PDU rejeté, renvoie null. L'insertion Outbox est non bloquante.
     *
     * @param imagePath chemin local de l'image à joindre (peut être null si body seul — rare).
     * @return le mmsId Outbox inséré (> 0) si la requête a été soumise, sinon null.
     */
    suspend fun sendMms(
        context: Context,
        address: String,
        body: String?,
        imagePath: String?,
    ): Long? = withContext(Dispatchers.IO) {
        if (address.isBlank()) {
            Log.w(TAG, "sendMms: blank address")
            return@withContext null
        }
        if (imagePath.isNullOrBlank() && body.isNullOrBlank()) {
            Log.w(TAG, "sendMms: nothing to send (no image, no body)")
            return@withContext null
        }
        try {
            val txn = "T${System.currentTimeMillis()}${UUID.randomUUID().toString().take(6)}"

            // 1. Media part (image) — compression best-effort.
            val mediaParts = ArrayList<MmsPduComposer.Part>()
            if (!imagePath.isNullOrBlank()) {
                val mp = buildImagePart(imagePath)
                if (mp != null) mediaParts += mp
                else if (body.isNullOrBlank()) {
                    Log.w(TAG, "sendMms: image unreadable and no body, abort")
                    return@withContext null
                }
            }

            // 2. Text part optionnelle.
            val textPart = body?.takeIf { it.isNotBlank() }?.let {
                MmsPduComposer.Part(
                    contentType = "text/plain;charset=utf-8",
                    contentId = "<text_0>",
                    contentLocation = "text_0.txt",
                    data = it.toByteArray(Charsets.UTF_8),
                )
            }

            val allMedia = listOfNotNull(textPart) + mediaParts
            if (allMedia.isEmpty()) {
                Log.w(TAG, "sendMms: no parts after build")
                return@withContext null
            }
            val smilPart = buildSmil(allMedia)

            // 3. Composer le PDU.
            val pdu = MmsPduComposer.composeSendReq(
                transactionId = txn,
                recipients = listOf(address),
                smilPart = smilPart,
                mediaParts = allMedia,
            )

            // 4. Écrire le PDU dans le cache.
            val pduDir = File(context.cacheDir, "mms_out").apply { mkdirs() }
            val pduFile = File(pduDir, "$txn.pdu")
            FileOutputStream(pduFile).use { it.write(pdu) }

            // 5. Insérer Outbox + parts (best-effort, n'empêche pas l'envoi).
            val mmsId = try {
                insertMmsOutbox(context, address, allMedia)
            } catch (e: Exception) {
                Log.w(TAG, "sendMms outbox insert failed: ${e.message}")
                -1L
            }

            // 6. PendingIntent SENT.
            val sentIntent = buildMmsSentIntent(context, mmsId, txn)

            // 7. sendMultimediaMessage.
            val sms = obtainSmsManagerForMms(context)
            sms.sendMultimediaMessage(
                context,
                Uri.fromFile(pduFile),
                null, // locationUrl null = MMSC carrier par défaut
                null, // configOverrides
                sentIntent,
            )
            Log.i(TAG, "sendMms → ${redact(address)} (img=${imagePath != null}, mmsId=$mmsId)")
            mmsId.takeIf { it > 0 }
        } catch (e: SecurityException) {
            Log.e(TAG, "sendMms → ${redact(address)}: SEND_SMS denied: ${e.message}")
            null
        } catch (e: Exception) {
            Log.e(TAG, "sendMms → ${redact(address)} failed: ${e.message}")
            null
        }
    }

    /** Construit une part image depuis un path local, compressée si > ~1 Mo. Null si illisible. */
    private fun buildImagePart(imagePath: String): MmsPduComposer.Part? {
        return try {
            val file = File(imagePath)
            if (!file.exists() || !file.canRead()) {
                Log.w(TAG, "buildImagePart: file unreadable")
                return null
            }
            val raw = file.readBytes()
            val (bytes, mime, ext) = compressImageIfNeeded(raw)
            MmsPduComposer.Part(
                contentType = mime,
                contentId = "<image_0>",
                contentLocation = "image_0.$ext",
                data = bytes,
            )
        } catch (e: Exception) {
            Log.w(TAG, "buildImagePart failed: ${e.message}")
            null
        }
    }

    /**
     * Réduit l'image sous [MAX_IMAGE_BYTES] / [MAX_IMAGE_W]x[MAX_IMAGE_H] en JPEG q dégressif.
     * @return Triple(bytes, mimeType, extension). Si déjà petite, renvoie le JPEG ré-encodé tel quel.
     */
    private fun compressImageIfNeeded(raw: ByteArray): Triple<ByteArray, String, String> {
        if (raw.size <= MAX_IMAGE_BYTES) return Triple(raw, "image/jpeg", "jpg")
        return try {
            val probe = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(raw, 0, raw.size, probe)
            val sample = calcInSampleSize(probe.outWidth, probe.outHeight, MAX_IMAGE_W, MAX_IMAGE_H)
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bm = BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)
                ?: return Triple(raw, "image/jpeg", "jpg")
            val out = ByteArrayOutputStream()
            var q = 80
            do {
                out.reset()
                bm.compress(Bitmap.CompressFormat.JPEG, q, out)
                q -= 10
            } while (out.size() > MAX_IMAGE_BYTES && q >= 30)
            bm.recycle()
            Triple(out.toByteArray(), "image/jpeg", "jpg")
        } catch (e: Throwable) {
            Log.w(TAG, "compressImageIfNeeded fallback: ${e.message}")
            Triple(raw, "image/jpeg", "jpg")
        }
    }

    private fun calcInSampleSize(w: Int, h: Int, maxW: Int, maxH: Int): Int {
        if (w <= 0 || h <= 0) return 1
        var inSample = 1
        var hw = w
        var hh = h
        while (hw / 2 >= maxW && hh / 2 >= maxH) {
            hw /= 2; hh /= 2; inSample *= 2
        }
        return inSample
    }

    /** SMIL minimal : un slide par part, en série. Apaise les MMSC stricts. */
    private fun buildSmil(parts: List<MmsPduComposer.Part>): MmsPduComposer.Part {
        val sb = StringBuilder()
        sb.append("<smil>\n<head>\n<layout>\n<root-layout/>\n")
        sb.append("<region id=\"Image\" left=\"0\" top=\"0\" height=\"100%\" width=\"100%\" fit=\"meet\"/>\n")
        sb.append("<region id=\"Text\" left=\"0\" top=\"70%\" height=\"30%\" width=\"100%\" fit=\"meet\"/>\n")
        sb.append("</layout>\n</head>\n<body>\n")
        for (p in parts) {
            sb.append("<par dur=\"5000ms\">\n")
            val region = if (p.contentType.startsWith("text/")) "Text" else "Image"
            val tag = when {
                p.contentType.startsWith("image/") -> "img"
                p.contentType.startsWith("video/") -> "video"
                p.contentType.startsWith("audio/") -> "audio"
                p.contentType.startsWith("text/") -> "text"
                else -> "ref"
            }
            sb.append("<$tag src=\"${p.contentLocation}\" region=\"$region\"/>\n")
            sb.append("</par>\n")
        }
        sb.append("</body>\n</smil>\n")
        return MmsPduComposer.Part(
            contentType = "application/smil",
            contentId = "<smil>",
            contentLocation = "smil.xml",
            data = sb.toString().toByteArray(Charsets.UTF_8),
        )
    }

    /** Insère un MMS sortant + ses parts dans content://mms (best-effort). @return mmsId ou -1. */
    private fun insertMmsOutbox(
        context: Context,
        recipient: String,
        parts: List<MmsPduComposer.Part>,
    ): Long {
        val resolver = context.contentResolver
        val threadId = Telephony.Threads.getOrCreateThreadId(context, recipient)
        val nowSec = System.currentTimeMillis() / 1000L

        val values = ContentValues().apply {
            put(Telephony.Mms.THREAD_ID, threadId)
            put(Telephony.Mms.DATE, nowSec)
            put(Telephony.Mms.MESSAGE_BOX, Telephony.Mms.MESSAGE_BOX_OUTBOX)
            put(Telephony.Mms.READ, 1)
            put(Telephony.Mms.SEEN, 1)
            put(Telephony.Mms.MESSAGE_TYPE, 128) // m-send-req
            put(Telephony.Mms.MMS_VERSION, 18)   // 0x12 = 1.2
            put(Telephony.Mms.CONTENT_TYPE, "application/vnd.wap.multipart.related")
        }
        val mmsUri = resolver.insert(Telephony.Mms.Outbox.CONTENT_URI, values) ?: return -1L
        val mmsId = ContentUris.parseId(mmsUri)

        // Adresses : self FROM=137 (insert-address-token), recipient TO=151.
        val addrUri = mmsUri.buildUpon().appendPath("addr").build()
        resolver.insert(addrUri, ContentValues().apply {
            put("address", "insert-address-token")
            put("charset", 106) // UTF-8
            put("type", MMS_ADDR_TYPE_FROM)
        })
        resolver.insert(addrUri, ContentValues().apply {
            put("address", recipient)
            put("charset", 106)
            put("type", MMS_ADDR_TYPE_TO)
        })

        // Parts.
        val partsUri = mmsUri.buildUpon().appendPath("part").build()
        for ((i, p) in parts.withIndex()) {
            val pv = ContentValues().apply {
                put(Telephony.Mms.Part.MSG_ID, mmsId)
                put(Telephony.Mms.Part.SEQ, i)
                put(Telephony.Mms.Part.CONTENT_TYPE, p.contentType.substringBefore(';').trim())
                put(Telephony.Mms.Part.NAME, p.contentLocation)
                put(Telephony.Mms.Part.CONTENT_LOCATION, p.contentLocation)
                put(Telephony.Mms.Part.CONTENT_ID, p.contentId)
                if (p.contentType.startsWith("text/")) {
                    put(Telephony.Mms.Part.TEXT, String(p.data, Charsets.UTF_8))
                }
            }
            val pUri = resolver.insert(partsUri, pv)
            if (pUri != null &&
                !p.contentType.startsWith("text/") &&
                p.contentType != "application/smil"
            ) {
                try {
                    resolver.openOutputStream(pUri)?.use { it.write(p.data) }
                } catch (e: Exception) {
                    Log.w(TAG, "insertMmsOutbox part write failed: ${e.message}")
                }
            }
        }
        return mmsId
    }

    private fun buildMmsSentIntent(context: Context, mmsId: Long, txn: String): PendingIntent {
        val intent = Intent(ACTION_MMS_SENT).apply {
            setPackage(context.packageName)
            putExtra(EXTRA_MMS_ID, mmsId)
            putExtra(EXTRA_TXN_ID, txn)
        }
        val req = txn.hashCode() and 0x7FFFFFFF
        return PendingIntent.getBroadcast(
            context, req, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** SmsManager pour MMS, lié à la SIM SMS par défaut quand l'API le permet. */
    @Suppress("DEPRECATION")
    private fun obtainSmsManagerForMms(context: Context): SmsManager {
        val subId = runCatching { SubscriptionManager.getDefaultSmsSubscriptionId() }
            .getOrDefault(SubscriptionManager.INVALID_SUBSCRIPTION_ID)
        return when {
            subId >= 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                context.getSystemService(SmsManager::class.java).createForSubscriptionId(subId)
            subId >= 0 ->
                SmsManager.getSmsManagerForSubscriptionId(subId)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                context.getSystemService(SmsManager::class.java)
            else -> SmsManager.getDefault()
        }
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
