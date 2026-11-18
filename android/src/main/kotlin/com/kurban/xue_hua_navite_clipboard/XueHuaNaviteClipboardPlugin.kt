package com.kurban.xue_hua_navite_clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

/** XueHuaNaviteClipboardPlugin */
class XueHuaNaviteClipboardPlugin :
    FlutterPlugin,
    ClipboardHostApi {

    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var applicationContext: Context? = null
    private var clipboardManager: ClipboardManager? = null

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }
    private val changeCounter = AtomicInteger(0)
    private var lastObservedTimestamp: Long = -1L

    private var clipChangedListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    companion object {
        private const val EXTRA_IS_SENSITIVE_COMPAT = "android.content.extra.IS_SENSITIVE"
        private const val MIME_MARKDOWN = "text/markdown"
        private const val MIME_RTF = "text/rtf"
        private const val MIME_COLOR = "application/x-color"
        private const val MIME_FILE_COPY_MODE = "application/x-file-copy-mode"
        private const val MIME_SHARED_FILE = "application/x-xuehua-file"
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = flutterPluginBinding
        applicationContext = flutterPluginBinding.applicationContext
        clipboardManager =
            applicationContext?.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        ClipboardHostApiRegistrar().register(this, flutterPluginBinding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopClipboardListening()
        ClipboardHostApiRegistrar().unregister(this, binding)
        pluginBinding = null
        applicationContext = null
        clipboardManager = null
    }

    // ==================== ClipboardHostApi ====================

    override fun writeItems(
        items: List<WireClipboardItem>,
        options: WireClipboardWriteOptions,
    ): Boolean = runClipboardOp {
        val ctx = applicationContext ?: return@runClipboardOp false
        val manager = clipboardManager ?: return@runClipboardOp false
        if (items.isEmpty()) return@runClipboardOp false

        val isSensitive = options.isSensitive
        val label = options.label ?: "xue_hua_clipboard"

        val mimeTypes = mutableSetOf<String>()
        val clipItems = mutableListOf<ClipData.Item>()

        for ((index, item) in items.withIndex()) {
            val plainText = item.plainText
            val html = item.html
            val rtfBytes = item.rtfBytes
            val markdown = item.markdown
            val uriStr = item.uri
            val imageBytes = item.imageBytes
            val imageMimeType = item.imageMimeType ?: "image/png"
            val files = item.files
            val colorValue = item.colorValue
            val customFormats = item.customFormats

            val effectiveText = plainText
                ?: markdown
                ?: uriStr
                ?: (if (colorValue != null) String.format("#%08X", colorValue and 0xFFFFFFFFL) else null)

            if (effectiveText != null) {
                mimeTypes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
            }
            if (html != null) {
                mimeTypes.add(ClipDescription.MIMETYPE_TEXT_HTML)
            }
            if (markdown != null) {
                mimeTypes.add(MIME_MARKDOWN)
            }
            if (colorValue != null) {
                mimeTypes.add(MIME_COLOR)
            }

            var primaryUri: Uri? = null
            if (imageBytes != null && imageBytes.isNotEmpty()) {
                val shareDir = XueHuaClipboardContentProvider.getShareDir(ctx)
                val ext = when {
                    imageMimeType.contains("jpeg") || imageMimeType.contains("jpg") -> "jpg"
                    imageMimeType.contains("gif") -> "gif"
                    imageMimeType.contains("webp") -> "webp"
                    else -> "png"
                }
                val imgFile = File(shareDir, "clip_img_${System.currentTimeMillis()}_$index.$ext")
                FileOutputStream(imgFile).use { it.write(imageBytes) }
                primaryUri = XueHuaClipboardContentProvider.createUriForFile(ctx, imgFile, imageMimeType)
                mimeTypes.add(imageMimeType)
            } else if (rtfBytes != null && rtfBytes.isNotEmpty()) {
                val shareDir = XueHuaClipboardContentProvider.getShareDir(ctx)
                val rtfFile = File(shareDir, "clip_rtf_${System.currentTimeMillis()}_$index.rtf")
                FileOutputStream(rtfFile).use { it.write(rtfBytes) }
                primaryUri = XueHuaClipboardContentProvider.createUriForFile(ctx, rtfFile, MIME_RTF)
                mimeTypes.add(MIME_RTF)
            } else if (!uriStr.isNullOrBlank()) {
                primaryUri = Uri.parse(uriStr)
                mimeTypes.add(ClipDescription.MIMETYPE_TEXT_URILIST)
            }

            if (effectiveText != null || html != null || primaryUri != null) {
                clipItems.add(ClipData.Item(effectiveText, html, null, primaryUri))
            }

            if (!files.isNullOrEmpty()) {
                mimeTypes.add(ClipDescription.MIMETYPE_TEXT_URILIST)
                mimeTypes.add(MIME_FILE_COPY_MODE)
                mimeTypes.add(MIME_SHARED_FILE)
                val shareDir = XueHuaClipboardContentProvider.getShareDir(ctx)
                for (filePath in files) {
                    // Android 7+ forbids exposing file:// via ClipData (FileUriExposedException).
                    // Always share through our ContentProvider; keep the original path in text
                    // so same-app readFiles can round-trip the caller-facing path.
                    val fileUri: Uri = when {
                        filePath.startsWith("content://") -> Uri.parse(filePath)
                        else -> {
                            val src = if (filePath.startsWith("file://")) {
                                File(Uri.parse(filePath).path ?: filePath)
                            } else {
                                File(filePath)
                            }
                            val safeName = src.name.replace(Regex("[^a-zA-Z0-9._-]"), "_")
                            val dest = File(shareDir, "clip_file_${System.currentTimeMillis()}_${index}_$safeName")
                            if (src.exists() && src.isFile) {
                                src.copyTo(dest, overwrite = true)
                            } else {
                                dest.writeBytes(ByteArray(0))
                            }
                            XueHuaClipboardContentProvider.createUriForFile(ctx, dest, MIME_SHARED_FILE)
                        }
                    }
                    clipItems.add(ClipData.Item(filePath, null, null, fileUri))
                }
            }

            if (!customFormats.isNullOrEmpty()) {
                val shareDir = XueHuaClipboardContentProvider.getShareDir(ctx)
                for (entry in customFormats) {
                    val mime = entry.format
                    val data = entry.data
                    mimeTypes.add(mime)
                    val customFile = File(shareDir, "clip_custom_${System.currentTimeMillis()}_$index.bin")
                    FileOutputStream(customFile).use { it.write(data) }
                    val cUri = XueHuaClipboardContentProvider.createUriForFile(ctx, customFile, mime)
                    clipItems.add(ClipData.Item(null, null, null, cUri))
                }
            }
        }

        if (clipItems.isEmpty()) return@runClipboardOp false

        val description = ClipDescription(label, mimeTypes.toTypedArray())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val extras = PersistableBundle()
            if (isSensitive) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                } else {
                    extras.putBoolean(EXTRA_IS_SENSITIVE_COMPAT, true)
                }
            }
            val firstItem = items.firstOrNull()
            val markdown = firstItem?.markdown
            if (markdown != null) {
                extras.putString(MIME_MARKDOWN, markdown)
            }
            val colorValue = firstItem?.colorValue
            if (colorValue != null) {
                extras.putLong(MIME_COLOR, colorValue)
            }
            if (firstItem != null) {
                extras.putString(
                    MIME_FILE_COPY_MODE,
                    if (firstItem.fileCopyMode == WireFileCopyMode.CUT) "cut" else "copy",
                )
            }
            description.extras = extras
        }

        val clipData = ClipData(description, clipItems.first())
        for (i in 1 until clipItems.size) {
            clipData.addItem(clipItems[i])
        }
        manager.setPrimaryClip(clipData)
        changeCounter.incrementAndGet()
        true
    }

    override fun readItems(
        options: WireClipboardReadOptions,
    ): List<WireClipboardItem> = runClipboardOp {
        val ctx = applicationContext ?: return@runClipboardOp emptyList()
        val manager = clipboardManager ?: return@runClipboardOp emptyList()
        val clip = manager.primaryClip ?: return@runClipboardOp emptyList()
        if (clip.itemCount == 0) return@runClipboardOp emptyList()

        val description = clip.description
        val extras = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) description?.extras else null
        val markdownExtra = extras?.getString(MIME_MARKDOWN)
        val colorExtra = if (extras != null && extras.containsKey(MIME_COLOR)) extras.getLong(MIME_COLOR) else null
        val fileCopyModeExtra = if (extras?.getString(MIME_FILE_COPY_MODE) == "cut") {
            WireFileCopyMode.CUT
        } else {
            WireFileCopyMode.COPY
        }

        val collectedFiles = mutableListOf<String>()
        val collectedCustom = mutableListOf<WireCustomFormatEntry>()
        val parsedItems = mutableListOf<WireClipboardItem>()

        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val text = item.text?.toString()
            val html = item.htmlText
            val uri = item.uri

            var rtfBytes: ByteArray? = null
            var imageBytes: ByteArray? = null
            var imageMime = "image/png"
            var parsedUriStr: String? = null

            if (uri != null) {
                val scheme = uri.scheme?.lowercase()
                if (scheme == "file") {
                    uri.path?.let { collectedFiles.add(it) }
                } else if (scheme == "content") {
                    val mime = ctx.contentResolver.getType(uri) ?: uri.getQueryParameter("mime") ?: ""
                    val textLooksLikePath = !text.isNullOrBlank() && (
                        text.startsWith("/") ||
                            text.startsWith("file://") ||
                            text.startsWith("content://")
                        )
                    val isSharedFile = mime == MIME_SHARED_FILE || (
                        textLooksLikePath &&
                            extras?.containsKey(MIME_FILE_COPY_MODE) == true &&
                            !mime.startsWith("image/") &&
                            mime != MIME_RTF &&
                            mime != "application/rtf"
                        )
                    when {
                        isSharedFile -> {
                            collectedFiles.add(text!!)
                        }
                        mime.startsWith("image/") -> {
                            ctx.contentResolver.openInputStream(uri)?.use { input ->
                                val rawBytes = input.readBytes()
                                val bmp = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
                                if (bmp != null) {
                                    val out = ByteArrayOutputStream()
                                    bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                                    imageBytes = out.toByteArray()
                                    imageMime = "image/png"
                                } else {
                                    imageBytes = rawBytes
                                    imageMime = mime
                                }
                            }
                        }
                        mime == MIME_RTF || mime == "application/rtf" -> {
                            ctx.contentResolver.openInputStream(uri)?.use { input ->
                                rtfBytes = input.readBytes()
                            }
                        }
                        mime.isNotEmpty() -> {
                            ctx.contentResolver.openInputStream(uri)?.use { input ->
                                collectedCustom.add(WireCustomFormatEntry(format = mime, data = input.readBytes()))
                            }
                        }
                    }
                } else if (scheme == "http" || scheme == "https" || scheme == "mailto") {
                    parsedUriStr = uri.toString()
                }
            }

            if (parsedUriStr == null && !text.isNullOrBlank()) {
                val trimmed = text.trim()
                if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
                    parsedUriStr = trimmed
                }
            }

            parsedItems.add(
                WireClipboardItem(
                    plainText = text,
                    html = html,
                    rtfBytes = rtfBytes,
                    markdown = if (i == 0) markdownExtra else null,
                    uri = parsedUriStr,
                    imageBytes = imageBytes,
                    imageMimeType = imageMime,
                    files = null,
                    fileCopyMode = fileCopyModeExtra,
                    colorValue = if (i == 0) colorExtra else null,
                    customFormats = null,
                )
            )
        }

        if (parsedItems.isNotEmpty() && (collectedFiles.isNotEmpty() || collectedCustom.isNotEmpty())) {
            parsedItems[0] = parsedItems[0].copy(
                files = collectedFiles.ifEmpty { null },
                customFormats = collectedCustom.ifEmpty { null },
            )
        }

        parsedItems
    }

    override suspend fun getMetadata(
        target: WireClipboardBufferTarget,
        detectPatterns: Boolean,
    ): WireClipboardMetadata = runClipboardOp {
        val manager = clipboardManager
        val desc = manager?.primaryClipDescription
        if (desc == null) {
            return@runClipboardOp WireClipboardMetadata(
                changeCount = changeCounter.get().toLong(),
                timestampMs = null,
                itemCount = 0L,
                hasPlainText = false,
                hasHtml = false,
                hasRtf = false,
                hasMarkdown = false,
                hasUri = false,
                hasImage = false,
                hasFiles = false,
                hasColor = false,
                rawPlatformFormats = emptyList(),
                detectedPatterns = emptyList(),
            )
        }

        val mimeList = mutableListOf<String>()
        for (i in 0 until desc.mimeTypeCount) {
            mimeList.add(desc.getMimeType(i))
        }

        val extras = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) desc.extras else null
        val hasPlainText = desc.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)
        val hasHtml = desc.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)
        val hasRtf = desc.hasMimeType(MIME_RTF) || desc.hasMimeType("application/rtf")
        val hasMarkdown = desc.hasMimeType(MIME_MARKDOWN) || (extras?.containsKey(MIME_MARKDOWN) == true)
        val hasUri = desc.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)
        val hasImage = desc.hasMimeType("image/*")
        val hasFiles = extras?.containsKey(MIME_FILE_COPY_MODE) == true
        val hasColor = desc.hasMimeType(MIME_COLOR) || (extras?.containsKey(MIME_COLOR) == true)

        val timestampMs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            desc.timestamp.takeIf { it > 0 }
        } else {
            null
        }

        val detectedPatterns = mutableListOf<WireClipboardDetectedPattern>()
        if (detectPatterns && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (desc.classificationStatus == ClipDescription.CLASSIFICATION_COMPLETE) {
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_URL) > 0.5f) {
                    detectedPatterns.add(WireClipboardDetectedPattern.PROBABLE_WEB_URL)
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_EMAIL) > 0.5f) {
                    detectedPatterns.add(WireClipboardDetectedPattern.EMAIL_ADDRESS)
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_PHONE) > 0.5f) {
                    detectedPatterns.add(WireClipboardDetectedPattern.PHONE_NUMBER)
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_ADDRESS) > 0.5f) {
                    detectedPatterns.add(WireClipboardDetectedPattern.POSTAL_ADDRESS)
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_FLIGHT_NUMBER) > 0.5f) {
                    detectedPatterns.add(WireClipboardDetectedPattern.FLIGHT_NUMBER)
                }
            }
        }

        val itemCount = try {
            (manager.primaryClip?.itemCount ?: 1).toLong()
        } catch (_: Exception) {
            1L
        }

        WireClipboardMetadata(
            changeCount = readCurrentChangeCount().toLong(),
            timestampMs = timestampMs,
            itemCount = itemCount,
            hasPlainText = hasPlainText,
            hasHtml = hasHtml,
            hasRtf = hasRtf,
            hasMarkdown = hasMarkdown,
            hasUri = hasUri,
            hasImage = hasImage,
            hasFiles = hasFiles,
            hasColor = hasColor,
            rawPlatformFormats = mimeList,
            detectedPatterns = detectedPatterns,
        )
    }

    override fun getChangeCount(target: WireClipboardBufferTarget): Long = runClipboardOp {
        readCurrentChangeCount().toLong()
    }

    override fun clear(target: WireClipboardBufferTarget): Boolean = runClipboardOp {
        val manager = clipboardManager ?: return@runClipboardOp false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.clearPrimaryClip()
        } else {
            manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        changeCounter.incrementAndGet()
        true
    }

    override fun setPollingInterval(intervalMs: Long) {
        // Android uses system OnPrimaryClipChangedListener callbacks instead of polling.
    }

    override fun startClipboardListening() {
        if (clipChangedListener != null) return
        val manager = clipboardManager ?: return
        val listener = ClipboardManager.OnPrimaryClipChangedListener {
            val now = System.currentTimeMillis()
            val clipTimestamp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.primaryClipDescription?.timestamp ?: now
            } else {
                now
            }
            if (clipTimestamp != lastObservedTimestamp || now - lastObservedTimestamp > 50) {
                lastObservedTimestamp = clipTimestamp
                val count = changeCounter.incrementAndGet().toLong()
                mainHandler.post {
                    val binding = pluginBinding ?: return@post
                    try {
                        ClipboardFlutterApiRegistrar().getInstance(binding)?.onClipboardChanged(
                            WireClipboardChangeEvent(
                                buffer = WireClipboardBuffer.GENERAL,
                                changeCount = count,
                                timestampMs = clipTimestamp,
                            )
                        )
                    } catch (_: Exception) {
                        // Ignore stale FlutterApi dispatch when engine/isolate is detaching.
                    }
                }
            }
        }
        clipChangedListener = listener
        manager.addPrimaryClipChangedListener(listener)
    }

    override fun stopClipboardListening() {
        val listener = clipChangedListener ?: return
        clipboardManager?.removePrimaryClipChangedListener(listener)
        clipChangedListener = null
    }

    private fun readCurrentChangeCount(): Int {
        val manager = clipboardManager ?: return changeCounter.get()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ts = manager.primaryClipDescription?.timestamp ?: 0L
            if (ts > 0 && ts != lastObservedTimestamp) {
                lastObservedTimestamp = ts
                return changeCounter.incrementAndGet()
            }
        }
        return changeCounter.get()
    }

    private inline fun <T> runClipboardOp(block: () -> T): T {
        try {
            return block()
        } catch (e: FlutterError) {
            throw e
        } catch (e: SecurityException) {
            throw FlutterError(
                "BACKGROUND_RESTRICTED",
                "Clipboard access denied by Android system (apps in background cannot read clipboard on Android 10+): ${e.message}",
                null,
            )
        } catch (e: Exception) {
            throw FlutterError(
                "CLIPBOARD_ERROR",
                e.message ?: "Unknown error on Android clipboard",
                null,
            )
        }
    }
}
