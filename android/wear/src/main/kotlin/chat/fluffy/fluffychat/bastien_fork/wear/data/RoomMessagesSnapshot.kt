package chat.fluffy.fluffychat.bastien_fork.wear.data

import kotlinx.serialization.Serializable

/**
 * Contrat DataItem `/wear/rooms/{roomId}/messages` — 30 derniers messages d'une room.
 * Pushé par le phone à la demande (MessageClient ping watch → phone re-push).
 *
 * Limite cible : 100 KB. 30 messages × ~500 bytes JSON = ~15 KB safe.
 */
@Serializable
data class RoomMessagesSnapshot(
    val version: Int = 1,
    val roomId: String,
    val updatedAt: Long = 0L,
    val messages: List<RoomMessage> = emptyList()
)

@Serializable
data class RoomMessage(
    val id: String,
    val senderId: String,
    val senderName: String,
    val ts: Long,
    val type: String, // "text", "audio", "image", "video", "file", "sticker", "system"
    val body: String, // texte plain ou nom de fichier (fallback)
    val formattedBody: String? = null, // Matrix HTML (org.matrix.custom.html) si dispo
    val isOwn: Boolean = false,
    val audioDurationMs: Int? = null, // pour type=audio
    val isRedacted: Boolean = false,
    val thumbBase64: String? = null // JPEG q75 200x200 base64 pour image/video
)
