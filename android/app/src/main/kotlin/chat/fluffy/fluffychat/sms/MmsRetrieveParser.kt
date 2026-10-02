package chat.fluffy.fluffychat.sms

import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Parser for an MMS **m-retrieve-conf** PDU (the actual downloaded message body).
 *
 * Structure: a run of MMS header fields, then `Content-Type` (multipart/related
 * or multipart/mixed) whose value is followed by the WSP multipart body — a
 * uintvar count, then that many entries of:
 *   [headers-len uintvar][data-len uintvar][content-type + headers][data].
 *
 * We extract `from`, `transaction-id`, `message-id`, and each body part's
 * content-type / name / bytes. Best-effort and guarded; carrier PDUs vary.
 */
object MmsRetrieveParser {

    data class Part(
        val contentType: String,
        val name: String,
        val data: ByteArray,
    )

    data class Retrieved(
        val from: String?,
        val transactionId: String?,
        val messageId: String?,
        val date: Long?,
        val parts: List<Part>,
    )

    private const val FIELD_CONTENT_TYPE = 0x84
    private const val FIELD_FROM = 0x89
    private const val FIELD_MESSAGE_ID = 0x8B
    private const val FIELD_MESSAGE_TYPE = 0x8C
    private const val FIELD_MMS_VERSION = 0x8D
    private const val FIELD_TRANSACTION_ID = 0x98
    private const val FIELD_DATE = 0x85
    private const val FIELD_SUBJECT = 0x96
    private const val FIELD_FROM_ADDRESS_PRESENT = 0x80

    // Plafond du nombre de parts d'un MMS : un message réel en a < 50. Borne
    // contre un `count` multipart forgé (uintvar) qui ferait exploser l'alloc.
    private const val MAX_PARTS = 1024

    // Longueur maximale d'un nom de part conservé pour l'affichage.
    private const val MAX_NAME_LEN = 64

    /**
     * Nettoie un nom de part MMS brut. Les en-têtes PDU bruts (Content-Location,
     * paramètres name/filename, Content-ID) sont souvent pollués : URL avec
     * `%20`, préfixes de chemin, chevrons `<…>`, guillemets et — quand un
     * Content-Disposition structuré est décodé à tort comme du texte — des
     * caractères de contrôle. On décode les %XX, on ne garde que le basename,
     * on retire ces caractères, on borne la longueur, et on retombe sur
     * [fallback] (ex. « part_3 ») si le résultat est vide.
     */
    fun sanitizeName(raw: String?, fallback: String): String {
        if (raw.isNullOrBlank()) return fallback
        var s = percentDecode(raw).trim()
        if (s.startsWith("cid:", ignoreCase = true)) s = s.substring(4)
        // Anti path-traversal résiduel : ne conserve que le nom de base.
        s = s.substringAfterLast('/').substringAfterLast('\\')
        val sb = StringBuilder(s.length)
        for (ch in s) {
            val code = ch.code
            if (code < 0x20 || code == 0x7F) continue
            when (ch) {
                '<', '>', '"', '\'', '|' -> Unit
                else -> sb.append(ch)
            }
        }
        s = sb.toString().trim().trim('.')
        if (s.isEmpty()) return fallback
        return if (s.length > MAX_NAME_LEN) s.substring(0, MAX_NAME_LEN) else s
    }

    /** Décodage trivial des séquences %XX (UTF-8), sans dépendance URLDecoder. */
    private fun percentDecode(s: String): String {
        if (!s.contains('%')) return s
        val out = ByteArrayOutputStream(s.length)
        var i = 0
        while (i < s.length) {
            val ch = s[i]
            if (ch == '%' && i + 2 < s.length) {
                val hi = Character.digit(s[i + 1], 16)
                val lo = Character.digit(s[i + 2], 16)
                if (hi >= 0 && lo >= 0) {
                    out.write((hi shl 4) or lo)
                    i += 3
                    continue
                }
            }
            out.write(ch.toString().toByteArray(Charsets.UTF_8))
            i++
        }
        return out.toString("UTF-8")
    }

    fun parse(pdu: ByteArray): Retrieved? {
        return try {
            val c = Cursor(pdu)
            var from: String? = null
            var transactionId: String? = null
            var messageId: String? = null
            var date: Long? = null
            var parts: List<Part> = emptyList()

            while (c.hasRemaining()) {
                val field = c.peekByte()
                if (field == FIELD_CONTENT_TYPE) {
                    c.readByte() // consume field id
                    // Content-Type value, then the multipart body follows.
                    c.skipContentTypeValue()
                    parts = parseMultipart(c)
                    break
                }
                c.readByte() // consume field id
                when (field) {
                    FIELD_FROM -> from = c.readFromValue()
                    FIELD_TRANSACTION_ID -> transactionId = c.readText()
                    FIELD_MESSAGE_ID -> messageId = c.readText()
                    FIELD_MESSAGE_TYPE, FIELD_MMS_VERSION -> c.readByte()
                    // FIELD_DATE = X-Mms-Date (0x85), epoch SECONDES. On le conserve
                    // pour ne pas dater un MMS entrant à l'heure du download.
                    FIELD_DATE -> date = c.readLongInteger()
                    FIELD_SUBJECT -> c.readText()
                    else -> {
                        if (!c.tryConsumeUnknownValue()) break
                    }
                }
            }
            Retrieved(from, transactionId, messageId, date, parts)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MmsRetrieveParser.parse failed: ${e.message}")
            null
        }
    }

