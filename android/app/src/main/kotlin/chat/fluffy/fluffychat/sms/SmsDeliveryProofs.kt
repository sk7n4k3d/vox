package chat.fluffy.fluffychat.sms

import android.content.Context
import android.provider.Telephony

// Preuve de remise multipart (audit VoxOne 2026-11-05).
//
// Un SMS multipart = UNE ligne dans content://sms mais UN SMS-STATUS-REPORT PAR
// PART : l'ancien chemin écrivait STATUS_COMPLETE dès le rapport de la première
// part et la bulle passait en « Distribué » pendant que les parts suivantes
// n'étaient pas arrivées (ou étaient perdues).
//
// Règle : STATUS_COMPLETE n'est écrit côté provider que quand CHAQUE part a
// son propre rapport TP-Status de succès, et la ligne reçoit alors un marqueur
// de preuve. Le chemin de lecture exige ce marqueur : sans lui — lignes écrites
// avant ce correctif, messages venus d'une autre app, rapports orphelins — un
// STATUS_COMPLETE en base reste indéterminé et est dégradé à la lecture en
// STATUS_NONE (« Envoyé », jamais « Distribué »). Aucune donnée provider n'est
// modifiée, aucune confirmation n'est jamais fabriquée.

/** Nombre maximal de parts suivies par le bitmask (un Long). */
internal const val MAX_TRACKED_PARTS = 62

/** État persistant du suivi de remise d'UNE ligne envoyée par VOX. */
internal data class DeliveryTracking(
    /** Nombre total de parts du message ; 0 = pas encore connu. */
    val partCount: Int = 0,
    /** Bitmask des parts ayant un rapport TP-Status de succès (bit i = part i). */
    val delivered: Long = 0L,
    /** Toutes les parts sont prouvées remises : la ligne a droit à « Distribué ». */
    val proven: Boolean = false,
)

/** Décision produite par [advanceDelivery] / [applyDeliveryReport]. */
internal data class DeliveryAdvance(
    /** Nouvel état à persister. */
    val tracking: DeliveryTracking,
    /**
     * Statut à écrire au provider via [statusUpdateRequest] ; null = ne RIEN
     * écrire : une part remise sur plusieurs ne prouve pas la remise du tout.
     */
    val providerStatus: Int?,
)

internal fun allPartsDeliveredMask(partCount: Int): Long = (1L shl partCount) - 1L

/**
 * Applique un rapport de remise (statut mappé depuis le TP-Status) pour la
 * part [partIndex] d'un message de [partCount] parts, sur l'état [state].
 *
 *  - FAILED : l'échec gagne (état remis à zéro, provider FAILED + type FAILED,
 *    cf. F5 de l'audit 2026-11-05) ;
 *  - COMPLETE d'un multipart : on enregistre la part et on n'écrit RIEN tant
 *    que toutes les parts ne sont pas prouvées ; la dernière part déclenche
 *    le COMPLETE (case 1 part = rapport unique = preuve complète) ;
 *  - COMPLETE avec nombre de parts inconnu (intent d'une version antérieure au
 *    correctif, extra absent ou hors plage) : aucune preuve possible → on
 *    n'écrit rien, on n'invente rien ;
 *  - PENDING/NONE : progression non terminale, écrite comme avant.
 */
internal fun advanceDelivery(
    state: DeliveryTracking,
    status: Int,
    partIndex: Int,
    partCount: Int,
): DeliveryAdvance = when (status) {
    Telephony.Sms.STATUS_FAILED ->
        DeliveryAdvance(DeliveryTracking(), Telephony.Sms.STATUS_FAILED)

    Telephony.Sms.STATUS_COMPLETE -> completeAdvance(state, partIndex, partCount)

    Telephony.Sms.STATUS_PENDING -> DeliveryAdvance(
        state.withKnownCount(partCount),
        Telephony.Sms.STATUS_PENDING,
    )

    else -> DeliveryAdvance(state, Telephony.Sms.STATUS_NONE)
}

private fun DeliveryTracking.withKnownCount(count: Int): DeliveryTracking = when {
    partCount > 0 -> this
    count in 1..MAX_TRACKED_PARTS -> copy(partCount = count)
    else -> this
}

private fun completeAdvance(
    state: DeliveryTracking,
    partIndex: Int,
    partCount: Int,
): DeliveryAdvance {
    // L'extra porté par le PendingIntent fait foi ; à défaut, le total déjà
    // persisté (une part antérieure l'a peut-être révélé).
    val count = if (partCount in 1..MAX_TRACKED_PARTS) partCount else state.partCount
    if (count <= 0 || count > MAX_TRACKED_PARTS) {
        return DeliveryAdvance(state, null)
    }
    if (count == 1) {
        return DeliveryAdvance(
            DeliveryTracking(partCount = 1, delivered = 1L, proven = true),
            Telephony.Sms.STATUS_COMPLETE,
        )
    }
    if (partIndex !in 0 until count) {
        // Index absent ou hors plage : impossible d'attribuer la preuve à une
        // part nommément identifiée → rien d'écrit.
        return DeliveryAdvance(state.withKnownCount(count), null)
    }
    val mask = state.delivered or (1L shl partIndex)
    return if (mask == allPartsDeliveredMask(count)) {
        DeliveryAdvance(
            DeliveryTracking(count, mask, proven = true),
            Telephony.Sms.STATUS_COMPLETE,
        )
    } else {
        DeliveryAdvance(DeliveryTracking(count, mask), null)
    }
}

