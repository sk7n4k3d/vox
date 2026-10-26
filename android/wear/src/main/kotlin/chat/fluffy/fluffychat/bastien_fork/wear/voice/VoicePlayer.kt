package chat.fluffy.fluffychat.bastien_fork.wear.voice

import android.media.AudioAttributes
import android.media.MediaPlayer
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File

/**
 * Lecteur mono-voix des vocaux Matrix sur la montre : un seul fichier joué à
 * la fois, relâché à la fin ou quand un autre prend la main.
 */
object VoicePlayer {

    private var player: MediaPlayer? = null

    /** eventId du vocal en cours de lecture (null = rien). */
    val playingId = MutableStateFlow<String?>(null)

    /** Démarre [file] ; si c'est déjà lui, le stoppe. Retour true si lecture. */
    fun toggle(eventId: String, file: File): Boolean {
        if (playingId.value == eventId) {
            stop()
            return false
        }
        stop()
        return try {
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                setDataSource(file.absolutePath)
                setOnCompletionListener { stop() }
                setOnErrorListener { _, _, _ -> stop(); true }
                prepare()
                start()
            }
            playingId.value = eventId
            true
        } catch (t: Throwable) {
            stop()
            false
        }
    }

    fun stop() {
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
        playingId.value = null
    }
}
