package chat.fluffy.fluffychat.sms

import android.util.Log

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

    fun parse(pdu: ByteArray): Retrieved? {
        return try {
            val c = Cursor(pdu)
            var from: String? = null
            var transactionId: String? = null
            var messageId: String? = null
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
                    FIELD_DATE -> c.skipLongInteger()
                    FIELD_SUBJECT -> c.readText()
                    else -> {
                        if (!c.tryConsumeUnknownValue()) break
                    }
                }
            }
            Retrieved(from, transactionId, messageId, parts)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MmsRetrieveParser.parse failed: ${e.message}")
            null
        }
    }

    private fun parseMultipart(c: Cursor): List<Part> {
        val out = ArrayList<Part>()
        if (!c.hasRemaining()) return out
        val count = c.readUintvar()
        for (i in 0 until count) {
            if (!c.hasRemaining()) break
            val headersLen = c.readUintvar()
            val dataLen = c.readUintvar()
            val headerStart = c.position()
            // First in the part headers is the content-type.
            val contentType = c.readContentType()
            var name = "part_$i"
            // Walk remaining part headers for Content-Location / name.
            while (c.position() < headerStart + headersLen && c.hasRemaining()) {
                val h = c.readByte()
                when (h) {
                    0x8E, 0xAE -> name = c.readText() // Content-Location / name param
                    0x85, 0x97 -> name = c.readText() // Content-ID variants
                    else -> {
                        // Skip an unknown part-header value, best-effort.
                        if (!c.tryConsumeUnknownValue()) break
                    }
                }
            }
            // Realign to the declared end of headers.
            c.seek(headerStart + headersLen)
            val data = c.readBytes(dataLen)
            out.add(Part(contentType.ifEmpty { "application/octet-stream" }, name, data))
        }
        return out
    }

    private class Cursor(private val data: ByteArray) {
        private var pos = 0

        fun hasRemaining() = pos < data.size
        fun position() = pos
        fun seek(p: Int) { pos = p.coerceIn(0, data.size) }

        fun peekByte(): Int = data[pos].toInt() and 0xFF

        fun readByte(): Int {
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
            val sb = StringBuilder()
            while (hasRemaining()) {
                val ch = data[pos].toInt() and 0xFF
                pos++
                if (ch == 0) break
                sb.append(ch.toChar())
            }
            return sb.toString()
        }

        fun readUintvar(): Int {
            var value = 0
            while (hasRemaining()) {
                val b = readByte()
                value = (value shl 7) or (b and 0x7F)
                if (b and 0x80 == 0) break
            }
            return value
        }

        fun skipLongInteger() {
            val first = peekByte()
            if (first >= 0x80) { pos++; return }
            val len = readByte()
            pos = (pos + len).coerceAtMost(data.size)
        }

        private fun readValueLength(): Int {
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
        fun readContentType(): String {
            if (!hasRemaining()) return ""
            val first = peekByte()
            return when {
                // Constrained-media: a text string.
                first >= 0x20 && first < 0x80 -> readText()
                // Well-known short integer media type.
                first >= 0x80 -> { pos++; wellKnownContentType(first and 0x7F) }
                // Value-length prefixed (general form) — read length then the
                // media type (well-known byte or text), skip the rest (params).
                else -> {
                    val len = readValueLength()
                    val end = pos + len
                    val mt = if (hasRemaining()) {
                        val b = peekByte()
                        if (b >= 0x80) { pos++; wellKnownContentType(b and 0x7F) }
                        else readText()
                    } else ""
                    seek(end)
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
            0x03 -> "text/plain"
            0x1D -> "image/gif"
            0x1E -> "image/jpeg"
            0x20 -> "image/png"
            0x21 -> "application/vnd.wap.multipart.related"
            0x23 -> "application/vnd.wap.multipart.mixed"
            0x33 -> "audio/amr"
            else -> "application/octet-stream"
        }
    }
}
