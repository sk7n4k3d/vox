package chat.fluffy.fluffychat.bastien_fork.wear.ui

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64 as AndroidBase64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.concurrent.futures.await
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.FailureConfirmationDialog
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SuccessConfirmationDialog
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.curvedText
import androidx.wear.remote.interactions.RemoteActivityHelper
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomEntry
import chat.fluffy.fluffychat.bastien_fork.wear.data.RoomMessage
import chat.fluffy.fluffychat.bastien_fork.wear.theme.CyberTokens
import chat.fluffy.fluffychat.bastien_fork.wear.theme.WearDimens
import chat.fluffy.fluffychat.bastien_fork.wear.voice.AudioStore
import chat.fluffy.fluffychat.bastien_fork.wear.voice.AudioState
import chat.fluffy.fluffychat.bastien_fork.wear.voice.RecordingState
import chat.fluffy.fluffychat.bastien_fork.wear.voice.UploadState
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoicePlayer
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceRecordingService
import chat.fluffy.fluffychat.bastien_fork.wear.voice.VoiceUploader
import kotlinx.coroutines.launch

/**
 * Conversation — refonte premium 2026-10-26.
 *
 * Nouveautés contre la V2 « moche » :
 *  - scroll automatique vers le dernier message (l'appelant du bug historique) ;
 *  - séparateurs de jour (Aujourd'hui / Hier / lun. 12 janv.) ;
 *  - bulles asymétriques à queue : les miennes en dégradé cyan→violet avec halo,
 *    celles des autres en surface + nom de l'expéditeur ;
 *  - corps de message en 15sp (contre 11sp — illisibles au poignet) ;
 *  - pastille vocale : onde animée + durée, tap = écoute directe sur la montre
 *    (transfert à la demande depuis le phone, plus d'ouverture d'une page phone) ;
 *  - enregistrement : bandeau dégradé magenta avec waveform vivante, minuteur et
 *    consigne explicite, plus de bannière texte grise ;
 *  - bouton bord : icônes vectorielles (mic → stop), spinner pendant l'envoi.
 */
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

    // Quitter la conversation stoppe la lecture en cours.
    DisposableEffect(Unit) {
        onDispose { VoicePlayer.stop() }
    }

    val room = remember(roomListState, roomId) {
        when (val s = roomListState) {
            is RoomListUiState.Ready ->
                s.snapshot.favorites.firstOrNull { it.id == roomId }
                    ?: s.snapshot.recents.firstOrNull { it.id == roomId }
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
                if (!s.autoUpload) {
                    VoiceUploader.upload(context, s.roomId, s.file, s.durationMs)
                }
                VoiceRecordingService.resetState()
            }
            is RecordingState.Error -> VoiceRecordingService.resetState()
            else -> Unit
        }
    }

    val isRecording = recordingState is RecordingState.Recording
    val isUploading = uploadState is UploadState.Uploading || uploadState is UploadState.WaitingAck

    val messages = (messagesState as? MessagesUiState.Ready)?.messages ?: emptyList()

    // ---- Scroll automatique ----
    // Uniquement à l'arrivée de messages. L'enregistrement ne défile plus :
    // son bandeau est un overlay fixe (bug terrain 2026-10-26 : le saut de
    // liste au début du vocal emportait l'écran et le point d'envoi hors zone).
    LaunchedEffect(messages.size) {
        if (messages.size > 0) {
            scrollState.animateScrollToItem(messages.size)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
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
            item(key = "header") {
                RoomHeader(room = room, fallbackId = roomId, messagesState = messagesState)
            }

            when (val s = messagesState) {
                is MessagesUiState.Loading -> item(key = "skeleton") {
                    Column {
                        repeat(2) { i ->
                            ShimmerBlock(
                                modifier = Modifier.padding(
                                    top = if (i == 0) WearDimens.gapMd else WearDimens.gapSm
                                ),
                                height = if (i % 2 == 0) 44.dp else 60.dp
                            )
                        }
                    }
                }
                is MessagesUiState.Empty -> item(key = "empty") {
                    CenteredHint("Aucun message — appuie sur le micro pour parler")
                }
                is MessagesUiState.Ready -> {
                    s.messages.forEachIndexed { index, msg ->
                        val prevTs = s.messages.getOrNull(index - 1)?.ts
                        if (needsDaySeparator(msg.ts, prevTs)) {
                            item(key = "day-${msg.id}") {
                                DateSeparator(dayLabel(msg.ts, System.currentTimeMillis()))
                            }
                        }
                        item(key = msg.id) {
                            MessageBubble(msg, roomId)
                        }
                    }
                }
            }

        }
    }

        // Bandeau d'enregistrement : overlay fixe, jamais dans le défilé.
        AnimatedVisibility(
            visible = isRecording,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(120)),
            modifier = Modifier.align(Alignment.BottomCenter)
        ) {
            RecordingPill(recordingState)
        }
    }

    // Confirmation dialogs Wear M3 — haptic auto à l'apparition.
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

