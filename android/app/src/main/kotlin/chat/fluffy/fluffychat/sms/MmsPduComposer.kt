package chat.fluffy.fluffychat.sms

import java.io.ByteArrayOutputStream

/**
 * Encodeur minimal de PDU MMS `m-send-req` (OMA-MMS-ENC-V1_3 + WAP-230 WSP).
 *
 * Kotlin pur, ZÉRO dépendance externe (pas de com.google.android.mms). Adapté de
 * l'implémentation Beeper `com.beeper.sms.app.mms.PduComposer`.
 *
 * On encode uniquement ce dont [android.telephony.SmsManager.sendMultimediaMessage] a besoin
 * pour pousser un MMS sortant via le MMSC de l'opérateur :
 *  - X-Mms-Message-Type     = 128 (m-send-req)
 *  - X-Mms-Transaction-Id
 *  - X-Mms-MMS-Version      = 0x92 (v1.2)
 *  - From                   = insert-address-token
 *  - To                     = destinataire(s)
 *  - X-Mms-Message-Class    = Personal
 *  - X-Mms-Delivery-Report  = No
 *  - X-Mms-Read-Report      = No
 *  - Content-Type           = application/vnd.wap.multipart.related + start + type
 *  - body multipart (SMIL + médias)
 *
 * Pas de m-retrieve-conf, pas de notification, pas de read-orig-ind (on ENVOIE seulement).
 */
internal object MmsPduComposer {

    // ── Field codes (well-known short integers WSP, MSB set quand encodé). ────
    private const val FIELD_CONTENT_LOCATION = 0x03
    private const val FIELD_CONTENT_TYPE = 0x04
    private const val FIELD_DELIVERY_REPORT = 0x06
    private const val FIELD_FROM = 0x09
    private const val FIELD_MESSAGE_CLASS = 0x0A
    private const val FIELD_MESSAGE_TYPE = 0x0C
    private const val FIELD_MMS_VERSION = 0x0D
    private const val FIELD_READ_REPORT = 0x10
    private const val FIELD_TO = 0x17
    private const val FIELD_TRANSACTION_ID = 0x18

    private const val CT_APPLICATION_VND_WAP_MULTIPART_RELATED = 0x33

    private const val PARAM_TYPE = 0x09
    private const val PARAM_START = 0x0A
    private const val PARAM_NAME_STRING = 0x17

    private const val FROM_INSERT_ADDRESS_TOKEN = 0x81
    private const val MSG_CLASS_PERSONAL = 0x80
    private const val NO = 0x81

    private const val MSG_TYPE_SEND_REQ = 0x80
    private const val MMS_VERSION_1_2 = 0x92 // (1 << 4) | 2 = 0x12, short-int = 0x92.

    private const val CONTENT_ID_FIELD = 0x40 // WSP Content-ID assigned number.

    /**
     * Une partie multipart.
     * @param contentType MIME ("image/jpeg", "application/smil", "text/plain"…).
     * @param contentId   "<smil>" / "<part0.jpg>" — référencé par le SMIL.
     * @param contentLocation nom de fichier court (image.jpg) référencé par le SMIL.
     * @param data        bytes bruts (déjà compressés pour les images).
     */
    data class Part(
        val contentType: String,
        val contentId: String,
        val contentLocation: String,
        val data: ByteArray,
    )

