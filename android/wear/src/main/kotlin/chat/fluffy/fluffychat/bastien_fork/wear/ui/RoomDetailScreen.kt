package chat.fluffy.fluffychat.bastien_fork.wear.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64 as AndroidBase64
import androidx.concurrent.futures.await
import androidx.wear.remote.interactions.RemoteActivityHelper
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.Card
import androidx.wear.compose.material3.CardDefaults
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.FailureConfirmationDialog
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SuccessConfirmationDialog
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.curvedText
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomEntry
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomMessage
import chat.fluffy.fluffychat.bastien_fork.wear.voice.RecordingState
import chat.fluffy.fluffychat.bastien_fork.wear.voice.UploadState
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceRecordingService
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader
import kotlin.math.abs

@Composable
fun RoomDetailScreen(
    roomId: String,
    onBack: () -> Unit,
    viewModel: RoomListViewModel = viewModel()
) {
    val roomListState by viewModel.state.collectAsStateWithLifecycle()
    val recordingState by VoiceRecordingService.recordingState.collectAsStateWithLifecycle()
    val uploadState by VoiceUploader.state.collectAsStateWithLifecycle()
    val messagesState by rememberRoomMessagesState(roomId)
    val context = LocalContext.current
    val scrollState = rememberTransformingLazyColumnState()
    // Rotary bezel : géré automatiquement par ScreenScaffold + TLC en Wear Compose 1.6+.
    // Pas besoin de FocusRequester ni rotaryScrollable Modifier (cf. recherche dev Wear OS 2026).

    val room = remember(roomListState, roomId) {
        when (val s = roomListState) {
            is RoomListUiState.Ready -> {
                s.snapshot.favorites.firstOrNull { it.id == roomId }
                    ?: s.snapshot.recents.firstOrNull { it.id == roomId }
            }
            else -> null
        }
    }

    var pendingStart by remember { mutableStateOf(false) }
    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted && pendingStart) {
            VoiceRecordingService.start(context, roomId)
        }
        pendingStart = false
    }

    // Quand le service finit l'enregistrement, on bascule sur upload Asset.
    LaunchedEffect(recordingState) {
        when (val s = recordingState) {
            is RecordingState.Done -> {
                VoiceUploader.upload(context, s.roomId, s.file, s.durationMs)
                VoiceRecordingService.resetState()
            }
            is RecordingState.Error -> {
                VoiceRecordingService.resetState()
            }
            else -> Unit
        }
    }

    // Pas de haptic manuel sur uploadState Success/Error :
    // SuccessConfirmationDialog / FailureConfirmationDialog M3 jouent leur haptic Confirm/Reject
    // automatiquement à l'apparition. Doubler ferait un buzz parasite.

    val isRecording = recordingState is RecordingState.Recording
    val isUploading = uploadState is UploadState.Uploading || uploadState is UploadState.WaitingAck

    ScreenScaffold(
        scrollState = scrollState,
        edgeButton = {
            MicEdgeButton(
                isRecording = isRecording,
                isUploading = isUploading,
                uploadState = uploadState,
                recordingState = recordingState,
                onTap = {
                    if (isRecording) {
                        // Tap-to-toggle : 2e tap = stop + send
                        VoiceRecordingService.stop(context)
                    } else {
                        val hasMic = ContextCompat.checkSelfPermission(
                            context,
                            Manifest.permission.RECORD_AUDIO
                        ) == PackageManager.PERMISSION_GRANTED
                        if (hasMic) {
                            VoiceRecordingService.start(context, roomId)
                        } else {
                            pendingStart = true
                            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    }
                }
            )
        }
    ) { contentPadding ->
        TransformingLazyColumn(
            state = scrollState,
            contentPadding = contentPadding
        ) {
            // Header room
            item(key = "header") {
                RoomHeader(room = room, fallbackId = roomId)
            }

            when (val s = messagesState) {
                is MessagesUiState.Loading -> {
                    item(key = "loading") {
                        CenteredHint("Chargement…")
                    }
                }
                is MessagesUiState.Empty -> {
                    item(key = "empty") {
                        CenteredHint("Aucun message")
                    }
                }
                is MessagesUiState.Ready -> {
                    items(messages = s.messages, roomId = roomId)
                }
            }

            if (isRecording) {
                item(key = "recording") {
                    RecordingBanner(recordingState)
                }
            }
        }
    }

    // Confirmation dialogs Wear M3 — overlay system-style + curved text + haptic auto.
    // Durée par défaut : ConfirmationDialogDefaults.DurationMillis (~2 s) puis auto-dismiss.
    val isSuccess = uploadState is UploadState.Success
    val isFailure = uploadState is UploadState.Error
    SuccessConfirmationDialog(
        visible = isSuccess,
        onDismissRequest = { VoiceUploader.reset() },
        curvedText = { curvedText("Vocal envoyé") },
        durationMillis = 1_800L
    )
    FailureConfirmationDialog(
        visible = isFailure,
        onDismissRequest = { VoiceUploader.reset() },
        curvedText = {
            curvedText((uploadState as? UploadState.Error)?.message ?: "Échec")
        },
        durationMillis = 2_500L
    )
}

