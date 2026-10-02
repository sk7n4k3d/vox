package chat.fluffy.fluffychat.sms

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Suggestions de réponses SMS générées par le LLM de l'utilisateur.
 *
 * Lit les réglages posés côté Dart (endpoint OpenAI-compatible) directement
 * dans les SharedPreferences partagées avec Flutter :
 *   - chat.fluffy.llm_enabled (bool, défaut false)
 *   - chat.fluffy.llm_base_url (String, défaut https://llm.sk7.sh/v1)
 *   - chat.fluffy.llm_api_key (String, défaut vide)
 *   - chat.fluffy.llm_model (String, défaut qwen3.5-titan1-16x)
 *
 * [suggest] est bloquante et bornée (connect + read timeout) : elle est appelée
 * depuis [SmsNotifier.notifyIncoming], lui-même exécuté sur Dispatchers.IO, pour
 * ne jamais figer le main thread ni retarder la notification au-delà du budget.
 * Un cache court par thread évite de rappeler le LLM sur une rafale de SMS.
 */
object LlmSuggestions {

    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_ENABLED = "flutter.chat.fluffy.llm_enabled"
    private const val KEY_BASE_URL = "flutter.chat.fluffy.llm_base_url"
    private const val KEY_API_KEY = "flutter.chat.fluffy.llm_api_key"
    private const val KEY_MODEL = "flutter.chat.fluffy.llm_model"

    private const val DEFAULT_BASE_URL = "https://llm.sk7.sh/v1"
    private const val DEFAULT_MODEL = "qwen3.5-titan1-16x"

    // Budget strict : connect + read ≤ 2 s chacun → ≤ 4 s au total.
    private const val CONNECT_TIMEOUT_MS = 2_000
    private const val READ_TIMEOUT_MS = 2_000
    private const val MAX_TOKENS = 60
    private const val TEMPERATURE = 0.3

    private const val MAX_REPLIES = 3
    private const val MIN_WORDS = 1
    private const val MAX_WORDS = 6
    private const val MAX_REPLY_LENGTH = 80
    private const val CACHE_TTL_MS = 30_000L

    private const val SYSTEM_PROMPT =
        "Voici la fin d'une conversation SMS en français. Propose 3 réponses " +
            "courtes (max 6 mots chacune) que le destinataire pourrait envoyer, " +
            "au format JSON simple {\"replies\":[\"...\",\"...\",\"...\"]}. " +
            "Ne propose que des réponses naturelles en français."

    private val JSON_OBJECT = Regex("\\{.*\\}", RegexOption.DOT_MATCHES_ALL)
    private val WHITESPACE = Regex("\\s+")

    private data class Settings(val baseUrl: String, val apiKey: String, val model: String)
    private data class CacheEntry(val timestamp: Long, val replies: List<String>)

    private val cache = ConcurrentHashMap<Long, CacheEntry>()

    /**
     * Renvoie jusqu'à [MAX_REPLIES] réponses suggérées pour [threadId], ou une
     * liste vide si le LLM est désactivé, mal configuré, lent ou en erreur.
     * Bloquante : à n'appeler que hors du main thread.
     */
    fun suggest(context: Context, threadId: Long, transcript: String): List<String> {
        if (transcript.isBlank()) return emptyList()
        val settings = readSettings(context) ?: return emptyList()

        val cached = cache[threadId]
        if (cached != null &&
            System.currentTimeMillis() - cached.timestamp < CACHE_TTL_MS
        ) {
            return cached.replies
        }

        val replies = runCatching { request(settings, transcript) }
            .getOrElse {
                Log.w(SmsBridge.TAG, "LlmSuggestions: appel échoué (${it.message})")
                emptyList()
            }
        cache[threadId] = CacheEntry(System.currentTimeMillis(), replies)
        return replies
    }

    /** Purge le cache d'un thread (appelée quand la conversation est lue). */
    fun invalidate(threadId: Long) {
        cache.remove(threadId)
    }

    private fun readSettings(context: Context): Settings? {
        return try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_ENABLED, false)) return null
            val apiKey = prefs.getString(KEY_API_KEY, null)?.trim().orEmpty()
            if (apiKey.isEmpty()) return null
            val baseUrl = prefs.getString(KEY_BASE_URL, DEFAULT_BASE_URL)
                ?.trim()?.trimEnd('/')?.takeIf { it.isNotEmpty() } ?: DEFAULT_BASE_URL
            val model = prefs.getString(KEY_MODEL, DEFAULT_MODEL)
                ?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_MODEL
            Settings(baseUrl, apiKey, model)
        } catch (e: Exception) {
            null
        }
    }

    private fun request(settings: Settings, transcript: String): List<String> {
        val url = URL("${settings.baseUrl}/chat/completions")
        val body = JSONObject().apply {
            put("model", settings.model)
            put(
                "messages",
                JSONArray().apply {
                    put(JSONObject().put("role", "system").put("content", SYSTEM_PROMPT))
                    put(JSONObject().put("role", "user").put("content", transcript))
                },
            )
            put("max_tokens", MAX_TOKENS)
            put("temperature", TEMPERATURE)
        }.toString().toByteArray(Charsets.UTF_8)

        var connection: HttpURLConnection? = null
        return try {
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Authorization", "Bearer ${settings.apiKey}")
                setFixedLengthStreamingMode(body.size)
            }
            BufferedOutputStream(connection.outputStream).use { out ->
                out.write(body)
                out.flush()
            }
            val code = connection.responseCode
            if (code / 100 != 2) {
                Log.w(SmsBridge.TAG, "LlmSuggestions: LLM répond HTTP $code")
                return emptyList()
            }
            val raw = BufferedInputStream(connection.inputStream).use { input ->
                input.readBytes().toString(Charsets.UTF_8)
            }
            parseReplies(raw)
        } finally {
            connection?.disconnect()
        }
    }

    /**
     * Extrait le contenu du premier choix, puis tolère plusieurs formats :
     * JSON `{"replies":[…]}` (objet noyé dans du texte accepté), sinon repli sur
     * les lignes non vides (le modèle a répondu en liste).
     */
    private fun parseReplies(raw: String): List<String> {
        val content = extractContent(raw) ?: return emptyList()
        val candidates = ArrayList<String>()

        JSON_OBJECT.find(content)?.let { match ->
            runCatching {
                val arr = JSONObject(match.value).optJSONArray("replies")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        arr.optString(i).takeIf { it.isNotBlank() }?.let(candidates::add)
                    }
                }
            }
        }

        if (candidates.isEmpty()) {
            content.lineSequence().forEach { line ->
                val cleaned = line.trim().trimStart('-', '*', '•', ' ').trim('"').trim()
                if (cleaned.isNotEmpty()) candidates.add(cleaned)
            }
        }
        return filterReplies(candidates)
    }

    /** Contenu textuel de `choices[0].message.content`, ou le brut en repli. */
    private fun extractContent(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val parsed = runCatching {
            val choices = JSONObject(trimmed).optJSONArray("choices")
            if (choices == null || choices.length() == 0) return@runCatching null
            choices.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content")
                ?.takeIf { it.isNotBlank() }
        }.getOrNull()
        return parsed ?: trimmed
    }

    /** Filtre 1-6 mots, non vide, dédoublonné (casse ignorée), plafonné. */
    private fun filterReplies(raw: List<String>): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>(MAX_REPLIES)
        for (candidate in raw) {
            val text = candidate.trim().trim('"').trim()
            if (text.isEmpty() || text.length > MAX_REPLY_LENGTH) continue
            val words = text.split(WHITESPACE).count { it.isNotBlank() }
            if (words < MIN_WORDS || words > MAX_WORDS) continue
            if (!seen.add(text.lowercase(Locale.ROOT))) continue
            out.add(text)
            if (out.size == MAX_REPLIES) break
        }
        return out
    }
}
