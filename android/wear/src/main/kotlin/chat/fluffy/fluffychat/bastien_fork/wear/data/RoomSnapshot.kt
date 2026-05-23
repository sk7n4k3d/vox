package chat.fluffy.fluffychat.bastien_fork.wear.data

import kotlinx.serialization.Serializable

/**
 * Contrat DataItem `/wear/rooms` partagé entre le phone (fork FluffyChat) et la watch.
 * Version 1 — étoffé en vague 2 si besoin (audio preview duration, draft, etc.).
 */
@Serializable
data class RoomsSnapshot(
    val version: Int = 1,
    val updatedAt: Long = 0L,
    val favorites: List<RoomEntry> = emptyList(),
    val recents: List<RoomEntry> = emptyList()
)

@Serializable
data class RoomEntry(
    val id: String,
    val name: String,
    val avatarMxc: String? = null,
    val unread: Int = 0,
    val highlight: Int = 0,
    val lastEventTs: Long = 0L,
    val preview: String = "",
    val isDirect: Boolean = false,
    val isEncrypted: Boolean = false
)
