package chat.fluffy.fluffychat.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Reçoit les PendingIntents SENT / DELIVERED émis par [SmsBridge.sendSms] et met à jour
 * le `type` / `status` de la ligne SMS correspondante dans le provider.
 *
 * Déclaré non-exporté (receiver interne, déclenché par nos propres PendingIntents avec
 * setPackage). Pas de permission système requise.
 *
 * Les règles d'écriture (colonnes + garde WHERE) sont sorties de la classe dans des
 * fonctions pures ([deliveryStatusFromTpStatus], [statusUpdateRequest],
 * [sentTypeUpdateRequest]) pour être couvertes par des tests JVM unitaires.
 */
class SmsSentReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val rowId = intent.getLongExtra(SmsBridge.EXTRA_ROW_ID, 0L)
        if (rowId <= 0L) return

        when (action) {
            SmsBridge.ACTION_SMS_SENT -> {
                val ok = resultCode == Activity.RESULT_OK
                applyUpdate(
                    context,
                    sentTypeUpdateRequest(ok = ok, rowId = rowId, errorCode = resultCode),
                    rowId,
                    "updateType",
                )
                ScheduledSmsAlarms.onSmsSent(context.applicationContext, rowId, ok)
                if (!ok) Log.w(SmsBridge.TAG, "SMS send FAILED (row=$rowId, code=$resultCode)")
            }
            SmsBridge.ACTION_SMS_DELIVERED -> {
                // Lire le vrai SMS-STATUS-REPORT au lieu de supposer "remis" :
                // un échec/expiration opérateur doit être enregistré comme tel.
                // Multipart : un rapport PAR PART ; STATUS_COMPLETE n'est écrit
                // au provider que quand TOUTES les parts ont un rapport de
                // succès (audit VoxOne — le COMPLETE de la 1re part affichait
                // « Distribué » avant remise des suivantes).
                val status = parseDeliveryStatus(intent)
                val partIndex = intent.getIntExtra(SmsBridge.EXTRA_PART_INDEX, -1)
                val partCount = intent.getIntExtra(SmsBridge.EXTRA_PART_COUNT, 0)
                val adv = applyDeliveryReport(
                    SmsDeliveryProofs(context),
                    rowId,
                    status,
                    partIndex,
                    partCount,
                )
                val providerStatus = adv.providerStatus
                if (providerStatus != null) {
                    applyUpdate(
                        context,
                        statusUpdateRequest(providerStatus, rowId),
                        rowId,
                        "updateStatus",
                    )
                } else {
                    Log.i(
                        SmsBridge.TAG,
                        "remise part $partIndex/$partCount (row=$rowId) : " +
                            "preuve incomplète, statut non écrit",
                    )
                }
            }
        }
    }

    /**
     * Mappe le PDU de delivery-report vers un statut Telephony. Un PDU absent
     * ou illisible ne prouve PAS la remise : on retourne STATUS_NONE (-1), la
     * bulle reste « Envoyé ». Ne jamais fabriquer de STATUS_COMPLETE (0) sans
     * preuve — c'est la colonne qui déclenche le label « Distribué » côté UI
     * (audit 2026-11-05 : le fallback historique 0 affichait « Distribué » sur
     * rapport vide, et son `else` ouvert le fabriquait aussi sur TP-Status
     * négatif ou inconnu — F1 corrigé par [deliveryStatusFromTpStatus]).
     */
    private fun parseDeliveryStatus(intent: Intent): Int {
        return try {
            val msg = Telephony.Sms.Intents.getMessagesFromIntent(intent)?.firstOrNull()
                ?: run {
                    Log.w(SmsBridge.TAG, "delivery report sans PDU -> STATUS_NONE")
                    return Telephony.Sms.STATUS_NONE
                }
            val status = deliveryStatusFromTpStatus(msg.status)
            if (status == Telephony.Sms.STATUS_NONE && msg.status != Telephony.Sms.STATUS_NONE) {
                Log.w(SmsBridge.TAG, "TP-Status non probant (${msg.status}) -> STATUS_NONE")
            }
            status
        } catch (e: Exception) {
            Log.w(SmsBridge.TAG, "parseDeliveryStatus failed: ${e.message}")
            Telephony.Sms.STATUS_NONE
        }
    }

    /** Applique une requête produite par les helpers purs, en une seule instruction SQL. */
    private fun applyUpdate(context: Context, req: SmsRowUpdate, rowId: Long, label: String) {
        try {
            val values = ContentValues()
            req.values.forEach { (column, value) -> values.put(column, value) }
            context.contentResolver.update(
                Telephony.Sms.CONTENT_URI,
                values,
                req.selection,
                req.selectionArgs.toTypedArray(),
            )
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "$label(row=$rowId) failed: ${e.message}")
        }
    }
}

/**
 * Une mise à jour prête à envoyer vers le provider : valeurs + WHERE + args.
 * La garde vit dans le WHERE, jamais dans un `if` lu après une lecture :
 * le fournisseur applique l'instruction atomiquement (pas de course
 * lecture/écriture entre broadcast DELIVERED/SENT concurrents).
 */
