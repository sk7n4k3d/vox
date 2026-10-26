package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberTokens
import kotlin.math.abs

/**
 * Pièces partagées du design system Wear — tout ce qui fait « premium »
 * (glow, dégradés, shimmer, waveform) vit ici pour que les écrans restent
 * descriptifs.
 */

/** Halo coloré doux — signature cybercore, posé derrière les éléments clés. */
fun Modifier.glow(color: Color = CyberTokens.cyan, radius: Dp = 10.dp): Modifier =
    this.drawBehind {
        val r = radius.toPx()
        val step = r / 3f
        for (i in 3 downTo 1) {
            drawRoundRect(
                color = color.copy(alpha = 0.10f * i),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(r),
                alpha = 1f,
                topLeft = androidx.compose.ui.geometry.Offset(-step * i / 2f, -step * i / 2f),
                size = androidx.compose.ui.geometry.Size(size.width + step * i, size.height + step * i)
            )
        }
    }

/** Dégradé signature VOX (cyan → violet), en brush pour backgrounds et bords. */
object VoxGradients {
    val accent = Brush.horizontalGradient(listOf(CyberTokens.cyan, CyberTokens.violet, CyberTokens.magenta))
    val accentVertical = Brush.verticalGradient(listOf(CyberTokens.cyan, CyberTokens.violet))
    val ownBubble = Brush.verticalGradient(
        listOf(CyberTokens.cyan.copy(alpha = 0.26f), CyberTokens.violet.copy(alpha = 0.18f))
    )
    val record = Brush.verticalGradient(listOf(CyberTokens.magenta, Color(0xFFFF6AB0)))
}

/** Avatar à anneau dégradé + initiale, couleur dérivée de la room (stable). */
@Composable
fun GradientAvatar(
    seed: String,
    initial: String,
    modifier: Modifier = Modifier,
    size: Dp = 40.dp,
    ringWidth: Dp = 2.dp,
    online: Boolean? = null
) {
    val color = avatarColor(seed)
    Box(modifier = modifier.size(size)) {
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(VoxGradients.accent)
                .padding(ringWidth)
        ) {
            Box(
                modifier = Modifier
                    .size(size - ringWidth * 2)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.30f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = initial,
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = (size.value * 0.38f).sp,
                    maxLines = 1
                )
            }
        }
        if (online != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(size * 0.28f)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.background)
                    .padding(1.5.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size((size * 0.28f - 3.dp))
                        .clip(CircleShape)
                        .background(if (online) CyberTokens.success else Color(0xFF6B7280))
                )
            }
        }
    }
}

/** Pastille (badge arrondi plein) — unread, états, compteurs. */
@Composable
fun VoxPill(
    text: String,
    modifier: Modifier = Modifier,
    background: Color = CyberTokens.cyan,
    contentColor: Color = Color.Black,
    bold: Boolean = true
) {
    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(background)
            .padding(horizontal = 7.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            color = contentColor,
            fontWeight = if (bold) FontWeight.Bold else FontWeight.Medium,
            fontSize = 10.sp,
            maxLines = 1
        )
    }
}

/**
 * Waveform animée — 5 barres cadencées en déphase. En statique (actif=false)
 * les barres se figent à hauteur moyenne : même forme au repos, en mouvement
 * pendant l'enregistrement ou l'envoi.
 */
@Composable
fun WaveformBars(
    modifier: Modifier = Modifier,
    active: Boolean = true,
    bars: Int = 5,
    height: Dp = 14.dp,
    color: Color = MaterialTheme.colorScheme.onSurface
) {
    val transition = rememberInfiniteTransition(label = "waveform")
    val tick by transition.animateFloat(
        initialValue = 0f,
        targetValue = 2f * Math.PI.toFloat(),
        animationSpec = infiniteRepeatable(tween(1100, easing = LinearEasing), RepeatMode.Restart),
        label = "tick"
    )
    Row(
        modifier = modifier.height(height),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.5.dp)
    ) {
        repeat(bars) { i ->
            val phase = i * 0.55f
            val target = if (active) 0.30f + 0.70f * (0.5f + 0.5f * Math.sin((tick + phase).toDouble()).toFloat()) else 0.55f
            val h by animateFloatAsState(targetValue = target, animationSpec = tween(160), label = "bar$i")
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height(height * h)
                    .clip(CircleShape)
                    .background(color)
            )
        }
    }
}

/** Skeleton shimmer — remplace les « … » pendant le chargement. */
@Composable
fun ShimmerBlock(
    modifier: Modifier = Modifier,
    height: Dp = 56.dp,
    corner: Dp = 18.dp
) {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val shift by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1300, easing = LinearEasing), RepeatMode.Reverse),
        label = "shift"
    )
    val base = MaterialTheme.colorScheme.surfaceContainerHigh
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(corner))
            .background(
                Brush.horizontalGradient(
                    listOf(
                        base,
                        MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.45f),
                        base
                    )
                )
            )
    )
}

/** Séparateur de jour : filet dégradé + libellé centré en capitales espacées. */
@Composable
fun DateSeparator(label: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 10.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        listOf(Color.Transparent, CyberTokens.violet.copy(alpha = 0.5f))
                    )
                )
        )
        Text(
            text = label.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = CyberTokens.violet,
            letterSpacing = 1.2.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp)
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        listOf(CyberTokens.violet.copy(alpha = 0.5f), Color.Transparent)
                    )
                )
        )
    }
}

/** Couleur d'avatar stable dérivée du seed — même palette que les anneaux. */
fun avatarColor(seed: String): Color {
    val palette = listOf(
        Color(0xFF22D3EE), Color(0xFFEC4899), Color(0xFFA78BFA),
        Color(0xFF34D399), Color(0xFFFBBF24), Color(0xFFF87171),
        Color(0xFF60A5FA), Color(0xFFC084FC)
    )
    return palette[abs(seed.hashCode()) % palette.size]
}
