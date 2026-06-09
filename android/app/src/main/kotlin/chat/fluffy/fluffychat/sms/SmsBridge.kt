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

    // Plafond de taille d'un m-retrieve-conf lu en RAM (cf. ingestDownloadedMms) :
    // borne anti-OOM contre une content-location servant une réponse géante.
    private const val MAX_PDU_BYTES = 4L * 1024 * 1024

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

    /**
     * Callback poussé à la fin de l'envoi d'un MMS (POST direct MMSC).
     * Map : { mmsId, ok }. Null si Flutter pas attaché.
     */
    @Volatile
    var onMmsSendResult: ((Map<String, Any?>) -> Unit)? = null

    // ── Actions PendingIntent SENT / DELIVERED ────────────────────────────────
    const val ACTION_SMS_SENT = "eu.devlabz.vox.SMS_SENT"
    const val ACTION_SMS_DELIVERED = "eu.devlabz.vox.SMS_DELIVERED"
    const val ACTION_MMS_SENT = "eu.devlabz.vox.MMS_SENT"
    const val ACTION_MMS_DOWNLOADED = "eu.devlabz.vox.MMS_DOWNLOADED"
    const val EXTRA_ROW_ID = "row_id"
    const val EXTRA_MMS_ID = "mms_id"
    const val EXTRA_TXN_ID = "txn_id"
    const val EXTRA_CONTENT_LOCATION = "content_location"
    const val EXTRA_FROM = "from"

    // Plafonds compression image MMS sortant (≈ contraintes carrier).
    // Carrier MMS size cap: Orange (and most FR carriers) reject the m-send-req
    // with "2511:Message too large" above ~300 KB for the WHOLE PDU. We target
    // 280 KB for the image to leave room for SMIL + headers, and cap the
    // dimensions modestly — a MMS doesn't need 1080p.
    private const val MAX_IMAGE_BYTES = 280_000
    private const val MAX_IMAGE_W = 1280
    private const val MAX_IMAGE_H = 960
    // Au-delà, on ne charge pas le fichier entier en RAM (readBytes) : on décode
    // directement depuis le disque, sous-échantillonné, pour éviter l'OOM.
    private const val MAX_IMAGE_SOURCE_BYTES = 8_000_000L

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

            // Patch unreadCount + résolution displayName/photo (best-effort,
            // READ_CONTACTS optionnel). Mémoïse les lookups contacts sur la durée
            // de l'appel : deux threads partageant un numéro ne déclenchent qu'une
            // seule query.
            val contactCache = HashMap<String, ContactInfo>()
            for ((threadId, conv) in byThread) {
                conv["unreadCount"] = unreadByThread[threadId] ?: 0
                val address = conv["address"] as? String
                if (!address.isNullOrBlank()) {
                    val info = contactCache.getOrPut(address) {
                        resolveContact(context, address)
                    }
                    conv["displayName"] = info.name
                    conv["photoPath"] = info.photoPath
                }
            }

            byThread.values
                .sortedByDescending { (it["date"] as? Long) ?: 0L }
                .toList()
        }

    /**
     * Snippet d'un MMS pour la liste : sujet si présent, sinon 1re part text/plain,
     * sinon un libellé média (emoji + nom de fichier lisible, ou libellé générique
     * "Photo/Audio/Vidéo/Fichier" si le nom est absent ou moche), sinon "[MMS]".
     */
    private fun mmsSnippet(context: Context, mmsId: Long, subject: String?): String {
        val subj = subject?.takeUnless { it.isBlank() || it == "NoSubject" }
        if (subj != null) return subj
        val (text, attachments) = mmsParts(context, mmsId)
        if (text.isNotBlank()) return text
        // MMS purement média : 1re pièce jointe → emoji + nom propre / libellé générique.
        val first = attachments.firstOrNull()
        if (first != null) return mediaSnippet(first)
        return "[MMS]"
    }

    /** Emoji selon le type MIME, suivi du nom de fichier lisible ou du libellé générique. */
    private fun mediaSnippet(part: Map<String, Any?>): String {
        val mime = (part["mimeType"] as? String).orEmpty()
        val raw = (part["fileName"] as? String).orEmpty()
        val (emoji, label) = when {
            mime.startsWith("image/") -> "📷" to "Photo"
            mime.startsWith("video/") -> "🎬" to "Vidéo"
            mime.startsWith("audio/") -> "🎵" to "Audio"
            mime.contains("vcard") || mime.contains("x-vcard") -> "👤" to "Contact"
            else -> "📎" to "Fichier"
        }
        // Un nom auto-généré (part_123) ou vide n'apporte rien → libellé générique.
        val name = raw.takeUnless { it.isBlank() || it.startsWith("part_") } ?: label
        return "$emoji $name"
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
    /**
     * Liste les messages d'un thread, paginé. Charge au plus [limit] messages les
     * plus récents STRICTEMENT antérieurs à [beforeMs] (ou les plus récents si
     * beforeMs <= 0). Renvoyés triés ASC (ancien → récent) comme avant.
     *
     * Pagination : à l'ouverture, appeler avec beforeMs=0 → les `limit` derniers.
     * Pour remonter, rappeler avec beforeMs = date du plus ancien message déjà
     * chargé. limit<=0 = pas de limite (compat / petits threads).
     *
     * Perf : SMS et MMS sont chacun query en DATE DESC LIMIT, fusionnés, coupés à
     * [limit], puis re-triés ASC. Les parts MMS sont lues en batch (1 query).
     */
    suspend fun listMessages(
        context: Context,
        threadId: Long,
        limit: Int = 0,
        beforeMs: Long = 0L,
    ): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext emptyList()
            val out = ArrayList<Map<String, Any?>>()
            // Sur-échantillonne chaque source (SMS+MMS) pour qu'après fusion+coupe
            // on ait bien les `limit` plus récents tous types confondus.
            val perSourceLimit = if (limit > 0) limit else 0

            // ── SMS ──
            try {
                val smsSel = StringBuilder("${Telephony.Sms.THREAD_ID}=?")
                val smsArgs = arrayListOf(threadId.toString())
                if (beforeMs > 0L) {
                    smsSel.append(" AND ${Telephony.Sms.DATE}<?")
                    smsArgs.add(beforeMs.toString())
                }
                val smsOrder = "${Telephony.Sms.DATE} DESC" +
                    if (perSourceLimit > 0) " LIMIT $perSourceLimit" else ""
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
                    smsSel.toString(),
                    smsArgs.toTypedArray(),
                    smsOrder,
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
            out += listMms(context, threadId, perSourceLimit, beforeMs)

            // Fusion : tri DESC, coupe aux `limit` plus récents tous types
            // confondus, puis re-tri ASC pour l'affichage (ancien → récent).
            val merged = out.sortedByDescending { (it["date"] as? Long) ?: 0L }
            val capped = if (limit > 0) merged.take(limit) else merged
            capped.sortedBy { (it["date"] as? Long) ?: 0L }
        }

    /**
     * Lit les MMS d'un thread + leurs parts. DATE du provider MMS est en SECONDES → normalisée ms.
     * Pour chaque MMS : `body` = concat des parts text/plain ; `attachments` = parts non-texte/non-smil.
     */
    private fun listMms(
        context: Context,
        threadId: Long,
        limit: Int = 0,
        beforeMs: Long = 0L,
    ): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        try {
            // beforeMs est en ms ; la colonne MMS DATE est en SECONDES.
            val sel = StringBuilder("${Telephony.Mms.THREAD_ID}=?")
            val args = arrayListOf(threadId.toString())
            if (beforeMs > 0L) {
                sel.append(" AND ${Telephony.Mms.DATE}<?")
                args.add((beforeMs / 1000L).toString())
            }
            val order = "${Telephony.Mms.DATE} DESC" +
                if (limit > 0) " LIMIT $limit" else ""
            // 1re passe : collecte les MMS (sans les parts), mémorise les ids.
            val rows = ArrayList<MutableMap<String, Any?>>()
            val mmsIds = ArrayList<Long>()
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
                sel.toString(),
                args.toTypedArray(),
                order,
            )?.use { c ->
                val idxId = c.getColumnIndexOrThrow(Telephony.Mms._ID)
                val idxDate = c.getColumnIndexOrThrow(Telephony.Mms.DATE)
                val idxBox = c.getColumnIndexOrThrow(Telephony.Mms.MESSAGE_BOX)
                val idxRead = c.getColumnIndexOrThrow(Telephony.Mms.READ)
                val idxSubject = c.getColumnIndexOrThrow(Telephony.Mms.SUBJECT)
                while (c.moveToNext()) {
                    val mmsId = c.getLong(idxId)
                    mmsIds.add(mmsId)
                    rows.add(
                        mutableMapOf(
                            "_mmsId" to mmsId,
                            "_box" to c.getInt(idxBox),
                            "_date" to c.getLong(idxDate),
                            "_read" to c.getInt(idxRead),
                            "_subject" to c.getString(idxSubject),
                        ),
                    )
                }
            }
            // 2e passe : TOUTES les parts en UNE query (anti N+1).
            val partsByMms = mmsPartsBatch(context, mmsIds)
            for (row in rows) {
                val mmsId = row["_mmsId"] as Long
                val box = row["_box"] as Int
                val isFromMe = box == Telephony.Mms.MESSAGE_BOX_SENT ||
                    box == Telephony.Mms.MESSAGE_BOX_OUTBOX
                val (text, attachments) =
                    partsByMms[mmsId] ?: ("" to emptyList())
                val subject = (row["_subject"] as? String)
                    ?.takeUnless { it.isBlank() || it == "NoSubject" }
                // Ne pas répéter le sujet s'il est déjà identique au texte
                // (certains MMS copient le corps dans le sujet → doublon).
                val subj = subject?.takeUnless { it.trim() == text.trim() }
                val body = listOfNotNull(subj, text.takeIf { it.isNotBlank() }).joinToString("\n")
                val address = if (isFromMe) "" else (mmsSenderAddress(context, mmsId) ?: "")
                out += mapOf(
                    "id" to mmsId,
                    "address" to address,
                    "body" to body,
                    "date" to (row["_date"] as Long) * 1000L,
                    "isFromMe" to isFromMe,
                    // Mappe la box MMS vers une sémantique type proche des SMS pour Dart.
                    "type" to if (isFromMe) Telephony.Sms.MESSAGE_TYPE_SENT
                              else Telephony.Sms.MESSAGE_TYPE_INBOX,
                    "status" to 0,
                    "read" to ((row["_read"] as Int) == 1),
                    "isMms" to true,
                    "attachments" to attachments,
                )
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "listMms($threadId): READ_SMS denied: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "listMms($threadId) failed: ${e.message}")
        }
        return out
    }

    /**
     * Lit les parts text+attachments de PLUSIEURS MMS en une seule query
     * (`MSG_ID IN (...)`), pour éviter le N+1 sur les longues conversations.
     * @return map mmsId → Pair(texte dédupliqué, attachments).
     */
    private fun mmsPartsBatch(
        context: Context,
        mmsIds: List<Long>,
    ): Map<Long, Pair<String, List<Map<String, Any?>>>> {
        if (mmsIds.isEmpty()) return emptyMap()
        val textsByMms = HashMap<Long, LinkedHashSet<String>>()
        val attachByMms = HashMap<Long, ArrayList<Map<String, Any?>>>()
        try {
            val placeholders = mmsIds.joinToString(",") { "?" }
            context.contentResolver.query(
                MMS_PART_URI,
                arrayOf(
                    Telephony.Mms.Part._ID,
                    Telephony.Mms.Part.MSG_ID,
                    Telephony.Mms.Part.CONTENT_TYPE,
                    Telephony.Mms.Part.NAME,
                    Telephony.Mms.Part.FILENAME,
                    Telephony.Mms.Part.TEXT,
                    Telephony.Mms.Part._DATA,
                ),
                "${Telephony.Mms.Part.MSG_ID} IN ($placeholders)",
                mmsIds.map { it.toString() }.toTypedArray(),
                null,
            )?.use { c ->
                val idxId = c.getColumnIndexOrThrow(Telephony.Mms.Part._ID)
                val idxMsg = c.getColumnIndexOrThrow(Telephony.Mms.Part.MSG_ID)
                val idxCt = c.getColumnIndexOrThrow(Telephony.Mms.Part.CONTENT_TYPE)
                val idxName = c.getColumnIndexOrThrow(Telephony.Mms.Part.NAME)
                val idxFile = c.getColumnIndexOrThrow(Telephony.Mms.Part.FILENAME)
                val idxText = c.getColumnIndexOrThrow(Telephony.Mms.Part.TEXT)
                val idxData = c.getColumnIndexOrThrow(Telephony.Mms.Part._DATA)
                while (c.moveToNext()) {
                    val partId = c.getLong(idxId)
                    val msgId = c.getLong(idxMsg)
                    val mime = c.getString(idxCt) ?: ""
                    when {
                        mime == "application/smil" -> { /* présentation, ignorée */ }
                        mime == "text/plain" -> {
                            val data = c.getString(idxData)
                            val t = if (data != null) readMmsPartText(context, partId)
                                    else c.getString(idxText)
                            val trimmed = t?.trim()
                            if (!trimmed.isNullOrEmpty()) {
                                textsByMms.getOrPut(msgId) { LinkedHashSet() }.add(trimmed)
                            }
                        }
                        else -> {
                            val fileName = c.getString(idxName)
                                ?: c.getString(idxFile)
                                ?: "part_$partId"
                            attachByMms.getOrPut(msgId) { ArrayList() } += mapOf(
                                "partId" to partId,
                                "mimeType" to mime,
                                "fileName" to fileName,
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "mmsPartsBatch failed: ${e.message}")
        }
        return mmsIds.associateWith { id ->
            (textsByMms[id]?.joinToString("\n") ?: "") to
                (attachByMms[id] ?: emptyList())
        }
    }

    /**
     * Lit toutes les parts d'un MMS.
     * @return Pair(texte concaténé des parts text/plain, liste d'attachments {partId,mimeType,fileName}).
     * Les parts application/smil et text/plain ne sont PAS exposées comme attachments.
     *
     * Note perf (assumée) : appelée une fois par MMS (N+1 sur content://mms/part).
     * Un batch `MSG_ID IN (...)` réduirait les round-trips, mais s'exécute sur
     * Dispatchers.IO (pas de freeze UI) et le parsing par-MMS est carrier-
     * dépendant et fragile — on garde la forme unitaire, plus sûre, pour un
     * thread de taille réaliste (quelques dizaines de MMS).
     */
    private fun mmsParts(context: Context, mmsId: Long): Pair<String, List<Map<String, Any?>>> {
        // Certains MMS (expéditeurs iOS, ou double-stockage à la réception)
        // contiennent la MÊME part text/plain en double → le texte s'affichait
        // collé deux fois dans la bulle. On dédoublonne les fragments de texte
        // identiques et on les joint proprement.
        val textParts = LinkedHashSet<String>()
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
                            val trimmed = t?.trim()
                            if (!trimmed.isNullOrEmpty()) textParts.add(trimmed)
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
        return textParts.joinToString("\n") to attachments
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
     * Supprime un message (SMS ou MMS) par son id. isMms distingue la table
     * cible (content://sms vs content://mms). Nécessite ROLE_SMS (app défaut).
     */
    suspend fun deleteMessage(context: Context, id: Long, isMms: Boolean): Int =
        withContext(Dispatchers.IO) {
            if (id <= 0L) return@withContext 0
            try {
                val uri = if (isMms) {
                    ContentUris.withAppendedId(Telephony.Mms.CONTENT_URI, id)
                } else {
                    ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, id)
                }
                context.contentResolver.delete(uri, null, null)
            } catch (e: Exception) {
                Log.e(TAG, "deleteMessage($id, mms=$isMms) failed: ${e.message}")
                0
            }
        }

    /**
     * Supprime toute une conversation (SMS + MMS) par son threadId. Utilise
     * l'URI conversations qui purge les deux tables pour le thread.
     */
    suspend fun deleteConversation(context: Context, threadId: Long): Int =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext 0
            try {
                val uri = ContentUris.withAppendedId(
                    Telephony.Threads.CONTENT_URI,
                    threadId,
                )
                context.contentResolver.delete(uri, null, null)
            } catch (e: Exception) {
                Log.e(TAG, "deleteConversation($threadId) failed: ${e.message}")
                // Fallback : purge SMS puis MMS par thread_id.
                var n = 0
                try {
                    n += context.contentResolver.delete(
                        Telephony.Sms.CONTENT_URI,
                        "${Telephony.Sms.THREAD_ID}=?",
                        arrayOf(threadId.toString()),
                    )
                    n += context.contentResolver.delete(
                        Telephony.Mms.CONTENT_URI,
                        "${Telephony.Mms.THREAD_ID}=?",
                        arrayOf(threadId.toString()),
                    )
                } catch (e2: Exception) {
                    Log.e(TAG, "deleteConversation fallback failed: ${e2.message}")
                }
                n
            }
        }

    /**
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
        @Suppress("UNUSED_PARAMETER") requestCodeOffset: Int,
    ): PendingIntent {
        val intent = Intent(action).apply {
            setPackage(context.packageName)
            putExtra(EXTRA_ROW_ID, rowId)
        }
        // requestCode unique par (action, rowId, partIndex). L'ancien
        // `(rowId.toInt() shl 4) + partIndex + offset` débordait l'Int et faisait
        // collisionner les codes SENT d'une ligne avec les DELIVERED d'une autre
        // après ~16k messages (FLAG_UPDATE_CURRENT écrasait alors le mauvais
        // extra). Objects.hash garantit l'unicité sans débordement arithmétique.
        val requestCode = java.util.Objects.hash(action, rowId, partIndex) and 0x7FFFFFFF
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
                val mime = mmsPartMime(context, partId)
                // HEIC/HEIF (typical from iPhones) are not decodable by Flutter's
                // Skia. Android *can* decode them, so transcode to JPEG here and
                // hand Flutter a .jpg it can render. Same for any image format
                // Skia doesn't handle (bmp/tiff): if it's an image type Skia
                // doesn't natively support, route it through the bitmap path.
                if (mime != null && needsTranscode(mime)) {
                    val jpeg = transcodeImageToJpeg(context, partId)
                    if (jpeg != null) return@withContext jpeg
                    // Fall through to a raw copy if transcoding failed (better a
                    // broken tile than nothing, and the viewer can still share it).
                }
                val ext = extensionForMime(mime)
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

    /** Image content-types Flutter/Skia can't decode but Android can. */
    private fun needsTranscode(mime: String): Boolean {
        val m = mime.lowercase()
        return m.startsWith("image/heic") ||
            m.startsWith("image/heif") ||
            m.startsWith("image/bmp") ||
            m.startsWith("image/tiff") ||
            m.startsWith("image/x-")
    }

    /**
     * Decodes an MMS image part with Android's native decoder and re-encodes it
     * as JPEG into the cache, so Flutter can display formats Skia rejects (HEIC
     * etc.). Returns the cached .jpg path, or null on failure.
     */
    private fun transcodeImageToJpeg(context: Context, partId: Long): String? {
        return try {
            val dir = File(context.cacheDir, "mms_parts").apply { mkdirs() }
            val outFile = File(dir, "part_${partId}_t.jpg")
            if (outFile.exists() && outFile.length() > 0) return outFile.absolutePath
            val uri = ContentUris.withAppendedId(MMS_PART_URI, partId)
            val bitmap = context.contentResolver.openInputStream(uri)?.use { input ->
                BitmapFactory.decodeStream(input)
            } ?: return null
            FileOutputStream(outFile).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, fos)
            }
            bitmap.recycle()
            if (outFile.length() > 0) outFile.absolutePath else null
        } catch (e: Exception) {
            Log.e(TAG, "transcodeImageToJpeg($partId) failed: ${e.message}")
            null
        }
    }

    /** Returns the partId of the first image part of a MMS, or -1. */
    private fun firstMmsImagePartId(context: Context, mmsId: Long): Long {
        return try {
            context.contentResolver.query(
                MMS_PART_URI,
                arrayOf(Telephony.Mms.Part._ID, Telephony.Mms.Part.CONTENT_TYPE),
                "${Telephony.Mms.Part.MSG_ID}=?",
                arrayOf(mmsId.toString()),
                null,
            )?.use { c ->
                val idIdx = c.getColumnIndexOrThrow(Telephony.Mms.Part._ID)
                val ctIdx = c.getColumnIndexOrThrow(Telephony.Mms.Part.CONTENT_TYPE)
                while (c.moveToNext()) {
                    val ct = c.getString(ctIdx) ?: ""
                    if (ct.startsWith("image/")) return c.getLong(idIdx)
                }
                -1L
            } ?: -1L
        } catch (e: Exception) {
            -1L
        }
    }

    /** Reads a single part's content-type. */
    private fun mmsPartMime(context: Context, partId: Long): String? = try {
        context.contentResolver.query(
            MMS_PART_URI,
            arrayOf(Telephony.Mms.Part.CONTENT_TYPE),
            "${Telephony.Mms.Part._ID}=?",
            arrayOf(partId.toString()),
            null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    /** Guesses a clean cache-file extension from a content-type. */
    private fun extensionForMime(mime: String?): String {
        val m = (mime ?: "").lowercase()
        return when {
            m.startsWith("image/jpeg") || m.startsWith("image/jpg") -> ".jpg"
            m.startsWith("image/png") -> ".png"
            m.startsWith("image/gif") -> ".gif"
            m.startsWith("image/webp") -> ".webp"
            m.startsWith("video/mp4") -> ".mp4"
            m.startsWith("video/3gpp") -> ".3gp"
            m.startsWith("video/") -> ".mp4"
            m.startsWith("audio/mpeg") -> ".mp3"
            m.startsWith("audio/amr") -> ".amr"
            m.startsWith("audio/") -> ".m4a"
            m.contains("vcard") || m.contains("x-vcard") -> ".vcf"
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

            // 4. Écrire le PDU dans le cache, servi via MmsPduProvider (un
            // ContentProvider que le service MMS système sait relire — cf. AOSP
            // MmsFileProvider). Un file:// ou un androidx FileProvider échouait
            // instantanément (code=5) car le service, dans un autre process, ne
            // pouvait pas lire l'URI.
            val pduName = "$txn.dat"
            val pduFile = MmsPduProvider.fileForName(context, pduName)
                ?: return@withContext null
            FileOutputStream(pduFile).use { it.write(pdu) }

            // 5. Insérer Outbox + parts (best-effort, n'empêche pas l'envoi).
            val mmsId = try {
                insertMmsOutbox(context, address, allMedia)
            } catch (e: Exception) {
                Log.w(TAG, "sendMms outbox insert failed: ${e.message}")
                -1L
            }

            // 6. Forcer le réseau cellulaire MMS puis POSTer le PDU directement
            // au MMSC. sendMultimediaMessage du système retourne HTTP_FAILURE
            // (code=5) sur ce device/carrier (GrapheneOS + Orange + WiFi-calling)
            // sans jamais atteindre le MMSC → on by-passe avec notre propre client
            // HTTP, sur le réseau MMS cellulaire (comme QKSMS/Signal).
            sendPduOnMmsNetwork(context, pdu, mmsId, txn)
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

    /**
     * Single-thread executor so MMS sends are SERIALIZED — back-to-back sends no
     * longer fire concurrent requestNetwork()s that raced into connect-timeout /
     * "Binding socket to network failed: EPERM" (one send tearing the MMS PDN
     * down while the next bound to it). One send at a time, shared MMS network.
     */
    private val mmsSendExecutor: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor()

    /**
     * Queues an MMS send: acquires the shared cellular-MMS network (reference
     * counted, via [MmsNetworkManager]), POSTs the PDU to the MMSC over it
     * ([MmsHttpClient]), updates the outbox on success. Serialized through
     * [mmsSendExecutor] so concurrent sends can't fight over the network.
     */
    private fun sendPduOnMmsNetwork(
        context: Context,
        pdu: ByteArray,
        mmsId: Long,
        txn: String,
    ) {
        val app = context.applicationContext
        mmsSendExecutor.execute {
            val (mmscUrl, proxyHost, proxyPort) = readMmsApn(app)
            if (mmscUrl.isNullOrBlank()) {
                Log.e(TAG, "sendPduOnMmsNetwork: pas de MMSC dans l'APN")
                onMmsSendResult?.invoke(mapOf("mmsId" to mmsId, "ok" to false))
                return@execute
            }
            val ok = MmsNetworkManager.withNetwork(app) { _ ->
                Log.i(TAG, "MMS network acquis → POST MMSC (proxy=${if (proxyHost.isNullOrBlank()) "non" else "oui"})")
                // The process is already bound to the MMS network by the manager,
                // so a plain HTTP connection routes over cellular MMS.
                val resp = MmsHttpClient.postPdu(
                    mmscUrl = mmscUrl,
                    proxyHost = proxyHost,
                    proxyPort = proxyPort,
                    pdu = pdu,
                )
                resp != null
            } ?: false
            Log.i(TAG, "MMS POST result ok=$ok (mmsId=$mmsId)")
            if (ok) markMmsSent(app, mmsId)
            onMmsSendResult?.invoke(mapOf("mmsId" to mmsId, "ok" to ok))
        }
    }

    /**
     * Resolves MMSC URL + MMS proxy host/port for the active SIM, trying, in
     * order: (1) CarrierConfigManager — the official API, NO permission needed;
     * (2) the carriers content provider (often blocked: "No permission to access
     * APN settings" on GrapheneOS / non-system apps); (3) a per-MCCMNC built-in
     * table for known carriers (Orange FR…). The provider path was the one that
     * failed — apps can't read content://telephony/carriers without the
     * privileged WRITE_APN_SETTINGS, so the CarrierConfig + built-in fallbacks
     * are what actually make this work.
     */
    private fun readMmsApn(context: Context): Triple<String?, String?, Int> {
        val numeric = runCatching {
            context.getSystemService(android.telephony.TelephonyManager::class.java)
                ?.simOperator
        }.getOrNull()

        // (1) CarrierConfigManager — official, permission-free.
        readMmsFromCarrierConfig(context)?.let {
            Log.i(TAG, "MMS APN via CarrierConfig (résolu)")
            return it
        }

        // (2) Carriers content provider (may throw SecurityException).
        readMmsFromCarriersProvider(context, numeric)?.let {
            Log.i(TAG, "MMS APN via provider (résolu)")
            return it
        }

        // (3) Built-in table for known carriers.
        builtInMmsApn(numeric)?.let {
            Log.i(TAG, "MMS APN via built-in (numeric=$numeric, résolu)")
            return it
        }

        Log.e(TAG, "readMmsApn: aucune source MMSC (numeric=$numeric)")
        return Triple(null, null, 0)
    }

    private fun readMmsFromCarrierConfig(context: Context): Triple<String?, String?, Int>? {
        return try {
            val ccm = context.getSystemService(
                android.telephony.CarrierConfigManager::class.java,
            ) ?: return null
            val config = ccm.config ?: return null
            // Keys live in CarrierConfigManager.Mms (string constants, accessed
            // directly to avoid SDK-version symbol issues).
            val mmsc = config.getString("mmsMmscUrlString")
                ?.takeIf { it.isNotBlank() } ?: return null
            val proxyAddr = config.getString("mmsHttpProxyAddressString")
                ?.takeIf { it.isNotBlank() }
            val proxyPort = config.getInt("mmsHttpProxyPortInt").takeIf { it > 0 } ?: 80
            Triple(mmsc, proxyAddr, proxyPort)
        } catch (e: Exception) {
            null
        }
    }

    private fun readMmsFromCarriersProvider(
        context: Context,
        numeric: String?,
    ): Triple<String?, String?, Int>? {
        return try {
            context.contentResolver.query(
                Uri.parse("content://telephony/carriers"),
                arrayOf("mmsc", "mmsproxy", "mmsport", "type", "current", "numeric"),
                null, null, null,
            )?.use { c ->
                val mmscIdx = c.getColumnIndex("mmsc")
                val proxyIdx = c.getColumnIndex("mmsproxy")
                val portIdx = c.getColumnIndex("mmsport")
                val typeIdx = c.getColumnIndex("type")
                val curIdx = c.getColumnIndex("current")
                val numIdx = c.getColumnIndex("numeric")
                var fallback: Triple<String?, String?, Int>? = null
                while (c.moveToNext()) {
                    val type = c.getString(typeIdx) ?: ""
                    val mmsc = c.getString(mmscIdx)
                    if (!type.contains("mms") || mmsc.isNullOrBlank()) continue
                    val proxy = c.getString(proxyIdx)?.takeIf { it.isNotBlank() }
                    val port = c.getString(portIdx)?.toIntOrNull() ?: 80
                    val triple = Triple(mmsc, proxy, port)
                    val isCurrent = curIdx >= 0 && c.getString(curIdx) != null
                    val numMatches = numIdx < 0 || numeric.isNullOrBlank() ||
                        c.getString(numIdx) == numeric
                    if (isCurrent && numMatches) return triple
                    if (fallback == null) fallback = triple
                }
                fallback
            }
        } catch (e: Exception) {
            Log.w(TAG, "readMmsFromCarriersProvider: ${e.message}")
            null
        }
    }

    /** Known MMS APNs by MCC+MNC, for when neither CarrierConfig nor the APN
     *  provider yield anything (e.g. GrapheneOS blocking the provider). */
    private fun builtInMmsApn(numeric: String?): Triple<String?, String?, Int>? {
        return when (numeric) {
            // Orange France (208/01, 208/02).
            "20801", "20802" ->
                Triple("http://mms.orange.fr", "192.168.10.200", 8080)
            // SFR (208/10, 208/13).
            "20810", "20813" ->
                Triple("http://mms1", "10.151.0.1", 8080)
            // Bouygues (208/20, 208/21).
            "20820", "20821" ->
                Triple("http://mms.bouyguestelecom.fr/mms/wapenc", null, 80)
            // Free Mobile (208/15).
            "20815" ->
                Triple("http://mms.free.fr", null, 80)
            else -> null
        }
    }

    /** Marks an outbound MMS as sent (moves it from outbox to sent box). */
    private fun markMmsSent(context: Context, mmsId: Long) {
        if (mmsId <= 0) return
        runCatching {
            val values = ContentValues().apply {
                put(Telephony.Mms.MESSAGE_BOX, Telephony.Mms.MESSAGE_BOX_SENT)
            }
            context.contentResolver.update(
                ContentUris.withAppendedId(Uri.parse("content://mms"), mmsId),
                values, null, null,
            )
        }
    }

    /** Construit une part image depuis un path local, compressée si > ~1 Mo. Null si illisible. */
    private fun buildImagePart(imagePath: String): MmsPduComposer.Part? {
        // catch Throwable (pas Exception) : readBytes/decode peuvent jeter
        // OutOfMemoryError (un Error, pas une Exception) sur une image énorme.
        return try {
            val file = File(imagePath)
            if (!file.exists() || !file.canRead()) {
                Log.w(TAG, "buildImagePart: file unreadable")
                return null
            }
            // Garde-fou avant de tout charger en RAM : refuse un fichier
            // déraisonnablement gros plutôt que de risquer un OOM sur readBytes.
            if (file.length() > MAX_IMAGE_SOURCE_BYTES) {
                Log.w(TAG, "buildImagePart: source too large (${file.length()} B), downscaling from file")
                val bytes = decodeAndCompressFromFile(file) ?: return null
                return MmsPduComposer.Part(
                    contentType = "image/jpeg",
                    contentId = "<image_0>",
                    contentLocation = "image_0.jpg",
                    data = bytes,
                )
            }
            val raw = file.readBytes()
            val (bytes, mime, ext) = compressImageIfNeeded(raw)
            MmsPduComposer.Part(
                contentType = mime,
                contentId = "<image_0>",
                contentLocation = "image_0.$ext",
                data = bytes,
            )
        } catch (e: Throwable) {
            Log.w(TAG, "buildImagePart failed: ${e.message}")
            null
        }
    }

    /**
     * Décode une image directement depuis le fichier (sans readBytes en RAM),
     * sous-échantillonnée et ré-encodée en JPEG sous [MAX_IMAGE_BYTES]. Utilisé
     * pour les sources trop grosses pour être chargées entières.
     */
    private fun decodeAndCompressFromFile(file: File): ByteArray? {
        return try {
            val probe = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, probe)
            val sample = calcInSampleSize(probe.outWidth, probe.outHeight, MAX_IMAGE_W, MAX_IMAGE_H)
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bm = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return null
            val out = ByteArrayOutputStream()
            var q = 80
            do {
                out.reset()
                bm.compress(Bitmap.CompressFormat.JPEG, q, out)
                q -= 10
            } while (out.size() > MAX_IMAGE_BYTES && q >= 30)
            bm.recycle()
            out.toByteArray()
        } catch (e: Throwable) {
            Log.w(TAG, "decodeAndCompressFromFile failed: ${e.message}")
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

    /** Échappe les caractères dangereux dans une valeur d'attribut XML. */
    private fun xmlAttr(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")

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
            // contentLocation est aujourd'hui une constante interne, mais on
            // échappe l'attribut XML par principe (défense en profondeur contre
            // une future source dérivée d'un nom de fichier utilisateur).
            sb.append("<$tag src=\"${xmlAttr(p.contentLocation)}\" region=\"$region\"/>\n")
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

    /**
     * Passe READ=1 et SEEN=1 sur tous les SMS **et MMS** non lus du thread.
     * Auparavant seuls les SMS étaient marqués → un thread MMS-only/mixte
     * gardait un badge non-lu impossible à effacer.
     * @return nb total de lignes mises à jour (SMS + MMS).
     */
    suspend fun markRead(context: Context, threadId: Long): Int =
        withContext(Dispatchers.IO) {
            if (threadId <= 0L) return@withContext 0
            val resolver = context.contentResolver
            var updated = 0
            // SMS
            try {
                val smsValues = ContentValues().apply {
                    put(Telephony.Sms.READ, 1)
                    put(Telephony.Sms.SEEN, 1)
                }
                updated += resolver.update(
                    Telephony.Sms.CONTENT_URI,
                    smsValues,
                    "${Telephony.Sms.THREAD_ID}=? AND ${Telephony.Sms.READ}=0",
                    arrayOf(threadId.toString()),
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "markRead SMS($threadId): write denied (default app?): ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "markRead SMS($threadId) failed: ${e.message}")
            }
            // MMS (table séparée, sinon le badge non-lu MMS ne s'efface jamais)
            try {
                val mmsValues = ContentValues().apply {
                    put(Telephony.Mms.READ, 1)
                    put(Telephony.Mms.SEEN, 1)
                }
                updated += resolver.update(
                    Telephony.Mms.CONTENT_URI,
                    mmsValues,
                    "${Telephony.Mms.THREAD_ID}=? AND ${Telephony.Mms.READ}=0",
                    arrayOf(threadId.toString()),
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "markRead MMS($threadId): write denied: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "markRead MMS($threadId) failed: ${e.message}")
            }
            updated
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

    /** Nom + chemin local de la photo (thumbnail) d'un contact. */
    data class ContactInfo(val name: String?, val photoPath: String?)

    /** Variante publique pour les receivers (notifications). */
    fun lookupContact(context: Context, address: String): ContactInfo =
        resolveContact(context, address)

    /**
     * Liste les contacts ayant au moins un numéro, GROUPÉS par contact (un seul
     * item même si plusieurs numéros pro/perso). Best-effort : liste vide si
     * READ_CONTACTS refusé. Trié par nom.
     *
     * Chaque entrée : { name, photoPath?, numbers: [ { number, label } ] }.
     * `label` est humanisé (Mobile / Domicile / Travail / …).
     */
    suspend fun listContacts(context: Context): List<Map<String, Any?>> =
        withContext(Dispatchers.IO) {
            // contactId → (name, photoPath, ordered numbers)
            data class Acc(
                val name: String,
                var photoPath: String?,
                val numbers: ArrayList<Map<String, Any?>>,
                val seenNorm: HashSet<String>,
            )
            val byContact = LinkedHashMap<Long, Acc>()
            try {
                context.contentResolver.query(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    arrayOf(
                        ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                        ContactsContract.CommonDataKinds.Phone.NUMBER,
                        ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                        ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                        ContactsContract.CommonDataKinds.Phone.TYPE,
                        ContactsContract.CommonDataKinds.Phone.LABEL,
                    ),
                    null,
                    null,
                    "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC",
                )?.use { c ->
                    val nameIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    )
                    val numIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.NUMBER,
                    )
                    val photoIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                    )
                    val idIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                    )
                    val typeIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.TYPE,
                    )
                    val labelIdx = c.getColumnIndexOrThrow(
                        ContactsContract.CommonDataKinds.Phone.LABEL,
                    )
                    while (c.moveToNext()) {
                        val number = c.getString(numIdx) ?: continue
                        val norm = number.filter { it.isDigit() || it == '+' }
                        if (norm.isBlank()) continue
                        val contactId = c.getLong(idIdx)
                        val name = c.getString(nameIdx) ?: ""
                        val acc = byContact.getOrPut(contactId) {
                            Acc(name, null, ArrayList(), HashSet())
                        }
                        if (!acc.seenNorm.add(norm)) continue // dup number
                        if (acc.photoPath == null) {
                            acc.photoPath = cacheContactPhoto(
                                context, contactId, c.getString(photoIdx),
                            )
                        }
                        val type = c.getInt(typeIdx)
                        val label = phoneTypeLabel(type, c.getString(labelIdx))
                        acc.numbers += mapOf("number" to number, "label" to label)
                    }
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "listContacts: READ_CONTACTS denied")
            } catch (e: Exception) {
                Log.w(TAG, "listContacts failed: ${e.message}")
            }
            byContact.values.map { acc ->
                mapOf(
                    "name" to acc.name,
                    "photoPath" to acc.photoPath,
                    "numbers" to acc.numbers,
                )
            }
        }

    /** Humanise le TYPE d'un numéro de téléphone (Mobile, Domicile, …). */
    private fun phoneTypeLabel(type: Int, custom: String?): String = when (type) {
        ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE -> "Mobile"
        ContactsContract.CommonDataKinds.Phone.TYPE_HOME -> "Domicile"
        ContactsContract.CommonDataKinds.Phone.TYPE_WORK -> "Travail"
        ContactsContract.CommonDataKinds.Phone.TYPE_MAIN -> "Principal"
        ContactsContract.CommonDataKinds.Phone.TYPE_WORK_MOBILE -> "Mobile pro"
        ContactsContract.CommonDataKinds.Phone.TYPE_FAX_HOME -> "Fax domicile"
        ContactsContract.CommonDataKinds.Phone.TYPE_FAX_WORK -> "Fax pro"
        ContactsContract.CommonDataKinds.Phone.TYPE_OTHER -> "Autre"
        ContactsContract.CommonDataKinds.Phone.TYPE_CUSTOM ->
            custom?.takeIf { it.isNotBlank() } ?: "Autre"
        else -> "Téléphone"
    }

    /**
     * Résout le nom ET la photo de contact pour un numéro. Best-effort : si
     * READ_CONTACTS n'est pas accordé (ou indisponible sur GrapheneOS profil
     * sans contacts), renvoie ContactInfo(null, null) sans planter.
     *
     * La photo (PHOTO_THUMBNAIL_URI = content://) n'est pas lisible par Flutter
     * directement, donc on extrait les bytes vers un fichier cache et on renvoie
     * son path (réutilisé tant que le fichier existe).
     */
    private fun resolveContact(context: Context, address: String): ContactInfo {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(address),
            )
            context.contentResolver.query(
                uri,
                arrayOf(
                    ContactsContract.PhoneLookup.DISPLAY_NAME,
                    ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI,
                    ContactsContract.PhoneLookup._ID,
                ),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val name = c.getString(0)?.takeIf { it.isNotBlank() }
                    val photoUri = c.getString(1)?.takeIf { it.isNotBlank() }
                    val contactId = c.getLong(2)
                    ContactInfo(
                        name = name,
                        photoPath = cacheContactPhoto(context, contactId, photoUri),
                    )
                } else {
                    ContactInfo(null, null)
                }
            } ?: ContactInfo(null, null)
        } catch (e: SecurityException) {
            ContactInfo(null, null) // READ_CONTACTS non accordé — non bloquant
        } catch (e: Exception) {
            Log.w(TAG, "resolveContact failed: ${e.message}")
            ContactInfo(null, null)
        }
    }

    /**
     * Extrait le thumbnail d'un contact vers cacheDir/contact_photos/<id>.jpg et
     * renvoie le path. Idempotent (réutilise le fichier s'il existe). Null si pas
     * de photo ou en cas d'erreur.
     */
    private fun cacheContactPhoto(context: Context, contactId: Long, photoUri: String?): String? {
        if (photoUri.isNullOrBlank()) return null
        return try {
            val dir = File(context.cacheDir, "contact_photos").apply { mkdirs() }
            val out = File(dir, "$contactId.jpg")
            if (out.exists() && out.length() > 0) return out.absolutePath
            context.contentResolver.openInputStream(Uri.parse(photoUri))?.use { input ->
                out.outputStream().use { input.copyTo(it) }
            }
            if (out.exists() && out.length() > 0) out.absolutePath else null
        } catch (e: Exception) {
            Log.w(TAG, "cacheContactPhoto($contactId) failed: ${e.message}")
            null
        }
    }

    // ── Réception MMS (download du corps quand VOX est app par défaut) ─────────

    /**
     * Télécharge le corps d'un MMS entrant depuis le MMSC, à partir de la
     * content-location extraite du PDU de notification. Le système écrit le
     * m-retrieve-conf brut dans [downloadFile] ; on le parse au callback
     * [MmsDownloadedReceiver] pour insérer la ligne + les parts dans
     * content://mms, puis on notifie Dart.
     *
     * [onDone] est invoqué quand la requête a été soumise (pas quand le download
     * finit) — il sert juste à libérer le goAsync() du receiver.
     */
    fun downloadIncomingMms(
        context: Context,
        notif: MmsNotificationParser.Notification,
        onDone: () -> Unit,
    ) {
        try {
            val location = notif.contentLocation
            if (location.isNullOrBlank()) {
                Log.e(TAG, "downloadIncomingMms: pas de content-location, abandon")
                onDone()
                return
            }
            // Defense-in-depth : ne déclenche le download que sur un scheme
            // http(s). La content-location vient du WAP push (attaquant-influençable) ;
            // un scheme exotique (file:, content:) ne doit jamais atteindre le
            // framework de download.
            val locScheme = android.net.Uri.parse(location).scheme?.lowercase()
            if (locScheme != "http" && locScheme != "https") {
                Log.e(TAG, "downloadIncomingMms: scheme content-location non autorisé, abandon")
                onDone()
                return
            }
            val dir = File(context.cacheDir, "mms_in").apply { mkdirs() }
            val downloadFile = File(dir, "dl_${System.currentTimeMillis()}.pdu")
            // FileProvider-backed content URI the framework can write to.
            val contentUri = androidx.core.content.FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                downloadFile,
            )

            val sentIntent = Intent(ACTION_MMS_DOWNLOADED).apply {
                setClass(context, MmsDownloadedReceiver::class.java)
                putExtra(EXTRA_CONTENT_LOCATION, location)
                putExtra(EXTRA_FROM, notif.from)
                putExtra("download_path", downloadFile.absolutePath)
                putExtra(EXTRA_TXN_ID, notif.transactionId)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            val pi = PendingIntent.getBroadcast(
                context,
                location.hashCode(),
                sentIntent,
                flags,
            )

            val sms = smsManager(context)
            sms.downloadMultimediaMessage(
                context,
                location,
                contentUri,
                null,
                pi,
            )
            Log.i(TAG, "downloadMultimediaMessage soumis (loc ${location.length} c)")
        } catch (e: Exception) {
            Log.e(TAG, "downloadIncomingMms failed: ${e.message}")
        } finally {
            onDone()
        }
    }

    /** SmsManager pour la SIM par défaut (subId si dispo). */
    private fun smsManager(context: Context): SmsManager {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
    }

    /**
     * Appelé par [MmsDownloadedReceiver] quand le download du m-retrieve-conf est
     * terminé. Parse le PDU téléchargé et insère la ligne MMS + ses parts dans
     * content://mms (inbox), puis notifie Dart pour rafraîchir la conversation.
     */
    suspend fun ingestDownloadedMms(
        context: Context,
        pduPath: String,
        from: String?,
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            val file = File(pduPath)
            if (!file.exists() || file.length() == 0L) {
                Log.e(TAG, "ingestDownloadedMms: PDU vide/absent ($pduPath)")
                return@withContext false
            }
            // Plafond avant readBytes() : la taille = réponse HTTP de la
            // content-location (influençable). Sans borne, un PDU géant lèverait
            // OutOfMemoryError (un Error, NON rattrapé par le catch) → crash du
            // process de l'app SMS par défaut. 4 Mo >> un MMS réel (~300 Ko–1 Mo).
            if (file.length() > MAX_PDU_BYTES) {
                Log.e(TAG, "ingestDownloadedMms: PDU trop volumineux (${file.length()} o), abandon")
                file.delete()
                return@withContext false
            }
            val pdu = file.readBytes()
            val retrieved = MmsRetrieveParser.parse(pdu)
            if (retrieved == null) {
                Log.e(TAG, "ingestDownloadedMms: m-retrieve-conf illisible")
                return@withContext false
            }
            val sender = retrieved.from ?: from
            val (mmsId, threadId) = insertRetrievedMms(context, retrieved, sender)
            file.delete()
            if (mmsId > 0) {
                Log.i(TAG, "MMS entrant ingéré mmsId=$mmsId thread=$threadId")
                // Notifie Dart : un MMS est désormais lisible dans le provider.
                onMmsReceived?.invoke(
                    mapOf(
                        "mimeType" to "application/vnd.wap.mms-message",
                        "date" to System.currentTimeMillis(),
                        "from" to (sender ?: ""),
                    )
                )
                // Notification système (même chemin que les SMS). Snippet = texte
                // du MMS s'il y en a, sinon un libellé média.
                val cleanSender = sender?.substringBefore('/')?.trim()
                if (threadId > 0L && !cleanSender.isNullOrBlank()) {
                    runCatching {
                        val textPart = retrieved.parts
                            .firstOrNull { it.contentType.startsWith("text/") }
                            ?.let { String(it.data, Charsets.UTF_8).trim() }
                        val hasImage = retrieved.parts.any { it.contentType.startsWith("image/") }
                        val hasVideo = retrieved.parts.any { it.contentType.startsWith("video/") }
                        val snippet = when {
                            !textPart.isNullOrBlank() -> textPart
                            hasVideo -> "🎥 Vidéo"
                            hasImage -> "📷 Photo"
                            else -> "📎 Pièce jointe"
                        }
                        // Résout la 1re image du MMS vers un fichier cache pour la
                        // preview inline dans la notification.
                        var imagePath: String? = null
                        var imageMime: String? = null
                        val imgPartId = firstMmsImagePartId(context, mmsId)
                        if (imgPartId > 0) {
                            imagePath = loadMmsPart(context, imgPartId)
                            imageMime = mmsPartMime(context, imgPartId)
                        }
                        val info = lookupContact(context, cleanSender)
                        SmsNotifier.notifyIncoming(
                            context = context,
                            threadId = threadId,
                            address = cleanSender,
                            senderName = info.name?.takeIf { it.isNotBlank() } ?: cleanSender,
                            body = snippet,
                            photoPath = info.photoPath,
                            timestamp = System.currentTimeMillis(),
                            imagePath = imagePath,
                            imageMime = imageMime,
                        )
                    }
                }
                true
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "ingestDownloadedMms failed: ${e.message}")
            false
        }
    }

    /**
     * Insère un MMS reçu (m-retrieve-conf parsé) dans content://mms inbox + ses
     * parts dans content://mms/part. Retourne Pair(mmsId, threadId), ou (-1, 0).
     */
    private fun insertRetrievedMms(
        context: Context,
        msg: MmsRetrieveParser.Retrieved,
        sender: String?,
    ): Pair<Long, Long> {
        val resolver = context.contentResolver

        // 0. THREAD_ID : sans lui, le MMS appartient à aucune conversation et
        // n'apparaît nulle part (VOX charge par thread_id). On le dérive de
        // l'adresse de l'expéditeur — getOrCreateThreadId crée/retrouve le thread
        // exact de ce numéro, le même que celui affiché pour ses SMS.
        val cleanSender = sender?.substringBefore('/')?.trim() // strip "/TYPE=PLMN"
        val threadId = if (!cleanSender.isNullOrBlank()) {
            try {
                Telephony.Threads.getOrCreateThreadId(context, cleanSender)
            } catch (e: Exception) {
                Log.w(TAG, "insertRetrievedMms: getOrCreateThreadId échoué: ${e.message}")
                0L
            }
        } else {
            0L
        }

        // 1. Ligne MMS dans l'inbox.
        val values = ContentValues().apply {
            put(Telephony.Mms.MESSAGE_TYPE, 132) // m-retrieve-conf
            put(Telephony.Mms.MESSAGE_BOX, Telephony.Mms.MESSAGE_BOX_INBOX)
            put(Telephony.Mms.DATE, System.currentTimeMillis() / 1000)
            put(Telephony.Mms.READ, 0)
            put(Telephony.Mms.SEEN, 0)
            put(Telephony.Mms.SUBSCRIPTION_ID, defaultSubId(context))
            if (threadId > 0L) put(Telephony.Mms.THREAD_ID, threadId)
            msg.transactionId?.let { put(Telephony.Mms.TRANSACTION_ID, it) }
            msg.messageId?.let { put(Telephony.Mms.MESSAGE_ID, it) }
            put(Telephony.Mms.MMS_VERSION, 0x12)
        }
        val mmsUri = resolver.insert(Uri.parse("content://mms/inbox"), values)
            ?: return -1L to 0L
        val mmsId = ContentUris.parseId(mmsUri)

        // 2. Parts — follows AOSP PduPersister.persistPart exactly (the way
        // QKSMS/Signal do it). The crucial bit: DO NOT put MSG_ID in the insert
        // values (the .../part URI already carries the message id) and DO NOT
        // put TEXT for text parts at insert time. Putting MSG_ID in the values
        // is what made the provider skip allocating the blob `_data` file, so
        // openOutputStream then failed with "Column _data not found". For text
        // we set TEXT via a follow-up update; for media we stream the bytes via
        // openOutputStream on the returned part URI.
        val partsUri = mmsUri.buildUpon().appendPath("part").build()
        for ((index, part) in msg.parts.withIndex()) {
            val contentType = part.contentType.substringBefore(';').trim()
            // text parts AND application/smil are stored in the TEXT column,
            // never as a binary blob (SMIL is the presentation layout, not a
            // displayable attachment — trying to openOutputStream it just logged
            // a spurious "_data not found").
            val isText = contentType.startsWith("text/") ||
                contentType == "application/smil"
            val partValues = ContentValues().apply {
                put(Telephony.Mms.Part.CHARSET, 106) // UTF-8
                put(Telephony.Mms.Part.CONTENT_TYPE, contentType)
                put(Telephony.Mms.Part.NAME, part.name)
                put(Telephony.Mms.Part.FILENAME, part.name)
                put(Telephony.Mms.Part.CONTENT_ID, "<${part.name}>")
                put(Telephony.Mms.Part.CONTENT_LOCATION, part.name)
                if (contentType == "application/smil") {
                    put(Telephony.Mms.Part.SEQ, -1)
                } else {
                    put(Telephony.Mms.Part.SEQ, index)
                }
            }
            val partUri = resolver.insert(partsUri, partValues)
            if (partUri == null) {
                Log.w(TAG, "insertRetrievedMms: insert part #$index échoué")
                continue
            }
            if (isText) {
                // Text body goes in the TEXT column via update (PduPersister does
                // the same — never at insert time).
                try {
                    resolver.update(
                        partUri,
                        ContentValues().apply {
                            put(
                                Telephony.Mms.Part.TEXT,
                                String(part.data, Charsets.UTF_8),
                            )
                        },
                        null,
                        null,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "insertRetrievedMms: update TEXT part #$index échoué: ${e.message}")
                }
            } else {
                // Media bytes. On stock AOSP openOutputStream(partUri) writes the
                // provider blob (this is what PduPersister/QKSMS do). GrapheneOS
                // hardens MmsProvider and can reject it with "Column _data not
                // found"; in that case we write the bytes to a file we own and
                // point the part's `_data` column at it.
                val partId = ContentUris.parseId(partUri)
                var wrote = false
                try {
                    resolver.openOutputStream(partUri)?.use { it.write(part.data) }
                    wrote = true
                    Log.i(TAG, "insertRetrievedMms: part #$index écrite via stream")
                } catch (e: Exception) {
                    Log.w(
                        TAG,
                        "insertRetrievedMms: stream part #$index échoué (${e.message}) → fallback _data",
                    )
                }
                if (!wrote) {
                    try {
                        val dir = File(context.filesDir, "mms_parts_in").apply { mkdirs() }
                        val blob = File(dir, "part_$partId${extensionForMime(contentType)}")
                        FileOutputStream(blob).use { it.write(part.data) }
                        val updated = resolver.update(
                            partUri,
                            ContentValues().apply { put("_data", blob.absolutePath) },
                            null,
                            null,
                        )
                        Log.i(
                            TAG,
                            "insertRetrievedMms: part #$index _data=${blob.absolutePath} (update=$updated)",
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "insertRetrievedMms: fallback _data #$index échoué: ${e.message}")
                    }
                }
            }
        }

        // 3. Adresse expéditeur (content://mms/<id>/addr).
        if (!sender.isNullOrBlank()) {
            val addrValues = ContentValues().apply {
                put("address", sender)
                put("type", 137) // FROM
                put("charset", 106) // UTF-8
                put("msg_id", mmsId)
            }
            try {
                resolver.insert(Uri.parse("content://mms/$mmsId/addr"), addrValues)
            } catch (e: Exception) {
                Log.w(TAG, "insertRetrievedMms: insert addr échoué: ${e.message}")
            }
        }
        return mmsId to threadId
    }

    private fun defaultSubId(context: Context): Int {
        return try {
            SubscriptionManager.getDefaultSmsSubscriptionId()
        } catch (e: Exception) {
            -1
        }
    }
}