/* ============================ Bulles ============================ */

@Composable
private fun MessageBubble(msg: RoomMessage, roomId: String) {
    val cs = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val openOnPhone: () -> Unit = {
        scope.launch { openMessageOnPhone(context, roomId = roomId, eventId = msg.id) }
    }
    // Le vocal s'écoute ici (bouton propre dans AudioContent) ; les autres médias
    // restent « ouvrir sur le téléphone » (non transférables sur la montre).
    val mediaClickable = msg.type == "video" || msg.type == "image" || msg.type == "file"

    val bubbleShape = if (msg.isOwn) {
        RoundedCornerShape(
            topStart = WearDimens.bubbleCorner, topEnd = WearDimens.bubbleCorner,
            bottomStart = WearDimens.bubbleCorner, bottomEnd = WearDimens.bubbleTail
        )
    } else {
        RoundedCornerShape(
            topStart = WearDimens.bubbleCorner, topEnd = WearDimens.bubbleCorner,
            bottomStart = WearDimens.bubbleTail, bottomEnd = WearDimens.bubbleCorner
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = if (msg.isOwn) 26.dp else 2.dp,
                end = if (msg.isOwn) 2.dp else 26.dp,
                top = WearDimens.gapXs, bottom = WearDimens.gapXs
            )
    ) {
        val bubbleModifier = if (msg.isOwn) {
            Modifier
                .glow(color = CyberTokens.cyan.copy(alpha = 0.5f), radius = 7.dp)
                .clip(bubbleShape)
                .background(VoxGradients.ownBubble)
        } else {
            Modifier
                .clip(bubbleShape)
                .background(cs.surfaceContainer)
        }
        Column(
            modifier = bubbleModifier
                .then(
                    if (mediaClickable) Modifier.clickable(onClick = openOnPhone) else Modifier
                )
                .padding(horizontal = 11.dp, vertical = 8.dp)
        ) {
            if (!msg.isOwn && msg.senderName.isNotBlank()) {
                Text(
                    text = msg.senderName,
                    style = MaterialTheme.typography.labelMedium,
                    color = CyberTokens.violet,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(modifier = Modifier.size(2.dp))
            }
            when {
                msg.isRedacted -> Text(
                    text = "Message supprimé",
                    style = MaterialTheme.typography.bodyMedium,
                    fontStyle = FontStyle.Italic,
                    color = cs.onSurfaceVariant
                )
                msg.type == "audio" -> AudioContent(msg, roomId)
                msg.type == "image" -> ImageContent(msg, "Photo")
                msg.type == "video" -> VideoContent(msg)
                msg.type == "file" -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("📄", fontSize = 13.sp)
                    Text(
                        text = " ${msg.body.ifBlank { "Fichier" }}",
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                msg.type == "system" -> Text(
                    text = msg.body,
                    style = MaterialTheme.typography.bodySmall,
                    color = cs.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
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
                        style = MaterialTheme.typography.bodyLarge
                    )
                }
            }
            // Horodatage discret en pied de bulle
            Text(
                text = clockOf(msg.ts),
                style = MaterialTheme.typography.labelSmall,
                color = cs.onSurfaceVariant.copy(alpha = 0.75f),
                modifier = Modifier
                    .align(if (msg.isOwn) Alignment.End else Alignment.Start)
                    .padding(top = 2.dp)
            )
        }
    }
}

/* -------- Contenu média -------- */

@Composable
private fun AudioContent(msg: RoomMessage, roomId: String) {
    val cs = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val states by AudioStore.states.collectAsStateWithLifecycle()
    val playingId by VoicePlayer.playingId.collectAsStateWithLifecycle()
    val state = states[msg.id]
    val isPlaying = playingId == msg.id
    val isRequesting = state is AudioState.Requesting
    val failure = state as? AudioState.Failed

    // Le vocal demandé s'est chargé → lecture immédiate.
    LaunchedEffect(state) {
        val ready = state as? AudioState.Ready ?: return@LaunchedEffect
        if (VoicePlayer.playingId.value != msg.id) VoicePlayer.toggle(msg.id, ready.file)
    }

    val onToggle: () -> Unit = {
        val cached = AudioStore.cachedFile(context, msg.id)
        when {
            cached != null -> VoicePlayer.toggle(msg.id, cached)
            !isRequesting -> scope.launch { AudioStore.requestAudio(context, roomId, msg.id) }
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clickable(onClick = onToggle)
    ) {
        Box(
            modifier = Modifier
                .size(26.dp)
                .clip(CircleShape)
                .background(
                    when {
                        failure != null -> cs.error.copy(alpha = 0.35f)
                        isPlaying -> CyberTokens.cyan.copy(alpha = 0.45f)
                        msg.isOwn -> CyberTokens.cyan.copy(alpha = 0.30f)
                        else -> CyberTokens.violet.copy(alpha = 0.30f)
                    }
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = if (isPlaying) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                contentDescription = if (isPlaying) "Arrêter" else "Écouter sur la montre",
                modifier = Modifier.size(16.dp),
                tint = when {
                    failure != null -> cs.error
                    msg.isOwn -> CyberTokens.cyan
                    else -> CyberTokens.violet
                }
            )
        }
        Spacer(modifier = Modifier.size(WearDimens.gapMd))
        WaveformBars(
            active = isPlaying || isRequesting,
            bars = 7,
            height = 16.dp,
            color = if (failure != null) cs.error else cs.onSurfaceVariant
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = when {
                failure != null -> "✕ ${failure.reason}".let { if (it.length > 14) it.take(13) + "…" else it }
                isRequesting -> "…"
                else -> formatDuration(msg.audioDurationMs ?: 0)
            },
            style = MaterialTheme.typography.labelMedium,
            color = if (failure != null) cs.error else cs.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun ImageContent(msg: RoomMessage, label: String) {
    val thumb = remember(msg.id, msg.thumbBase64) {
        msg.thumbBase64?.let { decodeBase64Bitmap(it) }
    }
    if (thumb != null) {
        Image(
            bitmap = thumb,
            contentDescription = label,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp)),
            contentScale = ContentScale.FillWidth
        )
    } else {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = "🖼 ${msg.body}", style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun VideoContent(msg: RoomMessage) {
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
                .size(44.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.55f))
                .align(Alignment.Center),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Filled.PlayArrow,
                contentDescription = "Lire vidéo",
                modifier = Modifier.size(26.dp),
                tint = Color.White
            )
        }
    }
}

/* -------- Enregistrement -------- */

/**
 * Bandeau d'enregistrement : remplace l'ancienne bannière texte. Dégradé
 * magenta, waveform vivante, minuteur, consigne — et le message implicite
 * « appuie sur le bouton bord pour envoyer ».
 */
@Composable
private fun RecordingPill(state: RecordingState) {
    val ms = (state as? RecordingState.Recording)?.elapsedMs ?: 0
    val pulse = rememberInfiniteTransition(label = "rec-pulse")
    val scale by pulse.animateFloat(
        initialValue = 0.92f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(tween(600, easing = EaseInOut), RepeatMode.Reverse),
        label = "rec-scale"
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 12.dp)
            .glow(color = CyberTokens.magenta, radius = 9.dp)
            .clip(CircleShape)
            .background(VoxGradients.record)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .scale(scale)
                .clip(CircleShape)
                .background(Color.White)
        )
        Text(
            text = formatDuration(ms),
            style = MaterialTheme.typography.titleLarge,
            color = Color.White,
            modifier = Modifier.padding(start = WearDimens.gapMd)
        )
        Spacer(modifier = Modifier.weight(1f))
        WaveformBars(active = true, bars = 5, height = 15.dp, color = Color.White)
    }
    Text(
        text = "Appuie sur le bord pour envoyer",
        style = MaterialTheme.typography.labelSmall,
        color = CyberTokens.magenta,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = WearDimens.gapSm)
    )
}

