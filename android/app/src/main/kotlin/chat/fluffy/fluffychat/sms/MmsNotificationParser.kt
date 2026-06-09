package chat.fluffy.fluffychat.sms

import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Minimal parser for an MMS **M-Notification.ind** PDU (the body of a WAP push
 * that tells us "an MMS is waiting on the MMSC"). We only need a few fields to
 * trigger a download via `SmsManager.downloadMultimediaMessage`:
 *
 *  - X-Mms-Content-Location (0x83) : the URL to fetch the m-retrieve-conf from.
 *  - X-Mms-Transaction-Id   (0x98) : echoed back so the MMSC matches the fetch.
 *  - From                    (0x89) : sender address (best-effort, for the notif).
 *  - X-Mms-Message-Size      (0x8E) : payload size (best-effort).
 *
 * This is a deliberately small WSP/MMS field walker — it skips fields it doesn't
 * care about by their value type rather than fully decoding them. Based on the
 * MMS Encapsulation spec (WAP-209) field assignments. Carrier PDUs vary, so
 * everything is best-effort and guarded; a parse miss returns nulls rather than
 * throwing.
 */
object MmsNotificationParser {

    data class Notification(
        val contentLocation: String?,
        val transactionId: String?,
        val from: String?,
        val messageSize: Long,
    )

    // MMS header field codes (with the high bit set as they appear on the wire).
    private const val FIELD_BCC = 0x81
    private const val FIELD_CC = 0x82
    private const val FIELD_CONTENT_LOCATION = 0x83
    private const val FIELD_CONTENT_TYPE = 0x84
    private const val FIELD_DATE = 0x85
    private const val FIELD_DELIVERY_REPORT = 0x86
    private const val FIELD_DELIVERY_TIME = 0x87
    private const val FIELD_EXPIRY = 0x88
    private const val FIELD_FROM = 0x89
    private const val FIELD_MESSAGE_CLASS = 0x8A
    private const val FIELD_MESSAGE_ID = 0x8B
    private const val FIELD_MESSAGE_TYPE = 0x8C
    private const val FIELD_MMS_VERSION = 0x8D
    private const val FIELD_MESSAGE_SIZE = 0x8E
    private const val FIELD_PRIORITY = 0x8F
    private const val FIELD_READ_REPLY = 0x90
    private const val FIELD_REPORT_ALLOWED = 0x91
    private const val FIELD_RESPONSE_STATUS = 0x92
    private const val FIELD_RESPONSE_TEXT = 0x93
    private const val FIELD_SENDER_VISIBILITY = 0x94
    private const val FIELD_STATUS = 0x95
    private const val FIELD_SUBJECT = 0x96
    private const val FIELD_TO = 0x97
    private const val FIELD_TRANSACTION_ID = 0x98

    private const val FROM_ADDRESS_PRESENT = 0x80
    private const val FROM_INSERT_ADDRESS = 0x81

    fun parse(data: ByteArray): Notification? {
        return try {
            val p = Cursor(data)
            var contentLocation: String? = null
            var transactionId: String? = null
            var from: String? = null
            var messageSize = 0L

            while (p.hasRemaining()) {
                val field = p.readByte()
                when (field) {
                    FIELD_CONTENT_LOCATION -> contentLocation = p.readText()
                    FIELD_TRANSACTION_ID -> transactionId = p.readText()
                    FIELD_MESSAGE_TYPE -> p.readByte() // m-notification-ind = 0x82
                    FIELD_MMS_VERSION -> p.readByte()
                    FIELD_MESSAGE_CLASS -> p.readByte()
                    FIELD_MESSAGE_ID -> p.readText()
                    FIELD_MESSAGE_SIZE -> messageSize = p.readLongInteger()
                    FIELD_EXPIRY, FIELD_DATE, FIELD_DELIVERY_TIME ->
                        p.skipValueLengthValue()
                    FIELD_FROM -> from = p.readFromValue()
                    FIELD_SUBJECT -> p.readText()
                    FIELD_PRIORITY, FIELD_DELIVERY_REPORT, FIELD_READ_REPLY,
                    FIELD_REPORT_ALLOWED, FIELD_RESPONSE_STATUS, FIELD_STATUS,
                    FIELD_SENDER_VISIBILITY -> p.readByte()
                    FIELD_RESPONSE_TEXT -> p.readText()
                    FIELD_CONTENT_TYPE -> {
                        // Content-type is last in well-formed PDUs; we don't need
                        // the body for a notification — stop here.
                        break
                    }
                    else -> {
                        // Unknown / not needed: try to consume a text value so we
                        // stay aligned. If the value isn't text-like this may
                        // mis-align, hence the overall try/catch.
                        if (!p.tryConsumeUnknownValue()) break
                    }
                }
            }

            if (contentLocation == null && transactionId == null) {
                Log.w(SmsBridge.TAG, "MmsNotificationParser: no content-location/transaction-id")
            }
            Notification(contentLocation, transactionId, from, messageSize)
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MmsNotificationParser.parse failed: ${e.message}")
            null
        }
    }

