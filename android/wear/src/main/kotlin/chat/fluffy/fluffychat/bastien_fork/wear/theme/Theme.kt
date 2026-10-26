package chat.fluffy.fluffychat.bastien_fork.wear.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Typography
import chat.fluffy.fluffychat.bastien_fork.wear.R

// Palette CYBERCORE alignée avec le phone (FluffyColors), revue pour la
// lisibilité sur le cadran (contrastes AA+ sur noir, surfaces étagées).
private val CyberCyan = Color(0xFF00F0FF)
private val CyberCyanDim = Color(0xFF0891B2)
private val CyberMagenta = Color(0xFFFF2E92)
private val CyberMagentaDim = Color(0xFFBE2B6E)
private val CyberViolet = Color(0xFFA78BFA)
private val CyberVioletDim = Color(0xFF7C5BE3)
private val CyberWarn = Color(0xFFFCEE0A)
private val CyberSuccess = Color(0xFF05FFA1)

// Backgrounds calibrés AOD-safe (Pure Black sur AOD pour éviter le burn-in
// sur AMOLED Galaxy Watch Ultra ; surfaces légèrement décalées pour la
// hiérarchie quand l'écran est actif).
private val CyberBg = Color(0xFF000000)              // AOD-safe pur
private val CyberSurfaceLow = Color(0xFF0A0511)
private val CyberSurface = Color(0xFF130A1F)
private val CyberSurfaceHigh = Color(0xFF1F1233)
private val CyberOnSurface = Color(0xFFF3EFFA)       // ~96% white — texte le plus présent possible
private val CyberOnSurfaceVariant = Color(0xFFC3B9D6) // rehaussé : 12sp reste lisible sur noir

private val CyberpunkColors = ColorScheme(
    primary = CyberCyan,
    primaryDim = CyberCyanDim,
    primaryContainer = CyberCyan.copy(alpha = 0.18f),
    onPrimary = CyberBg,
    onPrimaryContainer = CyberCyan,
    secondary = CyberMagenta,
    secondaryDim = CyberMagentaDim,
    secondaryContainer = CyberMagenta.copy(alpha = 0.18f),
    onSecondary = CyberBg,
    onSecondaryContainer = CyberMagenta,
    tertiary = CyberViolet,
    tertiaryDim = CyberVioletDim,
    tertiaryContainer = CyberViolet.copy(alpha = 0.18f),
    onTertiary = CyberBg,
    onTertiaryContainer = CyberViolet,
    surfaceContainerLow = CyberSurfaceLow,
    surfaceContainer = CyberSurface,
    surfaceContainerHigh = CyberSurfaceHigh,
    onSurface = CyberOnSurface,
    onSurfaceVariant = CyberOnSurfaceVariant,
    outline = CyberViolet.copy(alpha = 0.45f),
    outlineVariant = CyberViolet.copy(alpha = 0.22f),
    background = CyberBg,
    onBackground = CyberOnSurface,
    error = CyberMagenta,
    errorDim = CyberMagentaDim,
    errorContainer = CyberMagenta.copy(alpha = 0.18f),
    onError = CyberBg,
    onErrorContainer = CyberMagenta
)

// Fonts custom Wear : Rajdhani (titres, signature du fork) + Inter (lecture).
private val Rajdhani = FontFamily(
    Font(R.font.rajdhani, FontWeight.Normal),
    Font(R.font.rajdhani_semibold, FontWeight.SemiBold),
    Font(R.font.rajdhani_bold, FontWeight.Bold),
)

private val Inter = FontFamily(
    Font(R.font.inter, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
)

// Rampe 2026-10-26 — repensée pour le poignet : le corps de message passe de
// 11 à 15sp (minimum confortable sur 1,5"), les titres de room à 17sp, les
// horodatages restent petits mais montent d'un cran.
private val CyberpunkTypography = Typography(
    // Display = Rajdhani Bold, entêtes d'écran.
    displayLarge = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.Bold, fontSize = 28.sp, letterSpacing = (-0.5).sp),
    displayMedium = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.Bold, fontSize = 24.sp, letterSpacing = (-0.4).sp),
    displaySmall = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 20.sp),

    // Title = Rajdhani SemiBold : noms de rooms, en-têtes de cartes.
    titleLarge = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 17.sp),
    titleMedium = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 15.sp),
    titleSmall = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, letterSpacing = 0.1.sp),

    // Body = Inter : le vrai contenu. bodyLarge est la taille des messages.
    bodyLarge = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 20.sp),
    bodyMedium = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 19.sp),
    bodySmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp),

    // Labels = Inter Medium, capitales espacées pour les micro-informations.
    labelLarge = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 13.sp, letterSpacing = 0.2.sp),
    labelMedium = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 11.sp, letterSpacing = 0.6.sp),
    labelSmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.sp, letterSpacing = 0.8.sp),
)

@Composable
fun CyberpunkWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CyberpunkColors,
        typography = CyberpunkTypography,
        content = content
    )
}

// Tokens exportés pour usage direct (glow accents, espacements, rayons).
object CyberTokens {
    val cyan = CyberCyan
    val magenta = CyberMagenta
    val violet = CyberViolet
    val warn = CyberWarn
    val success = CyberSuccess
}

/** Espacements et rayons du design system Wear — une seule échelle pour tous les écrans. */
object WearDimens {
    val gapXs = 2.dp
    val gapSm = 4.dp
    val gapMd = 8.dp
    val gapLg = 12.dp
    val gapXl = 16.dp
    val bubbleCorner = 18.dp
    val bubbleTail = 6.dp
    val cardCorner = 20.dp
}
