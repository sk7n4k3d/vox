package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.ListHeaderDefaults
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.TitleCard
import chat.fluffy.fluffychat.bastien_fork.wear.R
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomEntry
import kotlin.math.abs

@Composable
fun RoomListScreen(
    viewModel: RoomListViewModel = viewModel(),
    onRoomClick: (RoomEntry) -> Unit = {}
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val scrollState = rememberTransformingLazyColumnState()

    // Rotary bezel Galaxy Watch Ultra : géré nativement par ScreenScaffold + TLC
    // en Wear Compose 1.6+ (pas besoin de FocusRequester manuel).

    ScreenScaffold(scrollState = scrollState) { contentPadding ->
        TransformingLazyColumn(
            state = scrollState,
            contentPadding = contentPadding
        ) {
            item {
                ListHeader(
                    modifier = Modifier
                        .fillMaxWidth()
                        .minimumVerticalContentPadding(
                            ListHeaderDefaults.minimumTopListContentPadding
                        )
                ) { Text(text = stringResource(R.string.rooms_title)) }
            }

            when (val s = state) {
                is RoomListUiState.Loading -> item { LoadingPlaceholder() }
                is RoomListUiState.Empty -> item {
                    EmptyPlaceholder(onRefresh = { viewModel.requestRefresh() })
                }
                is RoomListUiState.Ready -> {
                    if (s.snapshot.favorites.isNotEmpty()) {
                        item { SectionHeader(stringResource(R.string.favorites_section)) }
                        items(s.snapshot.favorites) { room ->
                            RoomCard(room = room, onClick = { onRoomClick(room) })
                        }
                    }
                    if (s.snapshot.recents.isNotEmpty()) {
                        item { SectionHeader(stringResource(R.string.recents_section)) }
                        items(s.snapshot.recents) { room ->
                            RoomCard(room = room, onClick = { onRoomClick(room) })
                        }
                    }
                    item {
                        Button(
                            onClick = { viewModel.requestRefresh() },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 8.dp),
                            colors = ButtonDefaults.filledTonalButtonColors()
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp)
                            )
                            Text(
                                text = "  " + stringResource(R.string.refresh),
                                style = MaterialTheme.typography.labelMedium
                            )
                        }
                    }
                }
            }
        }
    }
}

/* -------- Helpers TLC -------- */

private inline fun androidx.wear.compose.foundation.lazy.TransformingLazyColumnScope.items(
    rooms: List<RoomEntry>,
    crossinline content: @Composable (RoomEntry) -> Unit
) {
    rooms.forEach { room ->
        item(key = room.id) { content(room) }
    }
}

/* -------- Components -------- */

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 4.dp, top = 8.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun RoomCard(room: RoomEntry, onClick: () -> Unit) {
    TitleCard(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                RoomAvatar(room = room)
                Text(
                    text = room.name,
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 8.dp),
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1
                )
                if (room.highlight > 0) {
                    UnreadBadge(
                        count = room.highlight,
                        color = MaterialTheme.colorScheme.secondary
                    )
                } else if (room.unread > 0) {
                    UnreadDot(color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    ) {
        if (room.preview.isNotBlank()) {
            Text(
                text = room.preview,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2
            )
        }
    }
}

@Composable
private fun RoomAvatar(room: RoomEntry) {
    val palette = listOf(
        Color(0xFF22D3EE), Color(0xFFEC4899), Color(0xFFA78BFA),
        Color(0xFF34D399), Color(0xFFFBBF24), Color(0xFFF87171),
        Color(0xFF60A5FA), Color(0xFFC084FC)
    )
    val color = palette[abs(room.id.hashCode()) % palette.size]
    val initial = room.name.firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(color),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = initial,
            color = Color.Black,
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp
        )
    }
}

@Composable
private fun UnreadBadge(count: Int, color: Color) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(color)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = if (count > 99) "99+" else count.toString(),
            color = Color.Black,
            fontWeight = FontWeight.Bold,
            fontSize = 10.sp
        )
    }
}

@Composable
private fun UnreadDot(color: Color) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(color)
    )
}

@Composable
private fun LoadingPlaceholder() {
    Text(
        text = "…",
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 24.dp),
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun EmptyPlaceholder(onRefresh: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Row(
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = stringResource(R.string.empty_rooms),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
        Button(
            onClick = onRefresh,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 64.dp, start = 16.dp, end = 16.dp),
            colors = ButtonDefaults.filledTonalButtonColors()
        ) {
            Icon(
                imageVector = Icons.Filled.Refresh,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = "  " + stringResource(R.string.refresh),
                style = MaterialTheme.typography.labelMedium
            )
        }
    }
}
