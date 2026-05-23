package chat.fluffy.fluffychat.bastien_fork.wear.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme

private val CyberCyan = Color(0xFF22D3EE)
private val CyberCyanDim = Color(0xFF0EA5C5)
private val CyberMagenta = Color(0xFFEC4899)
private val CyberMagentaDim = Color(0xFFBE2B6E)
private val CyberViolet = Color(0xFFA78BFA)
private val CyberVioletDim = Color(0xFF7C5BE3)
private val CyberBg = Color(0xFF0F0A1E)
private val CyberSurfaceLow = Color(0xFF130E22)
private val CyberSurface = Color(0xFF1A1428)
private val CyberSurfaceHigh = Color(0xFF221A33)
private val CyberOnSurface = Color(0xFFE8E2F4)
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
    error = Color(0xFFFF6B6B),
    errorDim = Color(0xFFCC4848),
    errorContainer = Color(0xFFFF6B6B).copy(alpha = 0.18f),
    onError = CyberBg,
    onErrorContainer = Color(0xFFFF6B6B)
)

@Composable
fun CyberpunkWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CyberpunkColors,
        content = content
    )
}
