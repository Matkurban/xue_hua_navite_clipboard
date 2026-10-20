package com.kurban.xue_hua_navite_clipboard

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * Lightweight ContentProvider for sharing clipboard images, RTF, and custom binary files
 * via content:// URIs without requiring external AndroidX dependencies.
 */
class XueHuaClipboardContentProvider : ContentProvider() {

    companion object {
        private const val CACHE_SUBDIR = "xue_hua_clipboard_share"

        fun authority(context: Context): String =
            "${context.packageName}.xue_hua_clipboard.provider"

        fun getShareDir(context: Context): File {
            val dir = File(context.cacheDir, CACHE_SUBDIR)
            if (!dir.exists()) {
                dir.mkdirs()
            }
            return dir
        }

        fun createUriForFile(context: Context, file: File, mimeType: String? = null): Uri {
            val builder = Uri.Builder()
                .scheme("content")
                .authority(authority(context))
                .appendPath(file.name)
            if (!mimeType.isNullOrBlank()) {
                builder.appendQueryParameter("mime", mimeType)
            }
            return builder.build()
        }
    }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val ctx = context ?: return null
        val fileName = uri.lastPathSegment ?: return null
        val file = File(getShareDir(ctx), File(fileName).name)
        if (!file.exists()) return null

        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols, 1)
        val row = cursor.newRow()
        for (col in cols) {
            when (col) {
                OpenableColumns.DISPLAY_NAME -> row.add(file.name)
                OpenableColumns.SIZE -> row.add(file.length())
                else -> row.add(null)
            }
        }
        return cursor
    }

    override fun getType(uri: Uri): String? {
        val explicitMime = uri.getQueryParameter("mime")
        if (!explicitMime.isNullOrBlank()) {
            return explicitMime
        }
        val fileName = uri.lastPathSegment ?: return "application/octet-stream"
        val ext = fileName.substringAfterLast('.', "").lowercase()
        if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
        }
        return "application/octet-stream"
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val ctx = context ?: throw FileNotFoundException("Context is null")
        val fileName = uri.lastPathSegment ?: throw FileNotFoundException("Missing file name in $uri")
        val file = File(getShareDir(ctx), File(fileName).name)
        if (!file.exists()) {
            throw FileNotFoundException("Clipboard shared file not found: ${file.absolutePath}")
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
