package chat.fluffy.fluffychat.bastien_fork.wear.ui

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomsRepository
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomsSnapshot
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

private const val TAG = "RoomListViewModel"
private const val PHONE_CAPABILITY = "fluffychat_phone"
private const val REQUEST_PATH = "/wear/rooms/request"

sealed class RoomListUiState {
    data object Loading : RoomListUiState()
    data object Empty : RoomListUiState()
    data class Ready(val snapshot: RoomsSnapshot) : RoomListUiState()
}

class RoomListViewModel(app: Application) : AndroidViewModel(app) {

    private val repo = RoomsRepository(app)
    private val messageClient by lazy { Wearable.getMessageClient(app) }
    private val capabilityClient by lazy { Wearable.getCapabilityClient(app) }

    private val _state = MutableStateFlow<RoomListUiState>(RoomListUiState.Loading)
    val state: StateFlow<RoomListUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            repo.snapshots().collect { snap ->
                _state.value = if (snap.favorites.isEmpty() && snap.recents.isEmpty()) {
                    RoomListUiState.Empty
                } else {
                    RoomListUiState.Ready(snap)
                }
            }
        }
    }

    /**
     * Envoie un MessageClient ping au phone (capability `fluffychat_phone`) pour qu'il
     * republie un DataItem `/wear/rooms` frais.
     */
    fun requestRefresh() {
        viewModelScope.launch {
            try {
                val node = findPhoneNode() ?: run {
                    Log.w(TAG, "no phone node available for refresh ping")
                    return@launch
                }
                messageClient.sendMessage(node.id, REQUEST_PATH, ByteArray(0)).await()
                Log.d(TAG, "refresh ping sent to ${node.displayName}")
            } catch (t: Throwable) {
                Log.w(TAG, "refresh ping failed", t)
            }
        }
    }

    private suspend fun findPhoneNode(): Node? {
        val info = capabilityClient.getCapability(
            PHONE_CAPABILITY,
            CapabilityClient.FILTER_REACHABLE
        ).await()
        return info.nodes.firstOrNull { it.isNearby } ?: info.nodes.firstOrNull()
    }
}