/* -------- Bouton bord mic -------- */

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

    val infinite = rememberInfiniteTransition(label = "mic-pulse")
    val pulseAlpha by infinite.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 700, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse-alpha"
    )
    val containerColor = when {
        isUploading -> cs.surfaceContainerHigh
        isRecording -> cs.secondary.copy(alpha = pulseAlpha)
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
                if (isRecording) HapticFeedbackType.LongPress
                else HapticFeedbackType.VirtualKey
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
        Row(verticalAlignment = Alignment.CenterVertically) {
            when {
                isUploading -> {
                    WaveformBars(active = true, bars = 3, height = 12.dp, color = contentColor)
                    Text(
                        text = "  " + uploadHintText(uploadState),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = contentColor
                    )
                }
                isRecording -> {
                    val ms = (recordingState as? RecordingState.Recording)?.elapsedMs ?: 0
                    Icon(
                        imageVector = Icons.Filled.Stop,
                        contentDescription = "Stop",
                        modifier = Modifier.size(15.dp)
                    )
                    Text(
                        text = " " + formatDuration(ms),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = contentColor
                    )
                }
                else -> {
                    Icon(
                        imageVector = Icons.Filled.Mic,
                        contentDescription = "Message vocal",
                        modifier = Modifier.size(17.dp)
                    )
                    Text(
                        text = " Vocal",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(start = WearDimens.gapSm)
                    )
                }
            }
        }
    }
}

