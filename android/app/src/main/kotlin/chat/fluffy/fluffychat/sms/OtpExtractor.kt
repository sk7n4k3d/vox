package chat.fluffy.fluffychat.sms

/**
 * Détection d'un code OTP / 2FA dans le corps d'un SMS, pour proposer une action
 * « Copier le code » dans la notification. Pur regex, SANS Google Play Services
 * (marche sur GrapheneOS). Inspiré de jd1378/otphelper (CodeExtractor).
 */
object OtpExtractor {

    // Mots-clés (FR + EN) signalant un message de code à usage unique. Exiger au
    // moins un évite les faux positifs (numéros de tél, montants, dates, heures).
    private val KEYWORDS = listOf(
        "code", "otp", "vérif", "verif", "mot de passe", "password", "sécur",
        "secur", "2fa", "authentif", "auth", "identifiant", "validation",
        "confirmation", "usage unique", "one-time", "one time", "ne partagez",
        "do not share", "ne le partagez", "code pin", "pin ", "connexion",
        "log in", "login", "sign in",
    )

    // Code : 4 à 8 chiffres, éventuellement coupés UNE fois par un espace ou un
    // tiret (« 123-456 », « 123 456 »). Les anti-bornes [0-9] empêchent d'attraper
    // un fragment d'un nombre plus long (numéro de téléphone, montant).
    private val CODE_REGEX =
        Regex("""(?<![0-9])(\d{3}[ -]\d{3}|\d{4,8})(?![0-9])""")

    /** Retourne le code OTP (chiffres seuls, séparateurs retirés) si le SMS en
     *  contient un, sinon null. */
    fun extract(body: String?): String? {
        if (body.isNullOrBlank()) return null
        val lower = body.lowercase()
        if (KEYWORDS.none { lower.contains(it) }) return null
        val match = CODE_REGEX.find(body) ?: return null
        return match.value.replace(Regex("[ -]"), "")
    }
}