    /**
     * Compose un m-send-req complet.
     *
     * @param transactionId identifiant opaque renvoyé tel quel au MMSC.
     * @param recipients    numéros MSISDN (e.g. "+33611593473").
     * @param smilPart      partie SMIL (présentation) — requise pour les MMSC stricts.
     * @param mediaParts    parties média (image/texte) référencées par le SMIL.
     */
    fun composeSendReq(
        transactionId: String,
        recipients: List<String>,
        smilPart: Part,
        mediaParts: List<Part>,
    ): ByteArray {
        require(recipients.isNotEmpty()) { "MMS requires at least one recipient" }
        val out = ByteArrayOutputStream()

        // -- Headers --
        writeShortField(out, FIELD_MESSAGE_TYPE, MSG_TYPE_SEND_REQ)
        writeTextField(out, FIELD_TRANSACTION_ID, transactionId)
        writeShortField(out, FIELD_MMS_VERSION, MMS_VERSION_1_2)

        // From : value-length + (insert-address-token).
        run {
            out.write(FIELD_FROM or 0x80)
            val body = ByteArrayOutputStream()
            body.write(FROM_INSERT_ADDRESS_TOKEN)
            writeValueLength(out, body.size().toLong())
            out.write(body.toByteArray())
        }

        // To : un header par destinataire (avec /TYPE=PLMN).
        for (rcpt in recipients) {
            writeTextField(out, FIELD_TO, encodeAddress(rcpt))
        }

        writeShortField(out, FIELD_MESSAGE_CLASS, MSG_CLASS_PERSONAL)
        writeShortField(out, FIELD_DELIVERY_REPORT, NO)
        writeShortField(out, FIELD_READ_REPORT, NO)

        // Content-Type: application/vnd.wap.multipart.related; type=application/smil; start=<smilId>
        run {
            out.write(FIELD_CONTENT_TYPE or 0x80)
            val ct = ByteArrayOutputStream()
            ct.write(CT_APPLICATION_VND_WAP_MULTIPART_RELATED or 0x80)
            ct.write(PARAM_TYPE or 0x80)
            writeNullTerminatedString(ct, "application/smil")
            ct.write(PARAM_START or 0x80)
            writeNullTerminatedString(ct, smilPart.contentId)
            val ctBytes = ct.toByteArray()
            writeValueLength(out, ctBytes.size.toLong())
            out.write(ctBytes)
        }

        // -- Body --
        out.write(encodeBody(listOf(smilPart) + mediaParts))
        return out.toByteArray()
    }

    private fun encodeBody(parts: List<Part>): ByteArray {
        val out = ByteArrayOutputStream()
        writeUintvar(out, parts.size.toLong())
        for (p in parts) {
            val headers = ByteArrayOutputStream()
            // Content-Type header (text-string + param name pour large compat).
            val ct = ByteArrayOutputStream()
            writeNullTerminatedString(ct, p.contentType)
            if (p.contentLocation.isNotEmpty()) {
                ct.write(PARAM_NAME_STRING or 0x80)
                writeNullTerminatedString(ct, p.contentLocation)
            }
            val ctBytes = ct.toByteArray()
            writeValueLength(headers, ctBytes.size.toLong())
            headers.write(ctBytes)

            // Content-Location header.
            writeTextField(headers, FIELD_CONTENT_LOCATION, p.contentLocation)
            // Content-ID header (quoted).
            val cid = if (p.contentId.startsWith("<")) p.contentId else "<${p.contentId}>"
            headers.write(CONTENT_ID_FIELD or 0x80)
            writeNullTerminatedString(headers, cid)

            val headersBytes = headers.toByteArray()
            writeUintvar(out, headersBytes.size.toLong())
            writeUintvar(out, p.data.size.toLong())
            out.write(headersBytes)
            out.write(p.data)
        }
        return out.toByteArray()
    }

    // ── Encodage WSP de base ─────────────────────────────────────────────────

    private fun writeShortField(out: ByteArrayOutputStream, field: Int, valueWithMsb: Int) {
        out.write(field or 0x80)
        out.write(valueWithMsb)
    }

    private fun writeTextField(out: ByteArrayOutputStream, field: Int, value: String) {
        out.write(field or 0x80)
        writeNullTerminatedString(out, value)
    }

    private fun writeNullTerminatedString(out: ByteArrayOutputStream, s: String) {
        val bytes = s.toByteArray(Charsets.UTF_8)
        if (bytes.isNotEmpty() && (bytes[0].toInt() and 0xFF) >= 0x80) {
            out.write(0x7F)
        }
        out.write(bytes)
        out.write(0x00)
    }

    private fun writeValueLength(out: ByteArrayOutputStream, len: Long) {
        if (len < 31) {
            out.write(len.toInt())
        } else {
            out.write(0x1F)
            writeUintvar(out, len)
        }
    }

    private fun writeUintvar(out: ByteArrayOutputStream, value: Long) {
        require(value >= 0) { "uintvar negative: $value" }
        val bytes = ArrayList<Int>(5)
        var v = value
        bytes.add((v and 0x7F).toInt())
        v = v shr 7
        while (v != 0L) {
            bytes.add(((v and 0x7F) or 0x80).toInt())
            v = v shr 7
        }
        bytes.reverse()
        for (i in bytes.indices) {
            val b = if (i < bytes.size - 1) bytes[i] or 0x80 else bytes[i] and 0x7F
            out.write(b)
        }
    }

    /** Format MSISDN attendu par les MMSC : "+33XXXXXXXXX/TYPE=PLMN". */
    private fun encodeAddress(raw: String): String {
        val trimmed = raw.trim()
        return if (trimmed.endsWith("/TYPE=PLMN", ignoreCase = true)) trimmed
        else "$trimmed/TYPE=PLMN"
    }
}