private fun androidx.wear.compose.foundation.lazy.TransformingLazyColumnScope.items(
    messages: List<RoomMessage>,
    roomId: String
) {
    messages.forEach { msg ->
        item(key = msg.id) {
            MessageItem(msg, roomId)
        }
    }
}

@Composable
private fun MessageItem(msg: RoomMessage, roomId: String) {
    val cs = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val containerColor = if (msg.isOwn) cs.primaryContainer else cs.surfaceContainer
    val onContainerColor = if (msg.isOwn) cs.onPrimaryContainer else cs.onSurface

    val onClick: () -> Unit = remember(msg.id, msg.type, roomId) {
        when (msg.type) {
            "video", "image", "file" -> {
                {
                    scope.launch {
                        openMessageOnPhone(context, roomId = roomId, eventId = msg.id)
                    }
                }
            }
            else -> { -> {} }
        }
    }

    Card(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        colors = CardDefaults.cardColors(
            containerColor = containerColor,
            contentColor = onContainerColor
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        if (!msg.isOwn) {
            Text(
                text = msg.senderName,
                style = MaterialTheme.typography.labelSmall,
                color = cs.tertiary,
                maxLines = 1
            )
            Spacer(modifier = Modifier.size(2.dp))
        }
        when (msg.type) {
            "audio" -> AudioMessageContent(msg)
            "image" -> ImageMessageContent(msg)
            "video" -> VideoMessageContent(msg)
            "system" -> Text(
                text = msg.body,
                style = MaterialTheme.typography.bodyExtraSmall,
                color = cs.onSurfaceVariant,
                maxLines = 2
            )
            else -> {
                val rendered = remember(msg.id, msg.body, msg.formattedBody) {
                    MarkdownRenderer.render(
                        body = msg.body.ifBlank { "—" },
                        formattedBody = msg.formattedBody
                    )
                }
                Text(
                    text = rendered,
                    style = MaterialTheme.typography.bodySmall
                    // Pas de maxLines : le message complet est rendu, le TLC scroll si trop long.
                )
            }
        }
    }
}

@Composable
private fun AudioMessageContent(msg: RoomMessage) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.PlayArrow,
            contentDescription = "Vocal",
            modifier = Modifier.size(22.dp)
        )
        Spacer(modifier = Modifier.size(6.dp))
        Text(
            text = formatDuration(msg.audioDurationMs ?: 0),
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun ImageMessageContent(msg: RoomMessage) {
    val thumb = remember(msg.id, msg.thumbBase64) {
        msg.thumbBase64?.let { decodeBase64Bitmap(it) }
    }
    if (thumb != null) {
        Image(
            bitmap = thumb,
            contentDescription = "Photo",
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp)),
            contentScale = ContentScale.FillWidth
        )
    } else {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = "📷 ${msg.body}", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun VideoMessageContent(msg: RoomMessage) {
    val thumb = remember(msg.id, msg.thumbBase64) {
        msg.thumbBase64?.let { decodeBase64Bitmap(it) }
    }
    Box(modifier = Modifier.fillMaxWidth()) {
        if (thumb != null) {
            Image(
                bitmap = thumb,
                contentDescription = "Vidéo",
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp)),
                contentScale = ContentScale.FillWidth
            )
        }
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.55f))
                .align(Alignment.Center),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Filled.PlayArrow,
                contentDescription = "Lire vidéo",
                modifier = Modifier.size(28.dp),
                tint = Color.White
            )
        }
    }
}

/**
 * Ouvre la room/event sur le phone via RemoteActivityHelper.
 * Utilise un deep link matrix.to qui sera capturé par FluffyChat fork si installé,
 * sinon fallback navigateur.
 */