internal data class SmsRowUpdate(
    val values: Map<String, Int>,
    val selection: String,
    val selectionArgs: List<String>,
)

/**
 * Mappe le TP-Status brut du PDU de rapport (GSM 03.40 / TS 23.040 9.2.3.15)
 * vers un statut Telephony. Seules les valeurs de succès EXPLICITES fabriquent
 * STATUS_COMPLETE : 0x00 (reçu), 0x03 (stocké malgré erreur DCS), 0x04 (message
 * wait SMS-SC). 0x20..0x3F = erreur temporaire (en cours), 0x40..0xFF = échec
 * permanent. Tout le reste — négatif en particulier (-1 = TP-Status absent ou
 * illisible ; `SmsMessage.getStatus()` est un passe-plat non normalisé, cf.
 * audit AOSP 2026-11-05), valeurs positives inconnues et hors plage — ne
 * prouve rien : STATUS_NONE. L'ancien `else -> COMPLETE` transformait un
 * rapport mal formé en « Distribué » sans preuve (F1).
 */
internal fun deliveryStatusFromTpStatus(rawStatus: Int): Int = when {
    rawStatus in 0x40..0xFF -> Telephony.Sms.STATUS_FAILED
    rawStatus in 0x20..0x3F -> Telephony.Sms.STATUS_PENDING
    rawStatus == 0x00 || rawStatus == 0x03 || rawStatus == 0x04 -> Telephony.Sms.STATUS_COMPLETE
    else -> Telephony.Sms.STATUS_NONE
}

/**
 * Écrit le statut de remise (audit 2026-11-05, F3 + F5) :
 *  - STATUS_FAILED : toujours écrit, SANS garde de statut — un échec doit
 *    l'emporter quel que soit l'ordre d'arrivée des rapports de parts
 *    (multipart : une ligne = un message entier, un rapport par part). Il pose
 *    aussi TYPE=MESSAGE_TYPE_FAILED pour que le label « Distribué » (qui exige
 *    type==SENT côté UI) devienne impossible même si le COMPLETE d'une autre
 *    part était déjà passé avant ;
 *  - tout autre statut (COMPLETE, PENDING, NONE) : n'écrase JAMAIS un statut
 *    terminal déjà posé (0 ou 64). Un PENDING/NONE en retard ne peut plus
 *    régresser un « Distribué » prouvé, et un COMPLETE ne peut pas masquer un
 *    FAILED collant.
 *  - COMPLETE n'est plus jamais transmis ici sur la foi d'UNE part : voir
 *    [advanceDelivery] — seule la preuve de remise de TOUTES les parts (ou le
 *    rapport unique d'un message à une part) produit ce statut.
 */
internal fun statusUpdateRequest(status: Int, rowId: Long): SmsRowUpdate =
    if (status == Telephony.Sms.STATUS_FAILED) {
        SmsRowUpdate(
            values = mapOf(
                Telephony.Sms.STATUS to Telephony.Sms.STATUS_FAILED,
                Telephony.Sms.TYPE to Telephony.Sms.MESSAGE_TYPE_FAILED,
            ),
            selection = "${Telephony.Sms._ID}=?",
            selectionArgs = listOf(rowId.toString()),
        )
    } else {
        SmsRowUpdate(
            values = mapOf(Telephony.Sms.STATUS to status),
            selection =
                "${Telephony.Sms._ID}=? AND ${Telephony.Sms.STATUS} NOT IN (?, ?)",
            selectionArgs = listOf(
                rowId.toString(),
                Telephony.Sms.STATUS_COMPLETE.toString(),
                Telephony.Sms.STATUS_FAILED.toString(),
            ),
        )
    }

/**
 * Écrit le `type` au callback SENT (audit 2026-11-05, F4) :
 *  - succès : ne ressuscite pas une ligne déjà classée MESSAGE_TYPE_FAILED
 *    (sur un multipart, le SENT-ok d'une part ne doit pas ressortir « envoyé »
 *    une ligne que le callback d'échec ou un rapport de remise ont condamnée) ;
 *  - échec : écrit sans condition, l'échec gagne toujours.
 *
 * ERROR_CODE : code opérateur. On stocke le resultCode si échec (non-zéro
 * = erreur, sémantique attendue par les apps SMS lisant cette colonne).
 */
internal fun sentTypeUpdateRequest(ok: Boolean, rowId: Long, errorCode: Int): SmsRowUpdate =
    if (ok) {
        SmsRowUpdate(
            values = mapOf(Telephony.Sms.TYPE to Telephony.Sms.MESSAGE_TYPE_SENT),
            selection = "${Telephony.Sms._ID}=? AND ${Telephony.Sms.TYPE}<>?",
            selectionArgs = listOf(rowId.toString(), Telephony.Sms.MESSAGE_TYPE_FAILED.toString()),
        )
    } else {
        SmsRowUpdate(
            values = mapOf(
                Telephony.Sms.TYPE to Telephony.Sms.MESSAGE_TYPE_FAILED,
                Telephony.Sms.ERROR_CODE to errorCode,
            ),
            selection = "${Telephony.Sms._ID}=?",
            selectionArgs = listOf(rowId.toString()),
        )
    }