    private fun parseMultipart(c: Cursor): List<Part> {
        val out = ArrayList<Part>()
        if (!c.hasRemaining()) return out
        val count = c.readUintvar().coerceAtMost(MAX_PARTS)
        for (i in 0 until count) {
            if (!c.hasRemaining()) break
            val headersLen = c.readUintvar()
            val dataLen = c.readUintvar()
            val headerStart = c.position()
            val headerEnd = headerStart + headersLen
            // First in the part headers is the content-type. Its parameters may
            // carry the part name (0x85/0x97) / filename (0x98).
            val ctParams = HashMap<Int, String>()
            val contentType = c.readContentType(ctParams)
            var name: String? = ctParams[0x85] ?: ctParams[0x97]
            var fileName: String? = ctParams[0x98]
            var contentLocation: String? = null
            var contentId: String? = null
            // Walk remaining part headers. The name parameter is normally consumed
            // by readContentType, but some carriers emit it (or Content-Disposition)
            // as standalone headers — collect every candidate and sanitize at the end.
            while (c.position() < headerEnd && c.hasRemaining()) {
                val h = c.readByte()
                when (h) {
                    0x8E -> contentLocation = c.readText() // Content-Location
                    0x85, 0x97 -> name = c.readText() // name / filename parameter
                    0x98 -> fileName = c.readText() // Content-Disposition: filename
                    0xC0 -> contentId = c.readText() // Content-ID (quoted-string)
                    0xAE, 0xC5 -> readContentDisposition(c, headerEnd)?.let { fileName = it }
                    else -> {
                        // Skip an unknown part-header value, best-effort.
                        if (!c.tryConsumeUnknownValue()) break
                    }
                }
            }
            // Realign to the declared end of headers.
            c.seek(headerEnd)
            val data = c.readBytes(dataLen)
            // Priorité AOSP : name > filename > Content-Location > Content-ID.
            val rawName = name ?: fileName ?: contentLocation ?: contentId
            val partName = sanitizeName(rawName, "part_$i")
            out.add(Part(contentType.ifEmpty { "application/octet-stream" }, partName, data))
        }
        return out
    }

    /**
     * Consomme un Content-Disposition = Value-length Disposition *(Parameter) et
     * renvoie le paramètre `filename` (0x98) s'il est présent. Borné par [partEnd] :
     * un PDU malformé ne peut pas déborder de la part. Un misstep éventuel est
     * rattrapé par le realign `seek(headerEnd)` de l'appelant.
     */
    private fun readContentDisposition(c: Cursor, partEnd: Int): String? {
        val len = c.readValueLength()
        if (len <= 0) return null
        val end = (c.position() + len).coerceAtMost(partEnd)
        if (!c.hasRemaining()) return null
        // Disposition = Form-data(0x80) | Attachment(0x81) | Inline(0x82) | Token-text
        val disp = c.peekByte()
        if (disp in 0x80..0x82) c.readByte() else c.readText()
        var filename: String? = null
        while (c.position() < end && c.hasRemaining()) {
            val param = c.readByte()
            if (param == 0x98) filename = c.readText() else c.readText()
        }
        c.seek(end)
        return filename
    }

    private class Cursor(private val data: ByteArray) {
        private var pos = 0

        fun hasRemaining() = pos < data.size
        fun position() = pos
        fun seek(p: Int) { pos = p.coerceIn(0, data.size) }

        fun peekByte(): Int {
            if (pos >= data.size) throw IndexOutOfBoundsException("PDU tronqué")
            return data[pos].toInt() and 0xFF
        }

        fun readByte(): Int {
            // Borne explicite : un m-retrieve-conf tronqué ne doit pas déréférencer
            // hors buffer. L'exception est rattrapée par parse().
            if (pos >= data.size) throw IndexOutOfBoundsException("PDU tronqué")
            val b = data[pos].toInt() and 0xFF
            pos++
            return b
        }

        fun readBytes(len: Int): ByteArray {
            val end = (pos + len).coerceAtMost(data.size)
            val out = data.copyOfRange(pos, end)
            pos = end
            return out
        }