private suspend fun openMessageOnPhone(
    context: android.content.Context,
    roomId: String,
    eventId: String
) {
    try {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            data = Uri.parse("https://matrix.to/#/$roomId/$eventId")
        }
        RemoteActivityHelper(context).startRemoteActivity(intent).await()
    } catch (_: Throwable) {
        // fail silencieux — pas grave V1
    }
}

private fun decodeBase64Bitmap(base64: String): androidx.compose.ui.graphics.ImageBitmap? {
    return try {
        val bytes = AndroidBase64.decode(base64, AndroidBase64.DEFAULT)
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        bmp.asImageBitmap()
    } catch (_: Throwable) {
        null
    }
}

/**
 * EdgeButton mic — Wear M3 native EdgeButton (1.6.0+).
 *
 * Sprint 2 audit finding-022 (CRITICAL): le CustomEdgeMicButton précédent
 * réimplémentait l'arc maison via GenericShape mais avec une hit area
 * rectangulaire — l'utilisateur tapait "à côté" et croyait que ça ne
 * marchait pas. Le natif M3 EdgeButton gère hit area, morphing, padding
 * système, taille edge-hugging correcte.
 *
 * **Tap-to-toggle** : tap = start record, tap = stop+send.
 */
@Composable
private fun MicEdgeButton(
    isRecording: Boolean,
    isUploading: Boolean,
    uploadState: UploadState,
    recordingState: RecordingState,
    onTap: () -> Unit
) {
    val haptic = LocalHapticFeedback.current
    val cs = MaterialTheme.colorScheme
    val containerColor = when {
        isUploading -> cs.surfaceContainerHigh
        isRecording -> cs.secondary
        else -> cs.primary
    }
    val contentColor = when {
        isUploading -> cs.onSurface
        isRecording -> cs.onSecondary
        else -> cs.onPrimary
    }

    EdgeButton(
        onClick = {
            haptic.performHapticFeedback(
                if (isRecording) HapticFeedbackType.TextHandleMove
                else HapticFeedbackType.LongPress
            )
            onTap()
        },
        buttonSize = EdgeButtonSize.Large,
        enabled = !isUploading,
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = contentColor
        )
    ) {
        when {
            isUploading -> {
                Text(
                    text = uploadHintText(uploadState),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold
                )
            }
            isRecording -> {
                val ms = (recordingState as? RecordingState.Recording)?.elapsedMs ?: 0
                Text(
                    text = "● ${formatDuration(ms)}",
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp
                )
            }
            else -> {
                Text(
                    text = "🎤",
                    fontSize = 26.sp
                )
            }
        }
    }
}

@Composable
private fun RecordingBanner(state: RecordingState) {
    val ms = (state as? RecordingState.Recording)?.elapsedMs ?: 0
    Card(
        onClick = {},
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
            contentColor = MaterialTheme.colorScheme.onSecondaryContainer
        )
    ) {
        Text(
            text = "● Enregistrement   ${formatDuration(ms)}",
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun RoomHeader(room: RoomEntry?, fallbackId: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
    ) {
        SmallAvatar(
            seed = room?.id ?: fallbackId,
            initial = room?.name?.firstOrNull()?.uppercaseChar()?.toString() ?: "?"
        )
        Spacer(modifier = Modifier.size(8.dp))
        Text(
            text = room?.name ?: "…",
            style = MaterialTheme.typography.titleSmall,
            maxLines = 1,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun SmallAvatar(seed: String, initial: String) {
    val palette = listOf(
        Color(0xFF22D3EE), Color(0xFFEC4899), Color(0xFFA78BFA),
        Color(0xFF34D399), Color(0xFFFBBF24), Color(0xFFF87171),
        Color(0xFF60A5FA), Color(0xFFC084FC)
    )
    val color = palette[abs(seed.hashCode()) % palette.size]
    Box(
        modifier = Modifier
            .size(28.dp)
            .clip(CircleShape)
            .background(color),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = initial,
            color = Color.Black,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp
        )
    }
}

@Composable
private fun CenteredHint(text: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun uploadHintText(state: UploadState): String = when (state) {
    is UploadState.Uploading -> "Envoi… ${state.attempt}/3"
    is UploadState.WaitingAck -> "Confirmation…"
    is UploadState.Success -> "✓ Envoyé"
    is UploadState.Error -> "Échec"
    else -> ""
}

private fun formatDuration(ms: Int): String {
    val totalSec = ms / 1000
    val m = totalSec / 60
    val s = totalSec % 60
    return "%d:%02d".format(m, s)
}
