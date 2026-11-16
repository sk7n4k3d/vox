package chat.fluffy.fluffychat.sms

import android.provider.Telephony
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests JVM de la preuve de remise multipart (audit VoxOne 2026-11-05) :
 * le « Distribué » transitoire dès la 1re part d'un SMS multipart est corrigé
 * par [advanceDelivery] + [applyDeliveryReport] (écriture native) et
 * [reportedSentStatus] (lecture, cas historiques indéterminés).
 *
 * Le store est simulé par [DiskBackedStore] : deux instances qui partagent la
 * même « carte » de chaînes reproduisent exactement ce que fait
 * [SmsDeliveryProofs] avec SharedPreferences — un broadcast traité après un
 * redémarrage du process repart de l'état sur disque.
 */
class SmsDeliveryProofsTest {

    // ---------- multipart : jamais de COMPLETE avant la dernière part ----------

    @Test
    fun `multipart - le COMPLETE de la premiere part n ecrit jamais COMPLETE`() {
        val store = DiskBackedStore()
        val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, partIndex = 0, partCount = 3)
        assertNull(
            "une part sur trois ne prouve pas la remise du message entier",
            adv.providerStatus,
        )
        assertEquals(0b001L, store.state(ROW).delivered)
        assertFalse(store.isProven(ROW))
    }

    @Test
    fun `multipart - tous les ordres de rapports- COMPLETE seulement a la derniere part`() {
        val orders = listOf(
            listOf(0, 1, 2), listOf(0, 2, 1), listOf(1, 0, 2),
            listOf(1, 2, 0), listOf(2, 0, 1), listOf(2, 1, 0),
        )
        for (order in orders) {
            val store = DiskBackedStore()
            val row = row()
            order.forEachIndexed { step, part ->
                val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, part, 3)
                adv.providerStatus?.let {
                    applyLikeProvider(row, statusUpdateRequest(it, ROW))
                }
                if (step < order.lastIndex) {
                    assertNull("ordre $order : COMPLETE écrit trop tôt à l'étape $step", adv.providerStatus)
                    assertEquals(
                        "ordre $order : la bulle ne doit pas passer à « Distribué »",
                        Telephony.Sms.STATUS_NONE,
                        row[Telephony.Sms.STATUS],
                    )
                } else {
                    assertEquals(
                        "ordre $order : la dernière part doit prouver la remise",
                        Telephony.Sms.STATUS_COMPLETE,
                        adv.providerStatus,
                    )
                }
            }
            assertEquals(Telephony.Sms.STATUS_COMPLETE, row[Telephony.Sms.STATUS])
            assertTrue("la preuve doit exister pour le chemin de lecture", store.isProven(ROW))
            // Et relue, la ligne a bien droit à « Distribué » :
            assertEquals(
                Telephony.Sms.STATUS_COMPLETE,
                reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, row[Telephony.Sms.STATUS]!!, store.isProven(ROW)),
            )
        }
    }

    @Test
    fun `multipart - un rapport duplique de la meme part ne compte pas deux fois`() {
        val store = DiskBackedStore()
        applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 2)
        val dup = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 2)
        assertNull("le doublon ne doit pas créer la preuve de la 2e part", dup.providerStatus)
        assertEquals(0b01L, store.state(ROW).delivered)
        val last = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 1, 2)
        assertEquals(Telephony.Sms.STATUS_COMPLETE, last.providerStatus)
        assertTrue(store.isProven(ROW))
    }

    @Test
    fun `multipart - un COMPLETE partiel laisse la ligne relue en Envoye`() {
        val store = DiskBackedStore()
        applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 2)
        val dbStatus = Telephony.Sms.STATUS_NONE // le provider n'a jamais été touché
        assertEquals(
            Telephony.Sms.STATUS_NONE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, dbStatus, store.isProven(ROW)),
        )
    }

    // ---------- échec : gagne dans tous les ordres ----------

    @Test
    fun `multipart - FAILED et COMPLETE dans les deux ordres- echec collant, jamais de preuve`() {
        for (failedFirst in listOf(true, false)) {
            val store = DiskBackedStore()
            val row = row()
            val reports = if (failedFirst) {
                listOf(Pair(0, Telephony.Sms.STATUS_FAILED), Pair(1, Telephony.Sms.STATUS_COMPLETE))
            } else {
                listOf(Pair(1, Telephony.Sms.STATUS_COMPLETE), Pair(0, Telephony.Sms.STATUS_FAILED))
            }
            for ((part, status) in reports) {
                val adv = applyDeliveryReport(store, ROW, status, part, 2)
                adv.providerStatus?.let { applyLikeProvider(row, statusUpdateRequest(it, ROW)) }
            }
            assertEquals(
                "failedFirst=$failedFirst",
                Telephony.Sms.STATUS_FAILED,
                row[Telephony.Sms.STATUS],
            )
            assertEquals(Telephony.Sms.MESSAGE_TYPE_FAILED, row[Telephony.Sms.TYPE])
            assertFalse("un échec ne laisse jamais subsister de preuve", store.isProven(ROW))
        }
    }

    // ---------- cas indéterminés : pas de preuve, pas de label ----------

    @Test
    fun `nombre de parts inconnu - un COMPLETE ne fabrique jamais l ecriture provider`() {
        val store = DiskBackedStore()
        // PendingIntent créé par une version antérieure au correctif : extras absents.
        val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, partIndex = -1, partCount = 0)
        assertNull(adv.providerStatus)
        assertFalse(store.isProven(ROW))
    }

    @Test
    fun `index de part hors plage - aucune preuve attribuable, rien d ecrit`() {
        val store = DiskBackedStore()
        val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, partIndex = 7, partCount = 3)
        assertNull(adv.providerStatus)
        assertEquals(0L, store.state(ROW).delivered)
    }

    @Test
    fun `historique - COMPLETE en base sans preuve VOX lu comme NONE (pas de Distribue)`() {
        // Lignes écrites avant le correctif (COMPLETE dès la 1re part) ou par
        // une autre app : indéterminées → dégradées à la lecture seulement,
        // les données provider restent intactes.
        val store = DiskBackedStore()
        assertEquals(
            Telephony.Sms.STATUS_NONE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, Telephony.Sms.STATUS_COMPLETE, store.isProven(ROW)),
        )
        // Avec preuve complète cette fois : le 0 passe intact.
        store.markProven(ROW)
        assertEquals(
            Telephony.Sms.STATUS_COMPLETE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, Telephony.Sms.STATUS_COMPLETE, store.isProven(ROW)),
        )
    }

    @Test
    fun `la degradation ne touche que SENT-COMPLETE - recu echoue ou non-0 intacts`() {
        val provenFalse = false
        assertEquals(
            "reçu (inbox) : jamais concerné par le label",
            Telephony.Sms.STATUS_COMPLETE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_INBOX, Telephony.Sms.STATUS_COMPLETE, provenFalse),
        )
        assertEquals(
            Telephony.Sms.STATUS_COMPLETE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_FAILED, Telephony.Sms.STATUS_COMPLETE, provenFalse),
        )
        assertEquals(
            Telephony.Sms.STATUS_PENDING,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, Telephony.Sms.STATUS_PENDING, provenFalse),
        )
        assertEquals(
            Telephony.Sms.STATUS_NONE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, Telephony.Sms.STATUS_NONE, provenFalse),
        )
    }

    // ---------- mono-part : comportement inchangé (compat) ----------

    @Test
    fun `mono-part - rapport unique = preuve immediate et complete`() {
        val store = DiskBackedStore()
        val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 1)
        assertEquals(Telephony.Sms.STATUS_COMPLETE, adv.providerStatus)
        assertTrue(store.isProven(ROW))
    }

    // ---------- redémarrage ----------

    @Test
    fun `redemarrage - le suivi survit a la perte du process et la preuve se complete`() {
        val disk = mutableMapOf<String, String>()
        val before = DiskBackedStore(disk)
        applyDeliveryReport(before, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 2)
        assertFalse("la première part seule ne doit rien avoir marqué", before.isProven(ROW))

        // Mort du process : seul le contenu « disque » survit.
        val after = DiskBackedStore(disk)
        assertEquals(0b01L, after.state(ROW).delivered)
        assertEquals(2, after.state(ROW).partCount)
        val adv = applyDeliveryReport(after, ROW, Telephony.Sms.STATUS_COMPLETE, 1, 2)
        assertEquals(Telephony.Sms.STATUS_COMPLETE, adv.providerStatus)
        assertTrue(after.isProven(ROW))
    }

    @Test
    fun `pending et none - progression non terminale ecrite, suivi preserve`() {
        val store = DiskBackedStore()
        applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 3)
        val adv = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_PENDING, 1, 3)
        assertEquals(Telephony.Sms.STATUS_PENDING, adv.providerStatus)
        assertEquals(0b001L, store.state(ROW).delivered)
        val none = applyDeliveryReport(store, ROW, Telephony.Sms.STATUS_NONE, 1, 3)
        assertEquals(Telephony.Sms.STATUS_NONE, none.providerStatus)
        assertEquals(0b001L, store.state(ROW).delivered)
    }

    @Test
    fun `la preuve complete relue apres redemarrage autorise Distribue`() {
        val disk = mutableMapOf<String, String>()
        val first = DiskBackedStore(disk)
        applyDeliveryReport(first, ROW, Telephony.Sms.STATUS_COMPLETE, 0, 1)
        val afterReboot = DiskBackedStore(disk)
        assertEquals(
            Telephony.Sms.STATUS_COMPLETE,
            reportedSentStatus(Telephony.Sms.MESSAGE_TYPE_SENT, Telephony.Sms.STATUS_COMPLETE, afterReboot.isProven(ROW)),
        )
    }

    // ---------- mini-fournisseur + store simulé ----------

    private fun row(type: Int = Telephony.Sms.MESSAGE_TYPE_SENT) = mutableMapOf(
        Telephony.Sms.TYPE to type,
        Telephony.Sms.STATUS to Telephony.Sms.STATUS_NONE,
    )

    /** Interprète le WHERE comme le content provider (même modèle que SmsSentReceiverStatusTest). */
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

    /**
     * Store en mémoire sérialisé dans une carte de chaînes partagée : créer
     * une nouvelle instance sur la même carte = relire l'état depuis le
     * disque après un redémarrage (mêmes clés/valeurs que
     * [SmsDeliveryProofs] sur SharedPreferences).
     */
    private class DiskBackedStore(
        private val disk: MutableMap<String, String> = mutableMapOf(),
    ) : DeliveryProofStore {

        override fun state(rowId: Long) = DeliveryTracking(
            partCount = disk["count_$rowId"]?.toIntOrNull() ?: 0,
            delivered = disk["mask_$rowId"]?.toLongOrNull() ?: 0L,
            proven = disk["proven_$rowId"] == "1",
        )

        override fun saveState(rowId: Long, tracking: DeliveryTracking) {
            if (tracking == DeliveryTracking()) {
                disk.remove("count_$rowId")
                disk.remove("mask_$rowId")
                disk.remove("proven_$rowId")
            } else {
                disk["count_$rowId"] = tracking.partCount.toString()
                disk["mask_$rowId"] = tracking.delivered.toString()
                disk["proven_$rowId"] = if (tracking.proven) "1" else "0"
            }
        }

        override fun isProven(rowId: Long) = disk["proven_$rowId"] == "1"

        fun markProven(rowId: Long) {
            disk["proven_$rowId"] = "1"
        }
    }

    private companion object {
        const val ROW = 9911L
    }
}
