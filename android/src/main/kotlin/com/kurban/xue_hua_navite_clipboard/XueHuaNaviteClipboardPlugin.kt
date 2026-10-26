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
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

/** XueHuaNaviteClipboardPlugin */
class XueHuaNaviteClipboardPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var applicationContext: Context? = null
    private var clipboardManager: ClipboardManager? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val changeCounter = AtomicInteger(0)
    private var lastObservedTimestamp: Long = -1L

    private var eventSink: EventChannel.EventSink? = null
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
        applicationContext = flutterPluginBinding.applicationContext
        clipboardManager =
            applicationContext?.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "xue_hua_navite_clipboard")
        methodChannel.setMethodCallHandler(this)

        eventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "xue_hua_navite_clipboard/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopNativeClipboardListener()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        applicationContext = null
        clipboardManager = null
    }

    // ==================== EventChannel.StreamHandler (Lazy on-demand listener) ====================

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startNativeClipboardListener()
    }

    override fun onCancel(arguments: Any?) {
        stopNativeClipboardListener()
        eventSink = null
    }

    private fun startNativeClipboardListener() {
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
                val count = changeCounter.incrementAndGet()
                mainHandler.post {
                    eventSink?.success(
                        mapOf(
                            "buffer" to "general",
                            "changeCount" to count,
                            "timestampMs" to clipTimestamp
                        )
                    )
                }
            }
        }
        clipChangedListener = listener
        manager.addPrimaryClipChangedListener(listener)
    }

    private fun stopNativeClipboardListener() {
        val listener = clipChangedListener ?: return
        clipboardManager?.removePrimaryClipChangedListener(listener)
        clipChangedListener = null
    }

    // ==================== MethodChannel Handler ====================

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "writeItems" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(handleWriteItems(args))
                }
                "readItems" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(handleReadItems(args))
                }
                "getMetadata" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(handleGetMetadata(args))
                }
                "getChangeCount" -> {
                    result.success(handleGetChangeCount())
                }
                "clear" -> {
                    result.success(handleClear())
                }
                "setPollingInterval" -> {
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error(
                "BACKGROUND_RESTRICTED",
                "Clipboard access denied by Android system (apps in background cannot read clipboard on Android 10+): ${e.message}",
                null
            )
        } catch (e: Exception) {
            result.error("CLIPBOARD_ERROR", e.message ?: "Unknown error on Android clipboard", null)
        }
    }

    private fun handleWriteItems(args: Map<*, *>?): Boolean {
        val ctx = applicationContext ?: return false
        val manager = clipboardManager ?: return false
        val rawItems = args?.get("items") as? List<*> ?: return false
        if (rawItems.isEmpty()) return false

        val options = args["options"] as? Map<*, *>
        val isSensitive = options?.get("isSensitive") as? Boolean ?: false
        val label = options?.get("label") as? String ?: "xue_hua_clipboard"

        val mimeTypes = mutableSetOf<String>()
        val clipItems = mutableListOf<ClipData.Item>()

        for ((index, rawItem) in rawItems.withIndex()) {
            val itemMap = rawItem as? Map<*, *> ?: continue
            val plainText = itemMap["plainText"] as? String
            val html = itemMap["html"] as? String
            val rtfBytes = itemMap["rtfBytes"] as? ByteArray
            val markdown = itemMap["markdown"] as? String
            val uriStr = itemMap["uri"] as? String
            val imageBytes = itemMap["imageBytes"] as? ByteArray
            val imageMimeType = (itemMap["imageMimeType"] as? String) ?: "image/png"
            val files = (itemMap["files"] as? List<*>)?.mapNotNull { it as? String }
            val colorValue = (itemMap["colorValue"] as? Number)?.toLong()
            val customFormats = itemMap["customFormats"] as? Map<*, *>

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
                            // Stable plugin mime so reads can distinguish shared files from custom blobs.
                            XueHuaClipboardContentProvider.createUriForFile(ctx, dest, MIME_SHARED_FILE)
                        }
                    }
                    clipItems.add(ClipData.Item(filePath, null, null, fileUri))
                }
            }

            if (customFormats != null && customFormats.isNotEmpty()) {
                val shareDir = XueHuaClipboardContentProvider.getShareDir(ctx)
                for ((k, v) in customFormats) {
                    val fmtName = k as? String ?: continue
                    val fmtBytes = coerceByteArray(v) ?: continue
                    val safeName = fmtName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
                    val customFile = File(shareDir, "clip_custom_${safeName}_$index.bin")
                    FileOutputStream(customFile).use { it.write(fmtBytes) }
                    val customUri = XueHuaClipboardContentProvider.createUriForFile(ctx, customFile, fmtName)
                    mimeTypes.add(fmtName)
                    clipItems.add(ClipData.Item(effectiveText, null, null, customUri))
                }
            }

            if (clipItems.isEmpty()) {
                clipItems.add(ClipData.Item(""))
                mimeTypes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
            }
        }

        if (clipItems.isEmpty()) return false

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
            val firstItem = rawItems.firstOrNull() as? Map<*, *>
            val markdown = firstItem?.get("markdown") as? String
            if (markdown != null) {
                extras.putString(MIME_MARKDOWN, markdown)
            }
            val colorValue = (firstItem?.get("colorValue") as? Number)?.toLong()
            if (colorValue != null) {
                extras.putLong(MIME_COLOR, colorValue)
            }
            val fileCopyMode = firstItem?.get("fileCopyMode") as? String
            if (fileCopyMode != null) {
                extras.putString(MIME_FILE_COPY_MODE, fileCopyMode)
            }
            description.extras = extras
        }

        val clipData = ClipData(description, clipItems.first())
        for (i in 1 until clipItems.size) {
            clipData.addItem(clipItems[i])
        }
        manager.setPrimaryClip(clipData)
        changeCounter.incrementAndGet()
        return true
    }

    private fun handleReadItems(args: Map<*, *>?): List<Map<String, Any?>> {
        val ctx = applicationContext ?: return emptyList()
        val manager = clipboardManager ?: return emptyList()
        val clip = manager.primaryClip ?: return emptyList()
        if (clip.itemCount == 0) return emptyList()

        val description = clip.description
        val extras = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) description?.extras else null
        val markdownExtra = extras?.getString(MIME_MARKDOWN)
        val colorExtra = if (extras != null && extras.containsKey(MIME_COLOR)) extras.getLong(MIME_COLOR) else null
        val fileCopyModeExtra = extras?.getString(MIME_FILE_COPY_MODE) ?: "copy"

        val results = mutableListOf<Map<String, Any?>>()
        val collectedFiles = mutableListOf<String>()
        val collectedCustom = mutableMapOf<String, ByteArray>()

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
                            // Prefer caller-facing path stored in item text for same-app roundtrips.
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
                                collectedCustom[mime] = input.readBytes()
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

            val itemMap = mutableMapOf<String, Any?>(
                "plainText" to text,
                "html" to html,
                "rtfBytes" to rtfBytes,
                "markdown" to if (i == 0) markdownExtra else null,
                "uri" to parsedUriStr,
                "imageBytes" to imageBytes,
                "imageMimeType" to imageMime,
                "fileCopyMode" to fileCopyModeExtra,
                "colorValue" to if (i == 0) colorExtra else null
            )
            results.add(itemMap)
        }

        if (results.isNotEmpty()) {
            val first = results[0].toMutableMap()
            if (collectedFiles.isNotEmpty()) {
                first["files"] = collectedFiles
            }
            if (collectedCustom.isNotEmpty()) {
                first["customFormats"] = collectedCustom
            }
            results[0] = first
        }

        return results
    }

    private fun handleGetMetadata(args: Map<*, *>?): Map<String, Any?> {
        val manager = clipboardManager
        val desc = manager?.primaryClipDescription
        if (desc == null) {
            return mapOf(
                "changeCount" to changeCounter.get(),
                "timestampMs" to null,
                "itemCount" to 0,
                "hasPlainText" to false,
                "hasHtml" to false,
                "hasRtf" to false,
                "hasMarkdown" to false,
                "hasUri" to false,
                "hasImage" to false,
                "hasFiles" to false,
                "hasColor" to false,
                "rawPlatformFormats" to emptyList<String>(),
                "detectedPatterns" to emptyList<String>()
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

        val detectedPatterns = mutableListOf<String>()
        val detectPatterns = args?.get("detectPatterns") as? Boolean ?: false
        if (detectPatterns && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (desc.classificationStatus == ClipDescription.CLASSIFICATION_COMPLETE) {
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_URL) > 0.5f) {
                    detectedPatterns.add("probableWebUrl")
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_EMAIL) > 0.5f) {
                    detectedPatterns.add("emailAddress")
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_PHONE) > 0.5f) {
                    detectedPatterns.add("phoneNumber")
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_ADDRESS) > 0.5f) {
                    detectedPatterns.add("postalAddress")
                }
                if (desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_FLIGHT_NUMBER) > 0.5f) {
                    detectedPatterns.add("flightNumber")
                }
            }
        }

        val itemCount = try {
            manager.primaryClip?.itemCount ?: 1
        } catch (_: Exception) {
            1
        }

        return mapOf(
            "changeCount" to handleGetChangeCount(),
            "timestampMs" to timestampMs,
            "itemCount" to itemCount,
            "hasPlainText" to hasPlainText,
            "hasHtml" to hasHtml,
            "hasRtf" to hasRtf,
            "hasMarkdown" to hasMarkdown,
            "hasUri" to hasUri,
            "hasImage" to hasImage,
            "hasFiles" to hasFiles,
            "hasColor" to hasColor,
            "rawPlatformFormats" to mimeList,
            "detectedPatterns" to detectedPatterns
        )
    }

    private fun handleGetChangeCount(): Int {
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

    private fun handleClear(): Boolean {
        val manager = clipboardManager ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.clearPrimaryClip()
        } else {
            manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        changeCounter.incrementAndGet()
        return true
    }

    private fun coerceByteArray(value: Any?): ByteArray? {
        return when (value) {
            null -> null
            is ByteArray -> value
            is List<*> -> {
                val out = ByteArray(value.size)
                for (i in value.indices) {
                    val n = value[i] as? Number ?: return null
                    out[i] = n.toByte()
                }
                out
            }
            else -> null
        }
    }
}