/* -------- En-tête, utilitaires -------- */

@Composable
private fun RoomHeader(room: RoomEntry?, fallbackId: String, messagesState: MessagesUiState) {
    val cs = MaterialTheme.colorScheme
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = WearDimens.gapSm)
    ) {
        GradientAvatar(
            seed = room?.id ?: fallbackId,
            initial = room?.name?.firstOrNull()?.uppercaseChar()?.toString() ?: "?",
            size = 34.dp
        )
        Column(modifier = Modifier.padding(start = WearDimens.gapMd)) {
            Text(
                text = room?.name ?: "…",
                style = MaterialTheme.typography.titleLarge,
                color = cs.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = when (messagesState) {
                    is MessagesUiState.Loading -> "sync…"
                    else -> if (room?.isEncrypted == true) "chiffré · E2EE" else "en direct"
                },
                style = MaterialTheme.typography.labelSmall,
                color = if (room?.isEncrypted == true) CyberTokens.success else cs.onSurfaceVariant
            )
        }
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
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

/**
 * Ouvre la room/event sur le phone via RemoteActivityHelper (deep link matrix.to).
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
        // fail silencieux — rien d'autre à faire depuis la montre
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

private fun uploadHintText(state: UploadState): String = when (state) {
    is UploadState.Uploading -> "Envoi ${state.attempt}/3"
    is UploadState.WaitingAck -> "Confirm…"
    is UploadState.Success -> "Envoyé"
    is UploadState.Error -> "Échec"
    else -> ""
}

private fun clockOf(ts: Long): String {
    if (ts <= 0L) return ""
    val c = java.util.Calendar.getInstance().apply { timeInMillis = ts }
    return "%d:%02d".format(c.get(java.util.Calendar.HOUR_OF_DAY), c.get(java.util.Calendar.MINUTE))
}
