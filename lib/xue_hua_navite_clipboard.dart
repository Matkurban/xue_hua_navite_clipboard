import 'dart:convert';
import 'dart:typed_data';

import 'src/models/clipboard_change_event.dart';
import 'src/models/clipboard_format.dart';
import 'src/models/clipboard_item.dart';
import 'src/models/clipboard_metadata.dart';
import 'src/models/clipboard_read_options.dart';
import 'src/models/clipboard_write_options.dart';
import 'src/models/file_copy_mode.dart';
import 'xue_hua_navite_clipboard_platform_interface.dart';

export 'src/exceptions/clipboard_exception.dart';
export 'src/models/clipboard_change_event.dart';
export 'src/models/clipboard_format.dart';
export 'src/models/clipboard_item.dart';
export 'src/models/clipboard_metadata.dart';
export 'src/models/clipboard_read_options.dart';
export 'src/models/clipboard_write_options.dart';
export 'src/models/file_copy_mode.dart';
export 'xue_hua_navite_clipboard_platform_interface.dart';

/// 跨平台全功能原生剪切板核心类
class XueHuaNaviteClipboard {
  /// Constructs a [XueHuaNaviteClipboard] instance.
  XueHuaNaviteClipboard();

  /// 全局单例访问入口
  static final XueHuaNaviteClipboard instance = XueHuaNaviteClipboard();

  static final RegExp _htmlTagStripRegex = RegExp(
    r'<[^>]*>',
    multiLine: true,
    caseSensitive: false,
  );

  /// 将 HTML 简单剥离标签生成纯文本回退
  static String stripHtmlTags(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(_htmlTagStripRegex, '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .trim();
  }

  // ==================== 1. 便捷单项写入 API ====================

  /// 写入纯文本（支持附加敏感标记、本地限制、过期时间等）
  Future<bool> writeText(
    String text, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(ClipboardDataItem(plainText: text), options: options);
  }

  /// 写入敏感密码/密钥（自动开启 isSensitive: true, isTransient: true, localOnly: true，默认 60s 自动过期清空）
  Future<bool> writeSensitiveText(
    String secret, {
    Duration expiration = const Duration(seconds: 60),
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) {
    return writeItem(
      ClipboardDataItem(plainText: secret),
      options: ClipboardWriteOptions(
        buffer: buffer,
        customBufferName: customBufferName,
        isSensitive: true,
        isTransient: true,
        localOnly: true,
        expiration: expiration,
      ),
    );
  }

  /// 写入 HTML 富文本（自动附带 plainTextFallback 纯文本降级，若不传则自动剥离 HTML 标签生成）
  Future<bool> writeHtml(
    String html, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    final fallback = plainTextFallback ?? stripHtmlTags(html);
    return writeItem(
      ClipboardDataItem(html: html, plainText: fallback),
      options: options,
    );
  }

  /// 写入 RTF 富文本字节数据（可附带 plainTextFallback）
  Future<bool> writeRtf(
    Uint8List rtfBytes, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(rtfBytes: rtfBytes, plainText: plainTextFallback),
      options: options,
    );
  }

  /// 写入 RTF 富文本字符串（UTF-8 编码）
  Future<bool> writeRtfString(
    String rtf, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeRtf(
      Uint8List.fromList(utf8.encode(rtf)),
      plainTextFallback: plainTextFallback,
      options: options,
    );
  }

  /// 写入 Markdown 文本
  Future<bool> writeMarkdown(
    String markdown, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(
        markdown: markdown,
        plainText: plainTextFallback ?? markdown,
      ),
      options: options,
    );
  }

