package chat.fluffy.fluffychat.bastien_fork.wear.voice

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/**
 * Pousse une réponse texte (saisie/dictée via RemoteInput notif) vers le phone via
 * un DataItem `/wear/text/{uuid}`, symétrique au flux vocal `/wear/voice/{uuid}`.
 *
 * LIMITE COTE PHONE : a ce jour le natif phone ([WearBridgeService]) n'ecoute
 * que les paths voice et rooms. Tant qu'un handler de path texte
 * (Kotlin + callback Dart `onTextReceived`) n'est pas ajouté côté phone, ce texte
 * part dans le DataLayer mais n'est PAS posté dans la room Matrix. Le vocal, lui,
 * est pleinement fonctionnel. Voir le rapport pour le câblage phone restant.
 */
object TextUploader {

    private const val TAG = "TextUploader"
    private const val PATH_TEXT = "/wear/text"
    private const val KEY_ROOM_ID = "roomId"
    private const val KEY_TEXT = "text"
    private const val KEY_CREATED_AT = "createdAt"
    private const val KEY_UUID = "uuid"
    private const val PUT_TIMEOUT_MS = 15_000L

    // Borne défensive : un RemoteInput Wear ne produit pas de roman, mais on cape
    // pour éviter de pousser un DataItem géant si l'IME se comporte mal.
    private const val MAX_TEXT_LEN = 4_000

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun send(context: Context, roomId: String, text: String) {
        val clean = text.take(MAX_TEXT_LEN)
        val uuid = UUID.randomUUID().toString()
        scope.launch {
            val ok = withTimeoutOrNull(PUT_TIMEOUT_MS) {
                runCatching {
                    val req = PutDataMapRequest.create("$PATH_TEXT/$uuid").apply {
                        dataMap.putString(KEY_UUID, uuid)
                        dataMap.putString(KEY_ROOM_ID, roomId)
                        dataMap.putString(KEY_TEXT, clean)
                        dataMap.putLong(KEY_CREATED_AT, System.currentTimeMillis())
                    }.asPutDataRequest().setUrgent()
                    Wearable.getDataClient(context).putDataItem(req).await()
                }.onFailure { Log.w(TAG, "putDataItem text failed", it) }.isSuccess
            }
            Log.d(TAG, "text sent for ${roomId.redact()} ok=$ok (${clean.length} chars)")
        }
    }

    private fun String.redact(n: Int = 4): String =
        if (length <= n) this else substring(0, n) + "****"
}