/**
 * Statut rendu à l'UI pour une ligne SMS lue dans le provider. Un
 * STATUS_COMPLETE sans marqueur de preuve posé par VOX est indéterminé (autre
 * app, ou ligne écrite avant le correctif qui marquait « Distribué » dès la
 * première part) : dégradé à la lecture en STATUS_NONE. Les autres lignes
 * (reçues, échouées, brouillons) passent intactes — la colonne n'y porte pas
 * le label.
 */
internal fun reportedSentStatus(type: Int, dbStatus: Int, proven: Boolean): Int =
    if (type == Telephony.Sms.MESSAGE_TYPE_SENT &&
        dbStatus == Telephony.Sms.STATUS_COMPLETE &&
        !proven
    ) {
        Telephony.Sms.STATUS_NONE
    } else {
        dbStatus
    }

/** État persistant lu/écrit par [SmsSentReceiver] et par le chemin de lecture. */
internal interface DeliveryProofStore {
    fun state(rowId: Long): DeliveryTracking
    fun saveState(rowId: Long, tracking: DeliveryTracking)
    fun isProven(rowId: Long): Boolean
}

/**
 * Enchaîne lecture de l'état → [advanceDelivery] → persistance. Un broadcast
 * traité après un redémarrage (les PendingIntents de remise vivent dans le
 * framework, les extras survivent) repart donc de l'état sur disque.
 */
internal fun applyDeliveryReport(
    store: DeliveryProofStore,
    rowId: Long,
    parsedStatus: Int,
    partIndex: Int,
    partCount: Int,
): DeliveryAdvance {
    val adv = advanceDelivery(store.state(rowId), parsedStatus, partIndex, partCount)
    store.saveState(rowId, adv.tracking)
    return adv
}

/**
 * Implémentation SharedPreferences : persiste le suivi entre broadcasts même
 * si le process meurt entre deux rapports de parts. Purge les suivis jamais
 * complétés (aucun rapport revenu, ligne abandonnée) après [DEFAULT_RETENTION_MS] ;
 * les marqueurs de preuve ne sont jamais purgés — eux sont vrais.
 */
internal class SmsDeliveryProofs(context: Context) : DeliveryProofStore {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun state(rowId: Long) = DeliveryTracking(
        partCount = prefs.getInt("$KEY_COUNT$rowId", 0),
        delivered = prefs.getLong("$KEY_MASK$rowId", 0L),
        proven = prefs.getBoolean("$KEY_PROVEN$rowId", false),
    )

    override fun saveState(rowId: Long, tracking: DeliveryTracking) {
        val editor = prefs.edit()
        if (tracking == DeliveryTracking()) {
            // Suivi terminé et non concluant (échec) : plus rien à attendre.
            editor
                .remove("$KEY_COUNT$rowId")
                .remove("$KEY_MASK$rowId")
                .remove("$KEY_TS$rowId")
                .remove("$KEY_PROVEN$rowId")
        } else {
            if (prefs.getLong("$KEY_TS$rowId", 0L) == 0L) {
                editor.putLong("$KEY_TS$rowId", System.currentTimeMillis())
            }
            editor
                .putInt("$KEY_COUNT$rowId", tracking.partCount)
                .putLong("$KEY_MASK$rowId", tracking.delivered)
                .putBoolean("$KEY_PROVEN$rowId", tracking.proven)
        }
        editor.apply()
    }

    override fun isProven(rowId: Long): Boolean =
        prefs.getBoolean("$KEY_PROVEN$rowId", false)

    /** Marqueur de preuve d'une ligne supprimée → clés purgées. */
    fun forget(rowId: Long) = saveState(rowId, DeliveryTracking())

    fun pruneStaleParts(
        retentionMs: Long = DEFAULT_RETENTION_MS,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val editor = prefs.edit()
        var pruned = false
        for ((key, value) in prefs.all) {
            if (!key.startsWith(KEY_TS) || value !is Long) continue
            if (nowMs - value <= retentionMs) continue
            val rowId = key.removePrefix(KEY_TS)
            editor
                .remove("$KEY_COUNT$rowId")
                .remove("$KEY_MASK$rowId")
                .remove(key)
            pruned = true
        }
        if (pruned) editor.apply()
    }

    companion object {
        private const val PREFS = "vox_sms_delivery"
        private const val KEY_COUNT = "dlv_count_"
        private const val KEY_MASK = "dlv_mask_"
        private const val KEY_PROVEN = "dlv_prov_"
        private const val KEY_TS = "dlv_ts_"
        internal const val DEFAULT_RETENTION_MS = 1000L * 60L * 60L * 24L * 30L
    }
}