  /// 写入 URI / URL 链接
  Future<bool> writeUri(
    Uri uri, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(
        uri: uri,
        plainText: plainTextFallback ?? uri.toString(),
      ),
      options: options,
    );
  }

  /// 写入图片二进制数据（自动适配各端原生位图与 PNG 格式）
  Future<bool> writeImage(
    Uint8List imageBytes, {
    String mimeType = 'image/png',
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(imageBytes: imageBytes, imageMimeType: mimeType),
      options: options,
    );
  }

  /// 写入文件或文件夹路径列表（支持复制 Copy 或剪切 Cut 语义）
  Future<bool> writeFiles(
    List<String> filePaths, {
    FileCopyMode mode = FileCopyMode.copy,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(files: filePaths, fileCopyMode: mode),
      options: options,
    );
  }

  /// 写入颜色（ARGB 32-bit 整数，例如 0xFF2196F3）
  Future<bool> writeColor(
    int colorValue, {
    bool includeHexTextFallback = true,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    final hex =
        '#${(colorValue & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
    return writeItem(
      ClipboardDataItem(
        colorValue: colorValue,
        plainText: includeHexTextFallback ? hex : null,
      ),
      options: options,
    );
  }

  /// 写入自定义格式二进制数据
  Future<bool> writeCustomData(
    String format,
    Uint8List data, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItem(
      ClipboardDataItem(
        plainText: plainTextFallback,
        customFormats: <String, Uint8List>{format: data},
      ),
      options: options,
    );
  }

  // ==================== 2. 复合条目与多条目写入 API ====================

  /// 写入单个复合条目（同时携带多种格式表示）
  Future<bool> writeItem(
    ClipboardDataItem item, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return writeItems(<ClipboardDataItem>[item], options: options);
  }

  /// 写入多个独立剪切板条目
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    return XueHuaNaviteClipboardPlatform.instance.writeItems(
      items,
      options: options,
    );
  }

  // ==================== 3. 读取 API ====================

  /// 读取纯文本
  Future<String?> readText({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.plainText.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.plainText;
  }

  /// 读取 HTML 富文本
  Future<String?> readHtml({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.html.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.html;
  }

  /// 读取 RTF 富文本字节
  Future<Uint8List?> readRtf({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.rtf.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.rtfBytes;
  }

  /// 读取 Markdown 文本
  Future<String?> readMarkdown({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.markdown.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.markdown ?? items.first.plainText;
  }

  /// 读取 URI / URL
  Future<Uri?> readUri({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.uri.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.uri;
  }

  /// 读取图片字节数据（原生层默认无损转换为 PNG Uint8List 返回，可直接传给 Image.memory）
  Future<Uint8List?> readImage({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.png.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.imageBytes;
  }

  /// 读取文件列表路径（桌面端返回绝对路径列表；移动端解析或缓存可读文件后返回路径）
  Future<List<String>> readFiles({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.fileList.mimeType,
    );
    if (items.isEmpty) {
      return const <String>[];
    }
    final allFiles = <String>[];
    for (final item in items) {
      if (item.files != null) {
        allFiles.addAll(item.files!);
      }
    }
    return allFiles;
  }

  /// 读取当前文件列表附带的复制/剪切状态（Windows Preferred DropEffect / Linux gnome-copied-files）
  Future<FileCopyMode?> readFileCopyMode({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.fileList.mimeType,
    );
    if (items.isEmpty ||
        items.first.files == null ||
        items.first.files!.isEmpty) {
      return null;
    }
    return items.first.fileCopyMode;
  }

  /// 读取颜色值（ARGB 32-bit int）
  Future<int?> readColor({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: options,
      targetFormat: StandardClipboardFormat.color.mimeType,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.colorValue;
  }

  /// 读取指定自定义格式的原始二进制数据
  Future<Uint8List?> readCustomData(
    String format, {
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final mergedOptions = ClipboardReadOptions(
      buffer: options.buffer,
      customBufferName: options.customBufferName,
      preferredImageFormat: options.preferredImageFormat,
      requestedCustomFormats: <String>{
        ...options.requestedCustomFormats,
        format,
      }.toList(),
    );
    final items = await XueHuaNaviteClipboardPlatform.instance.readItems(
      options: mergedOptions,
      targetFormat: format,
    );
    if (items.isEmpty) {
      return null;
    }
    return items.first.customFormats[format];
  }

  /// 一次性读取完整复合条目（包含所有可用标准格式与请求的自定义格式）
  Future<ClipboardDataItem?> readItem({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) async {
    final items = await readItems(options: options);
    if (items.isEmpty) {
      return null;
    }
    return items.first;
  }

  /// 一次性读取剪切板中的所有条目列表（Multi-item read）
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  }) {
    return XueHuaNaviteClipboardPlatform.instance.readItems(options: options);
  }

  // ==================== 4. 元数据探测、清理与实时监听 API ====================

  /// 获取剪切板元数据（可用格式、changeCount、预探测模式，不拉取实际二进制载荷）
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  }) {
    return XueHuaNaviteClipboardPlatform.instance.getMetadata(
      buffer: buffer,
      customBufferName: customBufferName,
      detectPatterns: detectPatterns,
    );
  }

  /// 快速检查是否包含指定标准格式或原生格式名
  Future<bool> hasFormat(
    String formatOrMimeType, {
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    final metadata = await getMetadata(
      buffer: buffer,
      customBufferName: customBufferName,
    );
    final standard = StandardClipboardFormat.fromMimeType(formatOrMimeType);
    if (standard != null) {
      switch (standard) {
        case StandardClipboardFormat.plainText:
          return metadata.hasPlainText;
        case StandardClipboardFormat.html:
          return metadata.hasHtml;
        case StandardClipboardFormat.rtf:
          return metadata.hasRtf;
        case StandardClipboardFormat.markdown:
          return metadata.hasMarkdown;
        case StandardClipboardFormat.uri:
          return metadata.hasUri;
        case StandardClipboardFormat.png:
        case StandardClipboardFormat.jpeg:
        case StandardClipboardFormat.gif:
        case StandardClipboardFormat.webp:
        case StandardClipboardFormat.tiff:
        case StandardClipboardFormat.bmp:
        case StandardClipboardFormat.svg:
          return metadata.hasImage;
        case StandardClipboardFormat.fileList:
          return metadata.hasFiles;
        case StandardClipboardFormat.color:
          return metadata.hasColor;
      }
    }
    final targetLower = formatOrMimeType.toLowerCase();
    return metadata.rawPlatformFormats.any(
      (f) => f.toLowerCase() == targetLower,
    );
  }

  /// 获取当前剪切板变更计数（changeCount / SequenceNumber）
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) {
    return XueHuaNaviteClipboardPlatform.instance.getChangeCount(
      buffer: buffer,
      customBufferName: customBufferName,
    );
  }

  /// 清空剪切板内容
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) {
    return XueHuaNaviteClipboardPlatform.instance.clear(
      buffer: buffer,
      customBufferName: customBufferName,
    );
  }

  /// 剪切板变更事件流：
  /// 仅当添加监听（`.listen(...)`）时才会触发原生端注册系统监听/定时器；
  /// 当取消最后一个订阅（`subscription.cancel()`）时原生端立即注销系统监听，无任何后台空转开销。
  Stream<ClipboardChangeEvent> get onClipboardChanged {
    return XueHuaNaviteClipboardPlatform.instance.onClipboardChanged;
  }

  /// 配置轮询间隔（仅对无系统级广播通知的平台如 macOS 在存在活跃监听者时生效，默认 500ms）
  Future<void> setPollingInterval(Duration interval) {
    return XueHuaNaviteClipboardPlatform.instance.setPollingInterval(interval);
  }
}
