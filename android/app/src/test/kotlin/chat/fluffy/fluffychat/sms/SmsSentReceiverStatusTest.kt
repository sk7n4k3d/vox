package chat.fluffy.fluffychat.sms

import android.provider.Telephony
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tests JVM des règles d'écriture de [SmsSentReceiver] — findings prouvés de
 * l'audit 2026-11-05 :
 *  - F1 : un TP-Status négatif ou inconnu ne doit JAMAIS fabriquer « Distribué » ;
 *  - F3 : un rapport PENDING/NONE en retard ne régresse pas un statut terminal ;
 *  - F4 : le callback SENT-ok d'une part ne ressuscite pas une ligne FAILED ;
 *  - F5 : sur un multipart, l'échec gagne quel que soit l'ordre des rapports
 *    (statut + type posés ensemble, le label « Distribué » exige type==SENT).
 *
 * Les helpers de production construisent la vraie requête SQL (valeurs + WHERE
 * + args) ; [applyLikeProvider] l'interprète comme le content provider : la
 * garde vit dans le WHERE, la ligne passe ou saute, sans read-modify-write
 * Java entre deux broadcast concurrents.
 */
class SmsSentReceiverStatusTest {

    // ---------- F1 : mapping TP-Status (TS 23.040 9.2.3.15) ----------

