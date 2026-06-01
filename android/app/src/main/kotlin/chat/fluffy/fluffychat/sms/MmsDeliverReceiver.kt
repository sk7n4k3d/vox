package chat.fluffy.fluffychat.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Receiver WAP_PUSH_DELIVER (MMS entrant) — Étape 2.
 *
 * OBLIGATOIRE pour le rôle ROLE_SMS : une app SMS par défaut DOIT déclarer un receiver
 * WAP_PUSH_DELIVER pour `application/vnd.wap.mms-message`, sinon elle n'apparaît pas dans la
 * liste « app SMS par défaut ».
 *
 * ── Ce qui est COMPLET ────────────────────────────────────────────────────────
 *  - Réception du broadcast WAP_PUSH.
 *  - Notification à Dart (via [SmsBridge.onMmsReceived]) pour déclencher un refresh de la liste.
 *
 * ── Ce qui est BEST-EFFORT / DÉLÉGUÉ AU SYSTÈME ───────────────────────────────
 * On NE parse PAS le PDU de notification ici, et on NE déclenche PAS manuellement le download
 * du corps MMS via le MMSC. Raison : quand VOX détient ROLE_SMS, la **stack Android** (service
 * système) gère le download du m-retrieve-conf et écrit la ligne + les parts dans
 * `content://mms` de façon ASYNCHRONE. Réimplémenter ce download (parse PDU notif, requête HTTP
 * MMSC via l'APN MMS dédié, parse m-retrieve-conf, écriture parts) est fragile et carrier-
 * dépendant — hors scope raisonnable ici.
 *
 * Conséquence : à la réception du WAP push, le MMS n'est PAS encore forcément dans le provider.
 * On signale juste à Dart « un MMS arrive ». Dart doit re-`listConversations()` /
 * `listMessages()` peu après (ex. retry court ou refresh sur focus) pour le voir apparaître une
 * fois le download système terminé.
 *
 * Si VOX n'est pas l'app SMS par défaut, ce receiver ne se déclenche jamais.
 */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION) {
            return
        }
        val mimeType = intent.type
        Log.i(
            SmsBridge.TAG,
            "WAP_PUSH_DELIVER (MMS) reçu mime=$mimeType — download délégué à la stack système, " +
                "notification refresh envoyée à Dart",
        )

        // Notifie Dart si le pont est branché. Le corps du MMS sera disponible dans content://mms
        // une fois le download système terminé (asynchrone) — Dart doit refresh peu après.
        SmsBridge.onMmsReceived?.invoke(
            mapOf(
                "mimeType" to (mimeType ?: "application/vnd.wap.mms-message"),
                "date" to System.currentTimeMillis(),
            )
        )
    }
}
