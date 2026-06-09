package chat.fluffy.fluffychat.sms

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import java.io.File

/**
 * Minimal ContentProvider that serves an outbound MMS PDU file to the system
 * MMS service. Mirrors AOSP Messaging's MmsFileProvider.
 *
 * Why not androidx FileProvider: the system MMS service (a separate process,
 * `com.android.mms.service`) reads the PDU back through this URI. androidx
 * FileProvider requires an explicit per-package grant that's awkward to target
 * across ROMs; a plain ContentProvider whose openFile() just returns the file
 * lets the trusted system caller read it (the provider is exported so the OS
 * MMS service can reach it, and only ever serves files inside our own cache).
 *
 * Usage: write the PDU to [getFile], then hand [buildUri] to
 * SmsManager.sendMultimediaMessage as the contentUri.
 */
class MmsPduProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val ctx = context ?: return null
        // The provider must be exported so the system MMS service (a separate
        // process) can read the PDU — but that also makes it reachable by any
        // app. Lock it to trusted system callers only: the phone/MMS service
        // (UID 1001 = PHONE_UID) and our own process. A third-party app (UID
        // >= 10000) could otherwise read outbound MMS PDUs (message bodies,
        // recipients) by guessing the URI.
        val callingUid = Binder.getCallingUid()
        val allowed = callingUid == Process.PHONE_UID ||
            callingUid == Process.SYSTEM_UID ||
            callingUid == Process.myUid()
        if (!allowed) {
            Log.w(SmsBridge.TAG, "MmsPduProvider.openFile: refus UID=$callingUid")
            return null
        }
        val file = fileForUri(ctx, uri) ?: run {
            Log.e(SmsBridge.TAG, "MmsPduProvider.openFile: bad uri $uri")
            return null
        }
        // Read-only — the service only retrieves the PDU.
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "application/vnd.wap.mms-message"

    // The provider is file-only; the data methods are stubbed.
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        private const val AUTHORITY = "eu.devlabz.vox.mmspdu"
        private const val DIR = "rawmms"

        /** content:// URI for a named PDU file. */
        fun buildUri(name: String): Uri =
            Uri.parse("content://$AUTHORITY/$name")

        /**
         * The on-disk file backing [uri] (or, given a raw name, the file to
         * write). Canonical-path guarded to stay inside cacheDir/rawmms.
         */
        fun fileForUri(context: Context, uri: Uri): File? {
            val name = uri.lastPathSegment ?: return null
            return fileForName(context, name)
        }

        fun fileForName(context: Context, name: String): File? {
            val dir = File(context.cacheDir, DIR).apply { mkdirs() }
            val file = File(dir, name)
            return try {
                val canonical = file.canonicalPath
                // Séparateur inclus : sinon un sibling `rawmms_evil` passerait le
                // préfixe `rawmms`. Le fichier doit être STRICTEMENT sous le dossier.
                if (!canonical.startsWith(dir.canonicalPath + File.separator)) {
                    Log.e(SmsBridge.TAG, "MmsPduProvider: path traversal blocked: $name")
                    null
                } else {
                    file
                }
            } catch (e: Exception) {
                null
            }
        }
    }
}
