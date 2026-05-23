package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.State
import androidx.compose.ui.platform.LocalContext
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomMessage
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomMessagesRepository
import kotlinx.coroutines.flow.map

sealed class MessagesUiState {
    data object Loading : MessagesUiState()
    data object Empty : MessagesUiState()
    data class Ready(val messages: List<RoomMessage>) : MessagesUiState()
}

/**
 * Hook composable qui crée un RoomMessagesRepository scoped au roomId
 * et expose son StateFlow comme un Compose State.
 */
@Composable
fun rememberRoomMessagesState(roomId: String): State<MessagesUiState> {
    val context = LocalContext.current.applicationContext
    val repo = remember(roomId) { RoomMessagesRepository(context, roomId) }
    val flow = remember(repo) {
        repo.snapshots().map { snap ->
            if (snap.messages.isEmpty()) MessagesUiState.Empty
            else MessagesUiState.Ready(snap.messages) as MessagesUiState
        }
    }
    return flow.collectAsState(initial = MessagesUiState.Loading)
}
