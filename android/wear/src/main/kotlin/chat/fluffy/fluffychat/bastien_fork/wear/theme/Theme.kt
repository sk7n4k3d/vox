package chat.fluffy.fluffychat.bastien_fork.wear.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Typography
import chat.fluffy.fluffychat.bastien_fork.wear.R

// Sprint 2 V2 — palette CYBERCORE alignée avec le phone (FluffyColors).
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
private val CyberOnSurface = Color(0xFFF0EAFF)       // ~ 95% white pour contraste >7
private val CyberOnSurfaceVariant = Color(0xFFB8AECC)

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

// Sprint 2 V2 — fonts custom Wear (Rajdhani titres + Inter body).
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

private val CyberpunkTypography = Typography(
    // Display = Rajdhani Bold, room names + screen headers Wear.
    displayLarge = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.Bold, fontSize = 26.sp, letterSpacing = (-0.3).sp),
    displayMedium = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.Bold, fontSize = 22.sp),
    displaySmall = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 18.sp),

    // Title = Rajdhani SemiBold pour bubble headers / section labels.
    titleLarge = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 16.sp),
    titleMedium = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 14.sp),
    titleSmall = TextStyle(fontFamily = Rajdhani, fontWeight = FontWeight.SemiBold, fontSize = 12.sp),

    // Body = Inter pour lecture longue (timestamps, body messages, hints).
    bodyLarge = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 19.sp),
    bodyMedium = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 17.sp),
    bodySmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 11.sp, lineHeight = 14.sp),

    // Labels = Inter Medium uppercase-ish via letterSpacing.
    labelLarge = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 12.sp, letterSpacing = 0.1.sp),
    labelMedium = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.sp, letterSpacing = 0.5.sp),
    labelSmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 9.sp, letterSpacing = 0.5.sp),
)

@Composable
fun CyberpunkWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CyberpunkColors,
        typography = CyberpunkTypography,
        content = content
    )
}

// Tokens exportés pour usage direct (glow accents, etc.)
object CyberTokens {
    val cyan = CyberCyan
    val magenta = CyberMagenta
    val violet = CyberViolet
    val warn = CyberWarn
    val success = CyberSuccess
}