        fun readText(): String {
            if (hasRemaining() && (peekByte() == 0x22 || peekByte() == 0x7F)) pos++
            // Décodage UTF-8 (toChar() octet par octet = Latin-1 = noms cassés).
            val bytes = ByteArrayOutputStream()
            while (hasRemaining()) {
                val ch = data[pos]
                pos++
                if (ch.toInt() == 0) break
                bytes.write(ch.toInt())
            }
            return bytes.toString("UTF-8")
        }

        fun readUintvar(): Int {
            var value = 0
            var n = 0
            // WSP uintvar = 5 octets max ; au-delà = PDU forgé → on coupe.
            while (hasRemaining() && n < 5) {
                val b = readByte()
                value = (value shl 7) or (b and 0x7F)
                n++
                if (b and 0x80 == 0) break
            }
            return value
        }

        /** Short integer (high bit set) or long integer (length-prefixed) → Long. */
        fun readLongInteger(): Long {
            val first = peekByte()
            if (first >= 0x80) { pos++; return (first and 0x7F).toLong() }
            val len = readByte()
            var value = 0L
            for (i in 0 until len) {
                if (pos >= data.size) break
                value = (value shl 8) or (readByte().toLong() and 0xFF)
            }
            return value
        }

        fun readValueLength(): Int {
            val first = peekByte()
            return when {
                first < 0x1F -> { pos++; first }
                first == 0x1F -> { pos++; readUintvar() }
                else -> 0
            }
        }

        fun readFromValue(): String? {
            val len = readValueLength()
            val end = pos + len
            if (!hasRemaining()) return null
            val token = readByte()
            val addr = if (token == FIELD_FROM_ADDRESS_PRESENT) readText() else null
            seek(end)
            return addr
        }

        /** Content-Type as a string, handling short well-known and text forms. */
        fun readContentType(params: MutableMap<Int, String>? = null): String {
            if (!hasRemaining()) return ""
            val first = peekByte()
            return when {
                // Constrained-media: a text string.
                first >= 0x20 && first < 0x80 -> readText()
                // Well-known short integer media type.
                first >= 0x80 -> { pos++; wellKnownContentType(first and 0x7F) }
                // Value-length prefixed (general form) — read length then the
                // media type (well-known byte or text) and any parameters
                // (name 0x85/0x97, filename…) so the multipart walk can use them.
                else -> {
                    val len = readValueLength()
                    val end = (pos + len).coerceAtMost(data.size)
                    val mt = if (hasRemaining()) {
                        val b = peekByte()
                        if (b >= 0x80) { pos++; wellKnownContentType(b and 0x7F) }
                        else readText()
                    } else ""
                    if (params == null) {
                        seek(end)
                    } else {
                        while (pos < end && hasRemaining()) {
                            val param = readByte()
                            when (param) {
                                0x85, 0x97, 0x98 -> params[param] = readText()
                                else -> readText()
                            }
                        }
                        seek(end)
                    }
                    mt
                }
            }
        }

        /** Top-level Content-Type value of the PDU (we only need to skip it). */
        fun skipContentTypeValue() {
            val first = peekByte()
            if (first >= 0x80) { pos++; return }
            if (first >= 0x20 && first < 0x80) { readText(); return }
            val len = readValueLength()
            pos = (pos + len).coerceAtMost(data.size)
        }

        fun tryConsumeUnknownValue(): Boolean {
            if (!hasRemaining()) return false
            val first = peekByte()
            when {
                first >= 0x80 -> pos++
                first < 0x1F -> { val l = readValueLength(); pos = (pos + l).coerceAtMost(data.size) }
                first == 0x1F -> { val l = readValueLength(); pos = (pos + l).coerceAtMost(data.size) }
                else -> readText()
            }
            return true
        }

        private fun wellKnownContentType(code: Int): String = when (code) {
            0x00 -> "*/*"
            0x01 -> "text/*"
            0x02 -> "text/html"
            0x03 -> "text/plain"
            0x06 -> "text/x-vCalendar"
            0x07 -> "text/x-vCard"
            0x0B -> "multipart/*"
            0x0C -> "multipart/mixed"
            0x0D -> "multipart/form-data"
            0x0F -> "multipart/alternative"
            0x10 -> "application/*"
            0x1C -> "image/*"
            0x1D -> "image/gif"
            0x1E -> "image/jpeg"
            0x1F -> "image/tiff"
            0x20 -> "image/png"
            0x21 -> "image/vnd.wap.wbmp"
            0x22 -> "application/vnd.wap.multipart.*"
            0x23 -> "application/vnd.wap.multipart.mixed"
            0x24 -> "application/vnd.wap.multipart.form-data"
            0x25 -> "application/vnd.wap.multipart.byteranges"
            0x26 -> "application/vnd.wap.multipart.alternative"
            0x27 -> "application/xml"
            0x28 -> "text/xml"
            0x33 -> "application/vnd.wap.multipart.related"
            0x3E -> "application/vnd.wap.mms-message"
            0x4F -> "audio/*"
            0x50 -> "video/*"
            else -> "application/octet-stream"
        }
    }
}
