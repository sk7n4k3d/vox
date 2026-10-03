package chat.fluffy.fluffychat.media

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import chat.fluffy.fluffychat.sms.SmsBridge
import java.io.File

/**
 * Copies received media (images/videos) into the public MediaStore so that
 * external gallery clients (e.g. Nextcloud auto-upload) can pick them up.
 *
 * Target collections: `Pictures/VOX` for images, `Movies/VOX` for videos
 * (RELATIVE_PATH, API 29+). Below API 29 this is a silent no-op.
 *
 * Deduplication: a persisted set of `size:contentHash` keys
 * (`vox.exported.media`) prevents re-exporting the same bytes after a reboot
 * or a UI refresh. The key is content-derived so that a file exported both by
 * the native MMS pipeline and by the Dart safety net (same bytes) is only
 * written once.
 */
object MediaExporter {

    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY_ENABLED = "flutter.chat.fluffy.auto_export_media"

    private const val PREFS = "vox_media_export"
    private const val KEY_EXPORTED = "vox.exported.media"
    private const val MAX_ENTRIES = 4000

    private val lock = Any()
    private var exported: LinkedHashSet<String>? = null

    /** Reads the Dart setting `chat.fluffy.auto_export_media` (default true). */
    fun isEnabled(context: Context): Boolean = try {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        if (!prefs.contains(KEY_ENABLED)) true else prefs.getBoolean(KEY_ENABLED, true)
    } catch (e: Exception) {
        true
    }

    /** Reads [filePath] and inserts it into MediaStore. Returns the URI or null. */
    fun export(context: Context, filePath: String, mimeType: String, displayName: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val file = File(filePath)
            if (!file.exists() || file.length() == 0L) return null
            insert(context, file.readBytes(), mimeType, displayName.ifBlank { file.name })
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MediaExporter.export failed: ${e.message}")
            null
        }
    }

    /** Inserts in-memory [data] (MMS parts) into MediaStore. Returns the URI or null. */
    fun exportBytes(context: Context, data: ByteArray, mimeType: String, displayName: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            insert(context, data, mimeType, displayName.ifBlank { "vox_${System.currentTimeMillis()}" })
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MediaExporter.exportBytes failed: ${e.message}")
            null
        }
    }

    private fun insert(context: Context, data: ByteArray, mimeType: String, displayName: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (data.isEmpty()) return null
        val mime = mimeType.substringBefore(';').trim().lowercase()
        val isImage = mime.startsWith("image/")
        val isVideo = mime.startsWith("video/")
        if (!isImage && !isVideo) return null

        val key = "${data.size}:${data.contentHashCode()}"
        if (isExported(context, key)) return null

        val collection = if (isImage) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relativePath = if (isImage) {
            "${Environment.DIRECTORY_PICTURES}/VOX"
        } else {
            "${Environment.DIRECTORY_MOVIES}/VOX"
        }

        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: return null
        try {
            val stream = resolver.openOutputStream(uri)
            if (stream == null) {
                resolver.delete(uri, null, null)
                return null
            }
            stream.use { it.write(data) }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            markExported(context, key)
            Log.i(SmsBridge.TAG, "MediaExporter: exported $displayName (${data.size} o) → $uri")
            return uri.toString()
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            Log.e(SmsBridge.TAG, "MediaExporter.insert failed: ${e.message}")
            return null
        }
    }

    private fun isExported(context: Context, key: String): Boolean = try {
        synchronized(lock) { exportedSet(context).contains(key) }
    } catch (e: Exception) {
        false
    }

    private fun markExported(context: Context, key: String) {
        try {
            synchronized(lock) {
                val set = exportedSet(context)
                set.add(key)
                while (set.size > MAX_ENTRIES) {
                    val first = set.firstOrNull() ?: break
                    set.remove(first)
                }
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet(KEY_EXPORTED, HashSet(set))
                    .apply()
            }
        } catch (e: Exception) {
            Log.e(SmsBridge.TAG, "MediaExporter.markExported failed: ${e.message}")
        }
    }

    private fun exportedSet(context: Context): LinkedHashSet<String> {
        exported?.let { return it }
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_EXPORTED, emptySet()) ?: emptySet()
        val set = LinkedHashSet<String>(stored)
        exported = set
        return set
    }
}
