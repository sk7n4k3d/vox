package chat.fluffy.fluffychat.bastien_fork.wear.ui

import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Logique pure de la refonte : formats de durée, horodatages relatifs et
 * séparateurs de jour. Fusionner ces règles dans les écrans avait précisément
 * produit les incohérences de la V2.
 */
class FormatTest {

    private val tz = TimeZone.getTimeZone("Europe/Paris")
    private val day = 86_400_000L

    // Le code de prod utilise Calendar.getInstance() (tz système) : on épingle la
    // JVM sur le fuseau du téléphone pour que le test soit déterministe.
    @Before fun pinTz() { TimeZone.setDefault(tz) }
    @After fun restoreTz() { TimeZone.setDefault(null) }

    private fun at(dayOffset: Int, hour: Int, minute: Int = 0): Long {
        // 2026-10-26 00:00 local comme référence — heures ajoutées sans jamais
        // dépasser 23h59 pour que le jour calendaire soit exactement celui voulu.
        val cal = Calendar.getInstance(tz).apply {
            clear()
            set(2026, Calendar.OCTOBER, 26, 0, 0, 0)
        }
        return cal.timeInMillis + dayOffset * day + hour * 3_600_000L + minute * 60_000L
    }

    @Test fun `duree formate en mm ss`() {
        assertEquals("0:00", formatDuration(0))
        assertEquals("0:07", formatDuration(7_400))
        assertEquals("1:05", formatDuration(65_000))
        assertEquals("12:34", formatDuration(754_000))
    }

    @Test fun `stamp court — a l instant, minutes, heure, hier`() {
        val now = at(0, 9)
        assertEquals("à l'instant", shortStamp(now - 5_000, now))
        assertEquals("il y a 4 min", shortStamp(now - 4 * 60_000L, now))
        assertEquals("il y a 10 min", shortStamp(now - 10 * 60_000L, now))
        assertEquals("2:00", shortStamp(at(0, 2), now))
        assertEquals("Hier", shortStamp(at(-1, 9), now))
    }

    @Test fun `separateur de jour — premier message et changement de jour`() {
        assertTrue(needsDaySeparator(at(0, 9), null))
        assertFalse(needsDaySeparator(at(0, 9, 30), at(0, 9)))
        assertTrue(needsDaySeparator(at(1, 0, 5), at(0, 23, 55)))
    }

    @Test fun `libelle de jour — aujourdhui hier et date longue`() {
        val now = at(0, 12)
        assertEquals("Aujourd'hui", dayLabel(at(0, 10), now))
        assertEquals("Hier", dayLabel(at(-1, 22), now))
        // 2026-10-23 était un vendredi
        assertEquals("ven. 23 oct.", dayLabel(at(-3, 8), now))
    }
}
