package chat.fluffy.fluffychat.sms

import android.content.Context
import android.os.Build
import android.provider.BlockedNumberContract
import android.util.Log

/**
 * Blocage de numéros via la blacklist SYSTÈME Android (BlockedNumberContract).
 *
 * C'est la même base que Google Messages / QKSMS / Fossify : le système refuse
 * lui-même les SMS/MMS (jamais délivrés, pas de notif) ET les appels du numéro.
 *
 * Exige que VOX soit l'app SMS par défaut (contrat BlockedNumberContract —
 * sans le rôle, toute écriture lève une SecurityException). En lecture,
 * [BlockedNumberContract.isBlocked] marche même sans le rôle (best-effort).
 */
object BlockedNumbers {

    /** Normalise un numéro pour comparaison : garde les chiffres (+33 6… → 336…). */
    fun normalize(raw: String): String {
        val cleaned = raw.replace(Regex("[^0-9]"), "")
        // Numéros FR : un 0 initial devient 33… (le provider stocke souvent en format international).
        return if (cleaned.startsWith("0") && cleaned.length == 10) "33${cleaned.substring(1)}" else cleaned
    }

    fun isBlocked(context: Context, address: String): Boolean {
        return try {
            BlockedNumberContract.isBlocked(context, address)
        } catch (e: Exception) {
            Log.w(SmsBridge.TAG, "isBlocked failed: ${e.message}")
            false
        }
    }

    /** Bloque [address]. @return true si l'insertion a réussi. */
    fun block(context: Context, address: String): Boolean {
        return try {
            val values = android.content.ContentValues().apply {
                put(BlockedNumberContract.BlockedNumberColumns.COLUMN_ORIGINAL_NUMBER, address)
                put(BlockedNumberContract.BlockedNumberColumns.COLUMN_E164_NUMBER, normalize(address))
            }
            context.contentResolver.insert(BlockedNumberContract.BlockedNumberColumns.CONTENT_URI, values) != null
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "block failed: ${e.message}")
            false
        }
    }

    /** Débloque [address] (toutes les variantes du numéro). @return nb de lignes supprimées. */
    fun unblock(context: Context, address: String): Int {
        return try {
            val variants = setOf(address, normalize(address))
            var removed = 0
            for (v in variants) {
                removed += context.contentResolver.delete(
                    BlockedNumberContract.BlockedNumberColumns.CONTENT_URI,
                    "${BlockedNumberContract.BlockedNumberColumns.COLUMN_ORIGINAL_NUMBER}=? OR " +
                        "${BlockedNumberContract.BlockedNumberColumns.COLUMN_E164_NUMBER}=?",
                    arrayOf(v, v),
                )
            }
            removed
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "unblock failed: ${e.message}")
            0
        }
    }

    /** Liste tous les numéros bloqués : maps {id, number, e164}. */
    fun list(context: Context): List<Map<String, Any?>> {
        return try {
            val out = mutableListOf<Map<String, Any?>>()
            context.contentResolver.query(
                BlockedNumberContract.BlockedNumberColumns.CONTENT_URI,
                arrayOf(
                    BlockedNumberContract.BlockedNumberColumns._ID,
                    BlockedNumberContract.BlockedNumberColumns.COLUMN_ORIGINAL_NUMBER,
                    BlockedNumberContract.BlockedNumberColumns.COLUMN_E164_NUMBER,
                ),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    out.add(
                        mapOf(
                            "id" to c.getLong(0),
                            "number" to (c.getString(1) ?: ""),
                            "e164" to (c.getString(2) ?: ""),
                        )
                    )
                }
            }
            out
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                Log.w(SmsBridge.TAG, "list blocked: API < 24 unsupported")
            } else {
                Log.w(SmsBridge.TAG, "list blocked failed: ${e.message}")
            }
            emptyList()
        }
    }
}