    /** Tiny byte cursor over the PDU with WSP primitive decoders. */
    private class Cursor(private val data: ByteArray) {
        private var pos = 0

        fun hasRemaining() = pos < data.size

        /** Reads the next octet as an unsigned 0..255 int. */
        fun readByte(): Int {
            // Borne explicite : un PDU tronqué (input attaquant) ne doit jamais
            // déréférencer hors buffer. L'exception est rattrapée par parse().
            if (pos >= data.size) throw IndexOutOfBoundsException("PDU tronqué")
            val b = data[pos].toInt() and 0xFF
            pos++
            return b
        }

        private fun peek(): Int {
            if (pos >= data.size) throw IndexOutOfBoundsException("PDU tronqué")
            return data[pos].toInt() and 0xFF
        }

        /** Null-terminated text-string (skips a leading 0x7F/quote if present). */
        fun readText(): String {
            // A text value may be prefixed by a quote (0x22) or 0x7F per WSP; skip.
            if (hasRemaining() && (peek() == 0x22 || peek() == 0x7F || peek() == 0x80)) {
                pos++
            }
            // Accumule les octets puis décode en UTF-8 (toChar() octet par octet
            // donnerait du Latin-1 et casserait les noms/URLs non-ASCII).
            val bytes = ByteArrayOutputStream()
            while (hasRemaining()) {
                val c = data[pos]
                pos++
                if (c.toInt() == 0) break
                bytes.write(c.toInt())
            }
            return bytes.toString("UTF-8")
        }

        /** Short integer (high bit set) or long integer (length-prefixed). */
        fun readLongInteger(): Long {
            val first = peek()
            if (first >= 0x80) {
                // Short integer: value is in the low 7 bits.
                pos++
                return (first and 0x7F).toLong()
            }
            // Long integer: first byte is the length, then that many octets.
            val len = readByte() and 0xFF
            var value = 0L
            for (i in 0 until len) {
                value = (value shl 8) or (readByte().toLong() and 0xFF)
            }
            return value
        }

        /** From-value: value-length, then either address-present or insert-address. */
        fun readFromValue(): String? {
            val len = readValueLength()
            val end = pos + len
            if (pos >= data.size) return null
            val token = data[pos].toInt() and 0xFF
            pos++
            return if (token == FROM_ADDRESS_PRESENT) {
                val addr = readText()
                pos = end.coerceAtMost(data.size)
                addr
            } else {
                pos = end.coerceAtMost(data.size)
                null
            }
        }

        /** Reads a WSP value-length (short-length or length-quote+uintvar). */
        private fun readValueLength(): Int {
            val first = peek()
            return if (first < 0x1F) {
                pos++
                first
            } else if (first == 0x1F) {
                pos++
                readUintvar()
            } else {
                0
            }
        }

        private fun readUintvar(): Int {
            var value = 0
            var n = 0
            // WSP uintvar = 5 octets max (32 bits utiles) ; au-delà = PDU forgé,
            // on s'arrête pour éviter un overflow Int silencieux.
            while (hasRemaining() && n < 5) {
                val b = readByte() and 0xFF
                value = (value shl 7) or (b and 0x7F)
                n++
                if (b and 0x80 == 0) break
            }
            return value
        }

        /** Skips a value introduced by a value-length. */
        fun skipValueLengthValue() {
            val len = readValueLength()
            pos = (pos + len).coerceAtMost(data.size)
        }

        /**
         * Best-effort consume of an unknown field value so parsing can continue.
         * Returns false if we can't safely advance (caller should stop).
         */
        fun tryConsumeUnknownValue(): Boolean {
            if (!hasRemaining()) return false
            val first = peek()
            when {
                first >= 0x80 -> pos++ // short integer
                first < 0x1F -> skipValueLengthValue()
                first == 0x1F -> skipValueLengthValue()
                else -> readText() // assume text-string
            }
            return true
        }
    }
}
