package chat.fluffy.fluffychat.bastien_fork.wear.ui

import java.util.Calendar
import kotlin.math.abs

/**
 * Helpers de formatage et de découpage temporel — logique pure, testée sans
 * Compose (src/test). Toute règle d'affichage du temps passe par ici pour que
 * la liste et les séparateurs de jour ne divergent jamais.
 */

/** "m:ss" / "12:34" — borné à 99:59 (le recorder plafonne déjà plus bas). */
fun formatDuration(ms: Long): String {
    val totalSec = (ms / 1000L).coerceIn(0L, 5999L)
    val m = totalSec / 60
    val s = totalSec % 60
    return "%d:%02d".format(m, s)
}

fun formatDuration(ms: Int): String = formatDuration(ms.toLong())

/**
 * Timestamp court d'une room ou d'un message dans la liste :
 * "à l'instant" (<60 s), "il y a Nm", "9:41" aujourd'hui, "Hier",
 * "lun. 12" cette semaine, sinon "12/03".
 */
fun shortStamp(ts: Long, now: Long): String {
    if (ts <= 0L) return ""
    val diff = now - ts
    if (diff in 0 until 60_000L) return "à l'instant"
    if (diff < 60 * 60_000L) return "il y a %d min".format(diff / 60_000L)
    val cTs = Calendar.getInstance().apply { timeInMillis = ts }
    val cNow = Calendar.getInstance().apply { timeInMillis = now }
    val sameDay = cTs.get(Calendar.YEAR) == cNow.get(Calendar.YEAR) &&
        cTs.get(Calendar.DAY_OF_YEAR) == cNow.get(Calendar.DAY_OF_YEAR)
    if (sameDay) return "%d:%02d".format(cTs.get(Calendar.HOUR_OF_DAY), cTs.get(Calendar.MINUTE))
    val daysBack = dayIndex(cTs) - dayIndex(cNow)
    return when (abs(daysBack)) {
        1L -> "Hier"
        in 0L..6L -> lc(cTs.get(Calendar.DAY_OF_WEEK), cTs)
        else -> "%02d/%02d".format(cTs.get(Calendar.DAY_OF_MONTH), cTs.get(Calendar.MONTH) + 1)
    }
}

/** Trois lettres de jour pour le "lun. 12" (calendrier → FR en dur, pas de locale). */
private fun lc(dow: Int, c: Calendar): String {
    val names = arrayOf("", "dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam.")
    return "%s %d".format(names[dow], c.get(Calendar.DAY_OF_MONTH))
}

/**
 * Libellé d'un séparateur de jour dans la timeline :
 * aujourd'hui → "Aujourd'hui" ; -1 → "Hier" ; sinon "lun. 12 janv.".
 */
fun dayLabel(ts: Long, now: Long): String {
    val cTs = Calendar.getInstance().apply { timeInMillis = ts }
    val cNow = Calendar.getInstance().apply { timeInMillis = now }
    return when (dayIndex(cTs) - dayIndex(cNow)) {
0L -> "Aujourd'hui"
-1L -> "Hier"
        else -> {
            val months = arrayOf(
                "janv.", "févr.", "mars", "avr.", "mai", "juin",
                "juil.", "août", "sept.", "oct.", "nov.", "déc."
            )
            val dow = cTs.get(Calendar.DAY_OF_WEEK)
            val names = arrayOf("", "dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam.")
            "%s %d %s".format(names[dow], cTs.get(Calendar.DAY_OF_MONTH), months[cTs.get(Calendar.MONTH)])
        }
    }
}

/** Vrai si un séparateur de jour doit précéder ce message (premier de la liste ou changement de jour). */
fun needsDaySeparator(ts: Long, prevTs: Long?): Boolean {
    if (prevTs == null) return true
    return dayIndex(Calendar.getInstance().apply { timeInMillis = ts }) !=
        dayIndex(Calendar.getInstance().apply { timeInMillis = prevTs })
}

/** Clé de jour absolue (jours depuis l'époque, en heures locales) — ignore l'heure du jour. */
fun dayIndex(c: Calendar): Long {
    val ms = c.timeInMillis
    return Math.floorDiv(ms + c.timeZone.getOffset(ms), 86_400_000L)
}