    @Test
    fun `tp-status negatif ou inconnu ne fabrique jamais COMPLETE`() {
        // -1 = TP-Status absent ou illisible (SmsMessage.getStatus() est un
        // passe-plat non normalisé, vérifié dans AOSP frameworks/base).
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(-1))
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(Int.MIN_VALUE))
        // Valeurs non définies comme « remis » par la spec (0x01/0x02 =
        // stockage SC/équipement côté direction opposée, 0x05..0x1F réservées)
        // et hors plage 7 bits : aucune preuve de remise.
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(0x01))
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(0x02))
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(0x1F))
        assertEquals(Telephony.Sms.STATUS_NONE, deliveryStatusFromTpStatus(0x100))
    }

    @Test
    fun `seules les valeurs de succes explicites donnent COMPLETE`() {
        assertEquals(Telephony.Sms.STATUS_COMPLETE, deliveryStatusFromTpStatus(0x00))
        assertEquals(Telephony.Sms.STATUS_COMPLETE, deliveryStatusFromTpStatus(0x03))
        assertEquals(Telephony.Sms.STATUS_COMPLETE, deliveryStatusFromTpStatus(0x04))
    }

    @Test
    fun `erreurs temporaires en PENDING, permanentes en FAILED`() {
        assertEquals(Telephony.Sms.STATUS_PENDING, deliveryStatusFromTpStatus(0x20))
        assertEquals(Telephony.Sms.STATUS_PENDING, deliveryStatusFromTpStatus(0x2D))
        assertEquals(Telephony.Sms.STATUS_PENDING, deliveryStatusFromTpStatus(0x3F))
        assertEquals(Telephony.Sms.STATUS_FAILED, deliveryStatusFromTpStatus(0x40))
        assertEquals(Telephony.Sms.STATUS_FAILED, deliveryStatusFromTpStatus(0xFF))
    }

    // ---------- F3/F5 : garde du WHERE côté statut ----------

    @Test
    fun `FAILED s'ecrit sans garde de statut et pose type FAILED`() {
        val req = statusUpdateRequest(Telephony.Sms.STATUS_FAILED, ROW_ID)
        assertEquals(Telephony.Sms.STATUS_FAILED, req.values[Telephony.Sms.STATUS])
        // Le type suit : « Distribué » exigeant type==SENT côté UI, le masque
        // devient impossible même si le framework réécrit un statut depuis
        // l'extérieur dans un ordre non contrôlé.
        assertEquals(Telephony.Sms.MESSAGE_TYPE_FAILED, req.values[Telephony.Sms.TYPE])
        assertEquals(
            "un échec ne doit être bloqué par aucun statut courant",
            "${Telephony.Sms._ID}=?",
            req.selection,
        )
    }

    @Test
    fun `un statut non terminal refuse la regression d'un statut terminal`() {
        for (status in listOf(
            Telephony.Sms.STATUS_COMPLETE,
            Telephony.Sms.STATUS_PENDING,
            Telephony.Sms.STATUS_NONE,
        )) {
            val req = statusUpdateRequest(status, ROW_ID)
            assertEquals(
                listOf(
                    ROW_ID.toString(),
                    Telephony.Sms.STATUS_COMPLETE.toString(),
                    Telephony.Sms.STATUS_FAILED.toString(),
                ),
                req.selectionArgs,
            )
        }
    }

    // ---------- Scenarios bout-en-bout (requests reelles + sémantique provider) ----------

    @Test
    fun `F3 - PENDING puis NONE apres COMPLETE- le 0 terminal survit`() {
        val row = row(statusAfterSentCallback = true)
        applyLikeProvider(row, statusUpdateRequest(Telephony.Sms.STATUS_PENDING, ROW_ID))
        assertEquals(Telephony.Sms.STATUS_COMPLETE, row[Telephony.Sms.STATUS])
        applyLikeProvider(row, statusUpdateRequest(Telephony.Sms.STATUS_NONE, ROW_ID))
        assertEquals(Telephony.Sms.STATUS_COMPLETE, row[Telephony.Sms.STATUS])
    }

    @Test
    fun `F3 - COMPLETE apres PENDING- progression autorisee`() {
        val row = row(status = Telephony.Sms.STATUS_PENDING)
        applyLikeProvider(row, statusUpdateRequest(Telephony.Sms.STATUS_COMPLETE, ROW_ID))
        assertEquals(Telephony.Sms.STATUS_COMPLETE, row[Telephony.Sms.STATUS])
    }

    @Test
    fun `F5 - multipart FAILED puis COMPLETE- reste FAILED dans les deux ordres`() {
        for (completeFirst in listOf(false, true)) {
            val row = row()
            val complete = statusUpdateRequest(Telephony.Sms.STATUS_COMPLETE, ROW_ID)
            val failed = statusUpdateRequest(Telephony.Sms.STATUS_FAILED, ROW_ID)
            if (completeFirst) {
                applyLikeProvider(row, complete)
                applyLikeProvider(row, failed)
            } else {
                applyLikeProvider(row, failed)
                applyLikeProvider(row, complete)
            }
            assertEquals(
                "ordre ${if (completeFirst) "COMPLETE->FAILED" else "FAILED->COMPLETE"}",
                Telephony.Sms.STATUS_FAILED,
                row[Telephony.Sms.STATUS],
            )
            // Le type est FAILED dans les deux ordres : jamais de « Distribué »
            // pendant qu'une part est perdue.
            assertEquals(Telephony.Sms.MESSAGE_TYPE_FAILED, row[Telephony.Sms.TYPE])
        }
    }

    @Test
    fun `F4 - SENT-ok d une part apres un rapport FAILED ne ressuscite pas la ligne`() {
        val row = row()
        applyLikeProvider(row, statusUpdateRequest(Telephony.Sms.STATUS_FAILED, ROW_ID))
        applyLikeProvider(row, sentTypeUpdateRequest(ok = true, rowId = ROW_ID, errorCode = 0))
        assertEquals(Telephony.Sms.MESSAGE_TYPE_FAILED, row[Telephony.Sms.TYPE])
    }

    @Test
    fun `F4 - SENT-ok normal passe quand la ligne n est pas FAILED`() {
        val row = row(type = Telephony.Sms.MESSAGE_TYPE_QUEUED)
        applyLikeProvider(row, sentTypeUpdateRequest(ok = true, rowId = ROW_ID, errorCode = 0))
        assertEquals(Telephony.Sms.MESSAGE_TYPE_SENT, row[Telephony.Sms.TYPE])
    }

    @Test
    fun `F4 - SENT-ko ecrase sans condition, l echec gagne`() {
        val row = row(type = Telephony.Sms.MESSAGE_TYPE_FAILED)
        applyLikeProvider(row, sentTypeUpdateRequest(ok = false, rowId = ROW_ID, errorCode = 7))
        assertEquals(Telephony.Sms.MESSAGE_TYPE_FAILED, row[Telephony.Sms.TYPE])
        assertEquals(7, row[Telephony.Sms.ERROR_CODE])
    }

    @Test
    fun `F1 bout-en-bout - TP-Status -1 laisse la ligne sans preuve de remise`() {
        val row = row()
        val mapped = deliveryStatusFromTpStatus(-1)
        applyLikeProvider(row, statusUpdateRequest(mapped, ROW_ID))
        // -1 écrase un -1 (aucune information perdue, aucun mensonge) : le
        // statut comme le type restent non « Distribué ».
        assertEquals(Telephony.Sms.STATUS_NONE, row[Telephony.Sms.STATUS])
        assertEquals(Telephony.Sms.MESSAGE_TYPE_SENT, row[Telephony.Sms.TYPE])
    }

    // ---------- mini-fournisseur : applique la requête comme le ferait le provider ----------

    private fun row(
        type: Int = Telephony.Sms.MESSAGE_TYPE_SENT,
        status: Int = Telephony.Sms.STATUS_NONE,
        statusAfterSentCallback: Boolean = false,
    ) = mutableMapOf(
        Telephony.Sms.TYPE to type,
        Telephony.Sms.STATUS to if (statusAfterSentCallback) Telephony.Sms.STATUS_COMPLETE else status,
    )

    /**
     * Interprète les trois sélections exactement produites par les helpers :
     * si le WHERE filtre la ligne, l'écriture saute (0 ligne affectée) —
     * c'est l'atomicité qui manque à tout `if` Java lu après coup.
     */
    private fun applyLikeProvider(row: MutableMap<String, Int>, req: SmsRowUpdate) {
        val passes = when (req.selection) {
            "${Telephony.Sms._ID}=?" -> true
            "${Telephony.Sms._ID}=? AND ${Telephony.Sms.TYPE}<>?" ->
                row[Telephony.Sms.TYPE] != req.selectionArgs[1].toInt()
            "${Telephony.Sms._ID}=? AND ${Telephony.Sms.STATUS} NOT IN (?, ?)" ->
                row[Telephony.Sms.STATUS] !in req.selectionArgs.drop(1).map { it.toInt() }
            else -> error("sélection inconnue du modèle : ${req.selection}")
        }
        if (passes) req.values.forEach { (column, value) -> row[column] = value }
    }

    private companion object {
        const val ROW_ID = 4242L
    }
}
