package chat.fluffy.fluffychat.sms

import android.net.Network
import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.net.HttpURLConnection
import java.util.Locale

/**
 * Direct HTTP POST of an MMS PDU to the carrier MMSC, bound to a specific
 * [Network] (the cellular MMS network). Mirrors AOSP / klinker41 android-smsmms
 * `MmsHttpClient`. We use this instead of `SmsManager.sendMultimediaMessage`
 * because that system API returns HTTP_FAILURE (code=5) on this device/carrier
 * combo (GrapheneOS + Orange + Wi-Fi calling) without ever reaching the MMSC.
 *
 * By opening the connection ON the MMS [Network] we force the request through
 * the cellular MMS bearer even while Wi-Fi calling is the preferred data path.
 */
object MmsHttpClient {

    // A generic UA accepted by most MMSCs. Orange doesn't gate on it.
    private const val USER_AGENT = "Android-Mms/2.0"
    private const val UA_PROF_URL =
        "http://www.gsmarena.com/Android.xml"

    /**
     * Extracts X-Mms-Response-Status (field 0x92) from an m-send-conf PDU.
     * 0x80 = Ok; anything else is a carrier-side rejection (the MMS won't be
     * delivered even though the HTTP POST returned 200). Returns a human label.
     */
    /**
     * Reads the human-readable Response-Text (field 0x93) from an m-send-conf —
     * e.g. "1000:OK" (accepted) or "2511:Message too large" (rejected). This is
     * the most reliable signal across carriers; the binary Response-Status field
     * encoding varies. Returns the text, or "unknown".
     */
    fun parseResponseStatus(pdu: ByteArray): String {
        // Field 0x93 = X-Mms-Response-Text, a null-terminated text-string.
        var i = 0
        while (i < pdu.size - 1) {
            if ((pdu[i].toInt() and 0xFF) == 0x93) {
                val sb = StringBuilder()
                var j = i + 1
                while (j < pdu.size) {
                    val ch = pdu[j].toInt() and 0xFF
                    if (ch == 0) break
                    if (ch in 0x20..0x7E) sb.append(ch.toChar())
                    j++
                }
                if (sb.isNotEmpty()) return sb.toString()
            }
            i++
        }
        return "unknown"
    }

    /** True if the m-send-conf indicates the MMSC ACCEPTED the message. */
    fun isAccepted(pdu: ByteArray): Boolean {
        val text = parseResponseStatus(pdu).lowercase()
        // Accepted responses are "1000:OK" / "Ok"; anything else (2xxx error
        // codes, "too large", "denied"…) is a rejection even on HTTP 200.
        return text.contains("1000") || text == "ok" || text.endsWith(":ok")
    }

    /**
     * Blocks loopback and link-local hosts (cloud-metadata SSRF vector). NB: we
     * deliberately allow RFC1918 private ranges — carrier MMS proxies are private
     * (Orange = 192.168.10.200), so blocking them would break legitimate MMS.
     */
    private fun isBlockedHost(host: String?): Boolean {
        if (host.isNullOrBlank()) return true
        val h = host.lowercase()
        return h == "localhost" ||
            h.startsWith("127.") ||
            h.startsWith("169.254.") || // link-local / cloud metadata
            h == "::1" ||
            h == "0.0.0.0"
    }

    /**
     * POSTs [pdu] (an m-send-req) to [mmscUrl] over [network], optionally through
     * [proxyHost]:[proxyPort]. Returns the response bytes (m-send-conf) on a 2xx,
     * or null on any failure.
     */
    fun postPdu(
        mmscUrl: String,
        proxyHost: String?,
        proxyPort: Int,
        pdu: ByteArray,
    ): ByteArray? {
        // Defense-in-depth: the MMSC URL comes from the system APN (carrier
        // config), but a stale/injected APN could point the POST at an internal
        // address (cloud metadata 169.254.169.254, loopback…). Validate scheme +
        // host before sending the PDU (which contains the message body).
        val url = runCatching { URL(mmscUrl) }.getOrNull()
        if (url == null || url.protocol !in listOf("http", "https")) {
            Log.e(SmsBridge.TAG, "MmsHttpClient: schéma MMSC invalide: $mmscUrl")
            return null
        }
        if (isBlockedHost(url.host)) {
            Log.e(SmsBridge.TAG, "MmsHttpClient: hôte MMSC bloqué (loopback/link-local): ${url.host}")
            return null
        }
        if (!proxyHost.isNullOrBlank() && isBlockedHost(proxyHost)) {
            Log.e(SmsBridge.TAG, "MmsHttpClient: proxy bloqué: $proxyHost")
            return null
        }

        var connection: HttpURLConnection? = null
        return try {
            val useProxy = !proxyHost.isNullOrBlank() && proxyPort > 0
            // The CALLER has already bound this process to the MMS network
            // (ConnectivityManager.bindProcessToNetwork) while serialized, so a
            // plain url.openConnection() goes out over cellular MMS. We avoid
            // network.openConnection() here because its implicit per-socket bind
            // raced into "Binding socket to network failed: EPERM" on back-to-back
            // sends. Proxy is applied explicitly when the APN defines one.
            connection = if (useProxy) {
                val proxy = Proxy(
                    Proxy.Type.HTTP,
                    InetSocketAddress(proxyHost, proxyPort),
                )
                url.openConnection(proxy) as HttpURLConnection
            } else {
                url.openConnection() as HttpURLConnection
            }

            connection.apply {
                doInput = true
                doOutput = true
                requestMethod = "POST"
                connectTimeout = 30_000
                readTimeout = 30_000
                setRequestProperty(
                    "Content-Type",
                    "application/vnd.wap.mms-message",
                )
                setRequestProperty(
                    "Accept",
                    "*/*, application/vnd.wap.mms-message, application/vnd.wap.sic",
                )
                val locale = Locale.getDefault()
                setRequestProperty(
                    "Accept-Language",
                    "${locale.language}-${locale.country}, ${locale.language}",
                )
                setRequestProperty("User-Agent", USER_AGENT)
                setRequestProperty("x-wap-profile", UA_PROF_URL)
                setFixedLengthStreamingMode(pdu.size)
            }

            BufferedOutputStream(connection.outputStream).use { out ->
                out.write(pdu)
                out.flush()
            }

            val code = connection.responseCode
            if (code / 100 != 2) {
                Log.e(SmsBridge.TAG, "MmsHttpClient: MMSC répond HTTP $code")
                return null
            }
            val body = BufferedInputStream(connection.inputStream).use { input ->
                val buf = ByteArrayOutputStream()
                val chunk = ByteArray(4096)
                while (true) {
                    val n = input.read(chunk)
                    if (n <= 0) break
                    buf.write(chunk, 0, n)
                }
                buf.toByteArray()
            }
            // HTTP 200 only means the MMSC accepted the REQUEST; the MMS itself
            // can still be rejected (e.g. "2511:Message too large"). Parse the
            // response-text and only treat an accepted PDU as success.
            val status = parseResponseStatus(body)
            val accepted = isAccepted(body)
            if (!accepted) {
                val hex = body.joinToString(" ") { "%02X".format(it) }
                Log.e(
                    SmsBridge.TAG,
                    "MmsHttpClient: MMS REJETÉ par le MMSC: \"$status\" (HTTP $code) m-send-conf=[$hex]",
                )
                return null
            }
            Log.i(
                SmsBridge.TAG,
                "MmsHttpClient: MMS accepté \"$status\" (HTTP $code, ${body.size} o)",
            )
            body
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MmsHttpClient.postPdu failed: ${e.message}")
            null
        } finally {
            connection?.disconnect()
        }
    }
}
