package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Sync
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.Card
import androidx.wear.compose.material3.CardDefaults
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import chat.fluffy.fluffychat.bastien_fork.wear.R
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomEntry
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberTokens
import chat.fluffy.fluffychat.bastien_fork.wear.theme.WearDimens

/**
 * Liste des conversations — refonte 2026-10-26.
 *
 * Ce que la version premium change par rapport à la V2 :
 *  - en-tête titre + pastille d'état de synchro (le « … » éternel n'explique
 *    rien : ici on dit si le téléphone vient de pousser ou non) ;
 *  - squelettes shimmer au lieu d'un point d'interrogation pendant le chargement ;
 *  - cartes : avatar à anneau dégradé 40dp, nom en 17sp, horodatage relatif,
 *    aperçu 2 lignes, compteur non-lus en pastille (mention = magenta) ;
 *  - bouton Actualiser en pastille discrete en bas de liste.
 */
@Composable
fun RoomListScreen(
    viewModel: RoomListViewModel = viewModel(),
    onRoomClick: (RoomEntry) -> Unit = {}
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val scrollState = rememberTransformingLazyColumnState()

    // Rotary bezel Galaxy Watch Ultra : géré nativement par ScreenScaffold + TLC (1.6+).
    ScreenScaffold(scrollState = scrollState) { contentPadding ->
        TransformingLazyColumn(
            state = scrollState,
            contentPadding = contentPadding
        ) {
            item(key = "header") {
                ListHeaderRow(
                    syncing = state is RoomListUiState.Loading,
                    lastSyncMs = (state as? RoomListUiState.Ready)?.snapshot?.updatedAt
                )
            }

            when (val s = state) {
                is RoomListUiState.Loading -> item(key = "skeleton") {
                    Column {
                        repeat(3) { i ->
                            ShimmerBlock(
                                modifier = Modifier.padding(
                                    top = if (i == 0) WearDimens.gapMd else WearDimens.gapSm
                                )
                            )
                        }
                    }
                }

                is RoomListUiState.Empty -> item(key = "empty") {
                    EmptyState(onRefresh = { viewModel.requestRefresh() })
                }

                is RoomListUiState.Ready -> {
                    if (s.snapshot.favorites.isNotEmpty()) {
                        item(key = "fav-h") {
                            SectionHeader(stringResource(R.string.favorites_section))
                        }
                        s.snapshot.favorites.forEach { room ->
                            item(key = room.id) { RoomCard(room = room, onClick = { onRoomClick(room) }) }
                        }
                    }
                    if (s.snapshot.recents.isNotEmpty()) {
                        item(key = "rec-h") {
                            SectionHeader(stringResource(R.string.recents_section))
                        }
                        s.snapshot.recents.forEach { room ->
                            item(key = room.id) { RoomCard(room = room, onClick = { onRoomClick(room) }) }
                        }
                    }
                    item(key = "refresh") {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Button(
                                onClick = { viewModel.requestRefresh() },
                                modifier = Modifier.padding(top = WearDimens.gapLg),
                                colors = ButtonDefaults.filledTonalButtonColors()
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.Sync,
                                    contentDescription = null,
                                    modifier = Modifier.size(15.dp),
                                    tint = CyberTokens.cyan
                                )
                                Text(
                                    text = stringResource(R.string.refresh),
                                    style = MaterialTheme.typography.labelLarge,
                                    modifier = Modifier.padding(start = WearDimens.gapMd)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/* -------- En-tête avec état de synchro -------- */

/**
 * En-tête centré et empilé : sur cadran rond, la bande horizontale du haut est
 * étroite — un titre à gauche + pastille à droite se fait rogner par le masque
 * circulaire. Centré verticalement, il reste toujours dans l'aire sure, et ça
 * fait un « header d'app » plutôt qu'une ligne de texte collée en haut.
 */
@Composable
private fun ListHeaderRow(syncing: Boolean, lastSyncMs: Long?) {
    val now = System.currentTimeMillis()
    val fresh = lastSyncMs != null && now - lastSyncMs < 90_000L
    val stamp = if (lastSyncMs == null || lastSyncMs <= 0L) {
        stringResource(R.string.sync_never)
    } else {
        shortStamp(lastSyncMs, now)
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = WearDimens.gapMd, bottom = WearDimens.gapSm),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = stringResource(R.string.rooms_title),
            style = MaterialTheme.typography.displaySmall,
            color = MaterialTheme.colorScheme.onSurface
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(top = 2.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            syncing -> CyberTokens.warn
                            fresh -> CyberTokens.success
                            else -> Color(0xFF6B7280)
                        }
                    )
            )
            Text(
                text = if (syncing) "synchro…" else stamp,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 5.dp)
            )
        }
    }
}

/* -------- Cartes -------- */

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 6.dp, top = WearDimens.gapLg, bottom = WearDimens.gapSm),
        style = MaterialTheme.typography.labelSmall,
        color = CyberTokens.violet,
        letterSpacing = 1.1.sp
    )
}

@Composable
private fun RoomCard(room: RoomEntry, onClick: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    val hasUnread = room.unread > 0 || room.highlight > 0
    Card(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .padding(vertical = WearDimens.gapSm),
        colors = CardDefaults.cardColors(
            containerColor = if (hasUnread) cs.surfaceContainerHigh else cs.surfaceContainer,
            contentColor = cs.onSurface
        ),
        shape = RoundedCornerShape(WearDimens.cardCorner)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Top
        ) {
            GradientAvatar(
                seed = room.id,
                initial = room.name.firstOrNull()?.uppercaseChar()?.toString() ?: "?",
                size = 40.dp
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(start = WearDimens.gapMd)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = room.name,
                        style = MaterialTheme.typography.titleLarge,
                        color = if (hasUnread) cs.onSurface else cs.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (room.isEncrypted) {
                        Text(
                            text = "🔒",
                            fontSize = 9.sp,
                            modifier = Modifier.padding(start = 4.dp)
                        )
                    }
                }
                if (room.preview.isNotBlank()) {
                    Text(
                        text = room.preview,
                        style = MaterialTheme.typography.bodySmall,
                        color = cs.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 1.dp)
                    )
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = shortStamp(room.lastEventTs, System.currentTimeMillis()),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (hasUnread) CyberTokens.cyan else cs.onSurfaceVariant
                )
                if (room.highlight > 0) {
                    VoxPill(
                        text = if (room.highlight > 9) "9+" else room.highlight.toString(),
                        background = CyberTokens.magenta,
                        contentColor = Color.White,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                } else if (room.unread > 0) {
                    VoxPill(
                        text = if (room.unread > 9) "9+" else room.unread.toString(),
                        background = CyberTokens.cyan,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
            }
        }
    }
}

/* -------- États vides / chargement -------- */

@Composable
private fun EmptyState(onRefresh: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = WearDimens.gapLg),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "📡",
            fontSize = 26.sp,
            modifier = Modifier.padding(bottom = WearDimens.gapMd)
        )
        Text(
            text = stringResource(R.string.empty_rooms),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
        Button(
            onClick = onRefresh,
            modifier = Modifier.padding(top = WearDimens.gapLg),
            colors = ButtonDefaults.buttonColors(
                containerColor = CyberTokens.cyan,
                contentColor = Color.Black
            )
        ) {
            Icon(Icons.Filled.Sync, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(
                text = stringResource(R.string.refresh),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(start = WearDimens.gapMd)
            )
        }
    }
}
