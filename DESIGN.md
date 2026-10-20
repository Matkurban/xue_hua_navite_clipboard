# `xue_hua_navite_clipboard` 跨平台全功能原生剪切板插件设计文档

## 1. 背景与设计目标

Flutter 官方内置的 `Clipboard`（位于 `package:flutter/services.dart`）目前仅支持最基础的纯文本（`text/plain`）读写与简单是否有字符串的探测，无法满足富文本、图片、文件列表、自定义二进制格式、隐私保护（敏感密码防历史记录/防云同步）、多剪切板通道（如 Linux Primary Selection、macOS Find Pasteboard）以及剪切板实时监听等桌面端与移动端核心场景。

`xue_hua_navite_clipboard` 旨在打造一个**覆盖全平台（Android、iOS、macOS、Windows、Linux、Web）所有原生剪切板能力**的高性能、类型安全的 Flutter 插件。

### 核心目标
1. **全格式支持**：纯文本、HTML、RTF（富文本）、Markdown、URI/URL、图片（PNG / JPEG / GIF / WebP / TIFF / BMP / SVG）、文件与目录列表（支持复制/剪切语义）、颜色（Color）以及任意自定义 MIME / UTI / 原生格式二进制数据。
2. **复合条目与多条目（Multi-Representation & Multi-Item）**：支持单次写入同一内容的多种表示形式（例如同时写入 HTML + 纯文本降级 + 图片快照），以及一次性读写多个独立剪切板条目。
3. **无感探测与元数据（Pre-flight Inspection）**：在不读取完整大数据载荷（以及在 iOS 14+ 尽量避免提前触发系统粘贴横幅）的前提下，探测可用格式、系统变更计数（`changeCount` / Sequence Number）、时间戳及文本实体分类置信度。
4. **隐私与安全控制（Privacy & Security）**：原生支持密码与敏感内容标记（隐藏系统预览弹窗、排除在 Windows `Win+V` 剪切板历史和云剪切板之外、禁止 Apple 通用剪切板跨设备同步、遵循 macOS 密码管理器 `ConcealedType` 规范）以及到期自动清除（Expiration）。
5. **实时变更监听（Clipboard Monitoring）**：基于系统原生事件（Windows `WM_CLIPBOARDUPDATE`、Linux `owner-change`、Android `OnPrimaryClipChangedListener`、iOS `changedNotification`、macOS `changeCount` 轻量轮询）提供响应式 `Stream` 监听。
6. **平台特色扩展**：支持 Linux X11/Wayland 的 `PRIMARY`（鼠标选中即复制/中键粘贴）与 `CLIPBOARD` 双缓冲区切换，支持 macOS/iOS 命名剪切板（如 macOS 全局搜索剪切板 `Find Pasteboard`）。

---

## 2. 总体架构设计

插件采用 Flutter 官方推荐的 **Federated Plugin（联合插件接口）** 架构，通过 `XueHuaNaviteClipboardPlatform` 抽象层隔离平台实现：

```text
+-------------------------------------------------------------------+
|                     Dart Public API Layer                         |
|  XueHuaNaviteClipboard / ClipboardDataItem / ClipboardWriteOptions|
+-------------------------------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------+
|             XueHuaNaviteClipboardPlatform (Interface)             |
+-------------------------------------------------------------------+
            |                                           |
            v                                           v
+---------------------------------------+   +-----------------------+
| MethodChannelXueHuaNaviteClipboard    |   | XueHuaNaviteClipboard |
| - MethodChannel:                      |   | Web (package:web)     |
|   "xue_hua_navite_clipboard/methods"  |   | - Navigator.clipboard |
| - EventChannel:                       |   | - ClipboardItem API   |
|   "xue_hua_navite_clipboard/events"   |   | - DOM copy/paste evts |
+---------------------------------------+   +-----------------------+
    |         |         |         |         |
    v         v         v         v         v
+-------+ +-------+ +-------+ +-------+ +-------+
|Android| |  iOS  | | macOS | |Windows| | Linux |
|Kotlin | | Swift | | Swift | | C++   | | C/GTK |
+-------+ +-------+ +-------+ +-------+ +-------+
```

### 目录结构规划

```text
xue_hua_navite_clipboard/
├── lib/
│   ├── xue_hua_navite_clipboard.dart                    # 对外统一导出与高层便捷 API
│   ├── xue_hua_navite_clipboard_platform_interface.dart # 平台抽象接口定义
│   ├── xue_hua_navite_clipboard_method_channel.dart     # MethodChannel + EventChannel 实现
│   ├── xue_hua_navite_clipboard_web.dart                # Web 端 Clipboard API 实现
│   └── src/
│       ├── models/
│       │   ├── clipboard_format.dart                    # 标准格式枚举与自定义格式封装
│       │   ├── clipboard_item.dart                      # 复合剪切板条目模型（支持多表示形式）
│       │   ├── clipboard_write_options.dart             # 隐私、敏感标记、过期时间、命名通道配置
│       │   ├── clipboard_read_options.dart              # 读取过滤选项、剪切板通道选择
│       │   ├── clipboard_metadata.dart                  # 变更序号、格式列表、系统特征元数据
│       │   ├── clipboard_change_event.dart              # 剪切板变更事件数据
│       │   └── file_copy_mode.dart                      # 文件复制/剪切模式（Copy / Cut）
│       └── exceptions/
│           └── clipboard_exception.dart                 # 统一异常定义（权限拒绝、后台限制、格式不支持等）
├── android/                                             # Kotlin 实现 + FileProvider 支持
├── ios/                                                 # Swift UIPasteboard 实现
├── macos/                                               # Swift NSPasteboard 实现
├── windows/                                             # Win32 / Ole32 / GDI+ C++ 实现
└── linux/                                               # GTK3 (GtkClipboard / GdkPixbuf) C++ 实现
```

---

## 3. 全端能力矩阵与原生 API 映射

| 功能特性                       | Android                                           | iOS                                           | macOS                                                   | Windows                                                                                                           | Linux (GTK)                                                 | Web                                                          |
|:-------------------------------|:--------------------------------------------------|:----------------------------------------------|:--------------------------------------------------------|:------------------------------------------------------------------------------------------------------------------|:------------------------------------------------------------|:-------------------------------------------------------------|
| **底层核心 API**               | `ClipboardManager`, `ClipData`, `ContentResolver` | `UIPasteboard`, `UTType`, `NSItemProvider`    | `NSPasteboard`, `NSPasteboardItem`                      | Win32 Clipboard API, OLE `IDataObject`, `Gdiplus`                                                                 | `GtkClipboard`, `GtkSelectionData`, `GdkPixbuf`             | Async Clipboard API (`navigator.clipboard`), `ClipboardItem` |
| **纯文本 (`text/plain`)**      | `ClipData.newPlainText`                           | `UTType.plainText`                            | `.string` (`public.utf8-plain-text`)                    | `CF_UNICODETEXT`                                                                                                  | `UTF8_STRING` / `text/plain`                                | `text/plain`                                                 |
| **HTML (`text/html`)**         | `ClipData.newHtmlText`                            | `UTType.html`                                 | `.html` (`public.html`)                                 | `HTML Format` (带 CF_HTML 头部封装)                                                                               | `text/html`                                                 | `text/html`                                                  |
| **RTF (`text/rtf`)**           | 自定义 MIME `text/rtf` URI/Bytes                  | `UTType.rtf`                                  | `.rtf` (`public.rtf`)                                   | `Rich Text Format`                                                                                                | `text/rtf`, `application/rtf`                               | Custom format `web text/rtf`                                 |
| **URL / URI**                  | `ClipData.newRawUri` / `text/uri-list`            | `UTType.url`                                  | `.URL` (`public.url`)                                   | `UniformResourceLocatorW` + `CF_UNICODETEXT`                                                                      | `text/uri-list`                                             | `text/uri-list` / `text/plain`                               |
| **图片读写 (`PNG`/`JPEG`/等)** | `FileProvider` `content://` URI + `Bitmap`        | `UIPasteboard.image` (`PNG`/`JPEG` data)      | `.png`, `.tiff` (`NSImage`)                             | `PNG` 注册格式 + `CF_DIBV5` / `CF_DIB`                                                                            | `image/png`, `image/jpeg` (`GdkPixbuf`)                     | `image/png` (`ClipboardItem` Blob)                           |
| **文件列表 (`Files`)**         | 多条 `content://` / `file://` `ClipData.Item`     | `UTType.fileURL`                              | `.fileURL` / `NSFilenamesPboardType`                    | `CF_HDROP` (`DROPFILES`) + `Preferred DropEffect` (Copy/Cut)                                                      | `text/uri-list` + `x-special/gnome-copied-files` (copy/cut) | 受浏览器沙箱限制（支持读取拖入/粘贴的文件 Blob）             |
| **颜色 (`Color`)**             | ARGB Hex 降级或自定义 MIME                        | `UIPasteboard.color` (`UIColor`)              | `.color` (`NSColor`)                                    | 自定义格式 + Hex 降级                                                                                             | 自定义格式 + Hex 降级                                       | Hex 降级                                                     |
| **自定义二进制格式**           | `ContentProvider` / 自定义 MIME                   | 自定义 `UTType` / 标识符                      | `NSPasteboard.PasteboardType(rawValue:)`                | `RegisterClipboardFormatW`                                                                                        | 自定义 `GdkAtom` target                                     | `web <custom/mime>` (Chrome 104+)                            |
| **多条目读写 (`Multi-Item`)**  | `ClipData` 包含多个 `ClipData.Item`               | `UIPasteboard.items` (`[[String: Any]]`)      | `NSPasteboard.pasteboardItems`                          | 单事务多格式 + 多文件列表                                                                                         | 单事务多格式 + 多文件列表                                   | `List<ClipboardItem>`                                        |
| **变更序号 (`changeCount`)**   | `ClipDescription.timestamp` + 内部计数            | `UIPasteboard.changeCount`                    | `NSPasteboard.changeCount`                              | `GetClipboardSequenceNumber()`                                                                                    | `owner-change` 递增计数                                     | 事件递增计数                                                 |
| **实时监听 (`Stream`)**        | `OnPrimaryClipChangedListener`                    | `UIPasteboard.changedNotification`            | `changeCount` 定时轻量检测（默认 500ms）                | `AddClipboardFormatListener` (`WM_CLIPBOARDUPDATE`)                                                               | `g_signal_connect("owner-change")`                          | `copy`/`cut`/`paste` 事件监听                                |
| **敏感/密码保护**              | `EXTRA_IS_SENSITIVE` (API 33+)                    | `localOnly: true`                             | `org.nspasteboard.ConcealedType` / `TransientType`      | `ExcludeClipboardContentFromMonitorProcessing` + `CanIncludeInClipboardHistory=0` + `CanUploadToCloudClipboard=0` | `x-kde-passwordManagerHint` (`secret`)                      | N/A                                                          |
| **过期时间 (`expiration`)**    | 定时器到期清理                                    | `UIPasteboard.Option.expirationDate` (原生级) | 定时器比对 `changeCount` 安全清理                       | 定时器比对 `SequenceNumber` 安全清理                                                                              | 定时器清理                                                  | 定时器清理                                                   |
| **特殊剪切板通道**             | `general`                                         | `general` + 自定义命名 `UIPasteboard(name:)`  | `general`, `find`, `drag`, `font`, `ruler` + 自定义名称 | `general`                                                                                                         | `clipboard` (`Ctrl+C`) + `primary` (鼠标选中)               | `general`                                                    |

---

## 4. Dart 数据模型与公开 API 设计

### 4.1 剪切板通道与格式定义 (`clipboard_format.dart`)

```dart
/// 剪切板目标通道/缓冲区类型
enum ClipboardBuffer {
  /// 系统默认通用剪切板（所有平台支持）
  general,

  /// Linux X11/Wayland 鼠标选中缓冲区（中键粘贴，仅 Linux 原生生效，其他平台回退至 general）
  primarySelection,

  /// macOS 全局查找剪切板（Cmd+E 跨应用共享搜索词，仅 macOS 原生生效）
  macOsFind,

  /// macOS 拖拽剪切板
  macOsDrag,

  /// macOS 字体样式剪切板
  macOsFont,

  /// macOS 标尺样式剪切板
  macOsRuler,

  /// iOS / macOS 自定义命名剪切板（配合 customBufferName 使用）
  named,
}

/// 标准剪切板数据格式
enum StandardClipboardFormat {
  plainText('text/plain'),
  html('text/html'),
  rtf('text/rtf'),
  markdown('text/markdown'),
  uri('text/uri-list'),
  png('image/png'),
  jpeg('image/jpeg'),
  gif('image/gif'),
  webp('image/webp'),
  tiff('image/tiff'),
  bmp('image/bmp'),
  svg('image/svg+xml'),
  fileList('application/x-file-list'),
  color('application/x-color');

  final String mimeType;
  const StandardClipboardFormat(this.mimeType);
}

/// 文件写入模式（用于桌面端资源管理器复制或剪切文件）
enum FileCopyMode {
  /// 复制文件（Ctrl+C / Cmd+C）
  copy,

  /// 剪切/移动文件（Ctrl+X，Windows Preferred DropEffect = DROPEFFECT_MOVE，Linux gnome-copied-files = cut）
  cut,
}
```

### 4.2 复合剪切板条目模型 (`clipboard_item.dart`)

支持在一个条目内同时挂载多种格式（例如复制富文本或组件时，同时提供 `html`、`plainText` 和 `png` 预览图），粘贴目标应用会自动挑选其支持的最丰富格式：

```dart
import 'dart:typed_data';

/// 单个剪切板条目（可同时包含同一份数据的多种格式表示）
class ClipboardDataItem {
  /// 纯文本内容
  final String? plainText;

  /// HTML 富文本内容（写入时若未提供 plainText，插件会自动提取纯文本或使用回退文本）
  final String? html;

  /// RTF 富文本字节数据或字符串
  final Uint8List? rtfBytes;

  /// Markdown 文本内容
  final String? markdown;

  /// URL / URI 链接
  final Uri? uri;

  /// 图片二进制数据（写入时默认自动编码/转换为平台标准格式如 PNG + 原生位图）
  final Uint8List? imageBytes;

  /// 图片格式提示（默认 'image/png'）
  final String? imageMimeType;

  /// 本地文件/文件夹绝对路径或 URI 列表
  final List<String>? files;

  /// 文件操作模式（复制或剪切，默认 FileCopyMode.copy）
  final FileCopyMode fileCopyMode;

  /// ARGB 32位颜色值（对应 Flutter Color.value）
  final int? colorValue;

  /// 自定义格式字典：Key 为 MIME 类型、UTI 或平台注册格式名，Value 为原始字节数据
  final Map<String, Uint8List> customFormats;

  const ClipboardDataItem({
    this.plainText,
    this.html,
    this.rtfBytes,
    this.markdown,
    this.uri,
    this.imageBytes,
    this.imageMimeType = 'image/png',
    this.files,
    this.fileCopyMode = FileCopyMode.copy,
    this.colorValue,
    this.customFormats = const {},
  });

  /// 判断条目是否为空
  bool get isEmpty =>
      plainText == null &&
      html == null &&
      rtfBytes == null &&
      markdown == null &&
      uri == null &&
      imageBytes == null &&
      (files == null || files!.isEmpty) &&
      colorValue == null &&
      customFormats.isEmpty;
}
```

### 4.3 读写配置与隐私安全参数 (`clipboard_write_options.dart` & `clipboard_read_options.dart`)

```dart
/// 剪切板写入选项（涵盖隐私保护、跨设备同步控制与过期清理）
class ClipboardWriteOptions {
  /// 目标剪切板通道，默认 ClipboardBuffer.general
  final ClipboardBuffer buffer;

  /// 当 buffer == ClipboardBuffer.named 时的自定义名称（iOS/macOS 支持）
  final String? customBufferName;

  /// 是否标记为敏感/机密数据（如密码、私钥、验证码）：
  /// - Android 13+: 设置 ClipDescription.EXTRA_IS_SENSITIVE 隐藏系统弹窗明文预览
  /// - Windows: 设置 ExcludeClipboardContentFromMonitorProcessing 及禁止进入 Win+V 历史记录
  /// - macOS/iOS: 写入 org.nspasteboard.ConcealedType 供密码管理器/剪切板工具忽略
  /// - Linux: 写入 x-kde-passwordManagerHint = "secret"
  final bool isSensitive;

  /// 是否为临时生成的内容（不希望被第三方剪切板历史软件记录）：
  /// - Windows: CanIncludeInClipboardHistory = 0
  /// - macOS: org.nspasteboard.TransientType & org.nspasteboard.AutoGeneratedType
  final bool isTransient;

  /// 是否禁止跨设备云同步（仅保留在本机）：
  /// - iOS: UIPasteboard.Option.localOnly = true（禁止 Apple Universal Clipboard 同步）
  /// - Windows: CanUploadToCloudClipboard = 0（禁止微软云剪切板同步）
  final bool localOnly;

  /// 自动过期时长（到期后若剪切板内容未被其他数据覆盖，则自动清除）：
  /// - iOS: 原生映射至 UIPasteboard.Option.expirationDate
  /// - 其他平台: 内部记录写入时的 changeCount/sequenceNumber，到期后仅当序号未变时安全清空
  final Duration? expiration;

  /// Android ClipDescription 标签描述
  final String? label;

  const ClipboardWriteOptions({
    this.buffer = ClipboardBuffer.general,
    this.customBufferName,
    this.isSensitive = false,
    this.isTransient = false,
    this.localOnly = false,
    this.expiration,
    this.label,
  });
}

/// 剪切板读取选项
class ClipboardReadOptions {
  /// 目标剪切板通道
  final ClipboardBuffer buffer;

  /// 自定义命名剪切板名称
  final String? customBufferName;

  /// 期望读取的图片目标格式（默认转换输出为无损 PNG，也可指定原始格式）
  final StandardClipboardFormat preferredImageFormat;

  /// 指定需要一并提取的自定义格式名称列表（避免无意义遍历未知系统私有块）
  final List<String> requestedCustomFormats;

  const ClipboardReadOptions({
    this.buffer = ClipboardBuffer.general,
    this.customBufferName,
    this.preferredImageFormat = StandardClipboardFormat.png,
    this.requestedCustomFormats = const [],
  });
}
```

### 4.4 元数据与探测模型 (`clipboard_metadata.dart`)

```dart
/// iOS / Android 文本内容模式预探测结果（无需完整读取文本即可知晓是否包含链接、电话、邮箱等）
enum ClipboardDetectedPattern {
  probableWebUrl,
  probableWebSearch,
  number,
  emailAddress,
  phoneNumber,
  postalAddress,
  flightNumber,
  shipmentTrackingNumber,
  moneyAmount,
}

/// 剪切板实时状态与元数据（不读取重型二进制内容）
class ClipboardMetadata {
  /// 系统剪切板变更序号（macOS/iOS changeCount, Windows SequenceNumber）
  final int changeCount;

  /// 内容写入时间戳（毫秒，若平台支持如 Android 8.0+）
  final int? timestampMs;

  /// 当前剪切板中包含的条目数量（Multi-item count）
  final int itemCount;

  /// 快速布尔判断
  final bool hasPlainText;
  final bool hasHtml;
  final bool hasRtf;
  final bool hasMarkdown;
  final bool hasUri;
  final bool hasImage;
  final bool hasFiles;
  final bool hasColor;

  /// 平台底层报告的所有原生格式标识符列表（MIME Types / UTIs / Win32 Format Names / GdkAtoms）
  final List<String> rawPlatformFormats;

  /// 预探测到的文本语义模式（iOS 14+ UIPasteboard.detectPatterns / Android 12+ TextClassifier）
  final Set<ClipboardDetectedPattern> detectedPatterns;

  const ClipboardMetadata({
    required this.changeCount,
    this.timestampMs,
    required this.itemCount,
    required this.hasPlainText,
    required this.hasHtml,
    required this.hasRtf,
    required this.hasMarkdown,
    required this.hasUri,
    required this.hasImage,
    required this.hasFiles,
    required this.hasColor,
    required this.rawPlatformFormats,
    this.detectedPatterns = const {},
  });
}
```

### 4.5 核心主类 `XueHuaNaviteClipboard` API

```dart
class XueHuaNaviteClipboard {
  XueHuaNaviteClipboard._();
  static final XueHuaNaviteClipboard instance = XueHuaNaviteClipboard._();

  // ==================== 1. 便捷单项写入 API ====================

  /// 写入纯文本（支持附加敏感标记、本地限制、过期时间等）
  Future<void> writeText(
    String text, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入敏感密码/密钥（自动开启 isSensitive: true, isTransient: true, localOnly: true，默认 60s 自动过期清空）
  Future<void> writeSensitiveText(
    String secret, {
    Duration expiration = const Duration(seconds: 60),
  });

  /// 写入 HTML 富文本（自动附带 plainTextFallback 纯文本降级，若不传则自动剥离 HTML 标签生成）
  Future<void> writeHtml(
    String html, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入 RTF 富文本（可附带 plainTextFallback）
  Future<void> writeRtf(
    Uint8List rtfBytes, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入 Markdown 文本
  Future<void> writeMarkdown(
    String markdown, {
    bool alsoWriteHtml = false,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入 URI / URL 链接
  Future<void> writeUri(
    Uri uri, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入图片二进制数据（自动适配各端原生位图与 PNG 格式）
  Future<void> writeImage(
    Uint8List imageBytes, {
    String mimeType = 'image/png',
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入文件或文件夹路径列表（支持复制 Copy 或剪切 Cut 语义）
  Future<void> writeFiles(
    List<String> filePaths, {
    FileCopyMode mode = FileCopyMode.copy,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入颜色（ARGB 32-bit 整数或 Flutter Color）
  Future<void> writeColor(
    int colorValue, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入自定义格式二进制数据
  Future<void> writeCustomData(
    String format,
    Uint8List data, {
    String? plainTextFallback,
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  // ==================== 2. 复合条目与多条目写入 API ====================

  /// 写入单个复合条目（同时携带多种格式表示）
  Future<void> writeItem(
    ClipboardDataItem item, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 写入多个独立剪切板条目（iOS/macOS/Android 原生多条目支持，其他平台合并或取首项）
  Future<void> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  // ==================== 3. 读取 API ====================

  /// 读取纯文本
  Future<String?> readText({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取 HTML 富文本
  Future<String?> readHtml({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取 RTF 富文本字节
  Future<Uint8List?> readRtf({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取 Markdown 文本
  Future<String?> readMarkdown({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取 URI / URL
  Future<Uri?> readUri({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取图片字节数据（默认统一转换为 PNG Uint8List 返回，方便直接 Image.memory 渲染）
  Future<Uint8List?> readImage({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取文件列表路径（桌面端直接返回绝对路径列表；移动端自动将 content:// URI 解析或缓存至可读文件）
  Future<List<String>> readFiles({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取当前文件列表附带的复制/剪切状态（Windows Preferred DropEffect / Linux gnome-copied-files）
  Future<FileCopyMode?> readFileCopyMode({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取颜色值（ARGB 32-bit int）
  Future<int?> readColor({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 读取指定自定义格式的原始二进制数据
  Future<Uint8List?> readCustomData(
    String format, {
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 一次性读取完整复合条目（包含所有可用标准格式与请求的自定义格式）
  Future<ClipboardDataItem?> readItem({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  /// 一次性读取剪切板中的所有条目列表（Multi-item read）
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
  });

  // ==================== 4. 元数据探测、清理与实时监听 API ====================

  /// 获取剪切板元数据（可用格式、changeCount、预探测模式，不拉取实际二进制载荷）
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  });

  /// 快速检查是否包含指定标准格式或原生格式名
  Future<bool> hasFormat(
    String formatOrMimeType, {
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  });

  /// 获取当前剪切板变更计数（changeCount / SequenceNumber）
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  });

  /// 清空剪切板内容
  Future<void> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  });

  /// 剪切板变更事件流（当订阅不为空时自动开启原生监听，取消订阅时自动释放原生监听器）
  Stream<ClipboardChangeEvent> get onClipboardChanged;

  /// 配置 macOS 剪切板轮询间隔（仅对 macOS 生效，默认 500ms）
  Future<void> setPollingInterval(Duration interval);
}
```

---

## 5. 通道通信协议（MethodChannel & EventChannel）

### 5.1 通道名称
- **MethodChannel**: `xue_hua_navite_clipboard/methods`
- **EventChannel**: `xue_hua_navite_clipboard/events`

### 5.2 MethodChannel 方法表

| 方法名 (`method`)    | 参数 (`arguments`: `Map<String, dynamic>`)                                  | 返回值                 | 说明                                                                                   |
|:---------------------|:----------------------------------------------------------------------------|:-----------------------|:---------------------------------------------------------------------------------------|
| `writeItems`         | `{ "items": List<Map>, "options": Map }`                                    | `bool`                 | 统一写入入口（单项写入与多项写入在底层统一封装为 `items` 数组）                        |
| `readItems`          | `{ "options": Map, "targetFormat": String? }`                               | `List<Map>`            | 统一读取入口（支持指定单一 `targetFormat` 按需极速读取，或传 `null` 读取全部可用格式） |
| `getMetadata`        | `{ "buffer": String, "customBufferName": String?, "detectPatterns": bool }` | `Map<String, dynamic>` | 返回 `changeCount`、`has*` 布尔位、`rawPlatformFormats`、`detectedPatterns`            |
| `getChangeCount`     | `{ "buffer": String, "customBufferName": String? }`                         | `int`                  | 极速获取系统剪切板序号                                                                 |
| `clear`              | `{ "buffer": String, "customBufferName": String? }`                         | `bool`                 | 清空指定剪切板缓冲区                                                                   |
| `setPollingInterval` | `{ "intervalMs": int }`                                                     | `void`                 | 动态调整轮询间隔（用于 macOS 等无系统级广播平台）                                      |

### 5.3 EventChannel 事件载荷格式 (`ClipboardChangeEvent`)
当原生层检测到剪切板变更时，向 `EventChannel` 推送如下 `Map`：
```json
{
  "buffer": "general",
  "changeCount": 42,
  "timestampMs": 1792464797000
}
```

---

## 6. 各平台原生层实现细节

### 6.1 Android (`XueHuaNaviteClipboardPlugin.kt`)
1. **服务获取**：通过 `context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager` 获取剪切板服务。
2. **富文本与多格式写入**：
   - 使用 `ClipData` 构造。若同时包含 `html` 和 `plainText`，使用 `ClipData.Item(plainText, htmlText, intent, uri)`。
   - **图片与自定义文件共享**：内置轻量级 `FileProvider`（配置在插件 `AndroidManifest.xml` 及 `res/xml/xue_hua_clipboard_file_paths.xml` 中，指向 `context.cacheDir/xue_hua_clipboard/`）。写入 `imageBytes` 时，将图片写入缓存目录并通过 `FileProvider.getUriForFile` 生成 `content://` URI 放入 `ClipData`，同时赋予系统临时读取权限 `FLAG_GRANT_READ_URI_PERMISSION`。
3. **敏感标记（Android 13 / API 33+）**：
   - 当 `options.isSensitive == true` 时，在 `ClipDescription.extras` 中设置 `PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }`（低版本使用字符串常量 `"android.content.extra.IS_SENSITIVE"` 兼容）。
4. **读取图片与文件**：
   - 从 `ClipData.Item.uri` 通过 `context.contentResolver.openInputStream(uri)` 读取图片流或文件流；若外部应用提供的是文件路径或 `content://` 媒体 URI，自动解析出字节数组或拷贝至本地可读临时路径返回。
5. **变更监听**：
   - 注册 `ClipboardManager.OnPrimaryClipChangedListener`，当 `EventChannel` `onListen` 时绑定，`onCancel` 时解绑。

### 6.2 iOS (`XueHuaNaviteClipboardPlugin.swift`)
1. **实例选择**：根据 `buffer` 选择 `UIPasteboard.general` 或 `UIPasteboard(name: UIPasteboard.Name(customName), create: true)`。
2. **多条目与多格式写入**：
   - 构造 `[[String: Any]]` 字典数组，映射标准 UTI（使用 `UniformTypeIdentifiers` `UTType`）：
     - `UTType.utf8PlainText.identifier` (`public.utf8-plain-text`)
     - `UTType.html.identifier` (`public.html`)
     - `UTType.rtf.identifier` (`public.rtf`)
     - `UTType.url.identifier` (`public.url`)
     - `UTType.png.identifier` (`public.png`) / `UTType.jpeg.identifier`
     - `UTType.fileURL.identifier` (`public.file-url`)
   - 隐私与过期配置：使用 `pasteboard.setItems(items, options: [.localOnly: options.localOnly, .expirationDate: expirationDate])`；若 `isSensitive == true`，额外附加 `"org.nspasteboard.ConcealedType": Data()`。
3. **低打扰元数据探测（避免无故弹出粘贴提示框）**：
   - 在 `getMetadata` 中优先使用 `pasteboard.hasStrings`、`pasteboard.hasURLs`、`pasteboard.hasImages`、`pasteboard.hasColors`、`pasteboard.changeCount` 以及 `pasteboard.types`（这些属性在 iOS 14+ 不会触发粘贴权限弹窗）。
   - 当 `detectPatterns == true` 时，调用 iOS 14+ `pasteboard.detectPatterns(for: [.probableWebURL, .probableWebSearch, .number, ...])` 异步返回结果。
4. **变更监听**：
   - 监听 `UIPasteboard.changedNotification` 与 `UIApplication.didBecomeActiveNotification`（从后台切回前台时比对 `changeCount` 是否变化）。

### 6.3 macOS (`XueHuaNaviteClipboardPlugin.swift`)
1. **多剪切板通道映射**：
   - `.general` -> `NSPasteboard.general`
   - `.macOsFind` -> `NSPasteboard(name: .find)`
   - `.macOsDrag` -> `NSPasteboard(name: .drag)`
   - `.macOsFont` -> `NSPasteboard(name: .font)`
   - `.macOsRuler` -> `NSPasteboard(name: .ruler)`
   - `.named` -> `NSPasteboard(name: NSPasteboard.Name(customName))`
2. **读写实现**：
   - 写入前调用 `pasteboard.clearContents()`，随后构建 `[NSPasteboardItem]` 并通过 `pasteboard.writeObjects(items)` 写入。
   - **图片兼容处理**：读取图片时优先直接读取 `.png` (`NSPasteboard.PasteboardType.png`)；若源应用（如 macOS 预览/Safari）仅提供了 `.tiff`，则使用 `NSBitmapImageRep(data: tiffData)?.representation(using: .png, properties: [:])` 自动无损转为 PNG 返回给 Dart。
   - **文件列表**：写入文件时将路径转为 `NSURL(fileURLWithPath:)` 写入 `public.file-url`；读取时通过 `pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` 获取所有本地文件路径。
   - **隐私规范**：遵循 NSPasteboard.org 标准，支持写入 `org.nspasteboard.ConcealedType`（密码/机密）、`org.nspasteboard.TransientType`（临时内容）、`org.nspasteboard.AutoGeneratedType`。
3. **变更监听**：
   - macOS 系统没有全局 `NSPasteboard` 变更通知，因此在 `EventChannel` 处于活跃状态时，启动 `DispatchSourceTimer`（默认 500ms 间隔，可通过 `setPollingInterval` 配置）轻量比对 `pasteboard.changeCount`（仅一次整型寄存器读取，CPU 开销趋近于 0）。

### 6.4 Windows (`xue_hua_navite_clipboard_plugin.cpp`)
1. **剪贴板事务与编码**：
   - 使用 RAII 包装 `OpenClipboard(hwnd)` 与 `CloseClipboard()`（附带指数退避重试机制，防止与其他正在占用剪切板句柄的进程冲突）。
2. **格式映射与协议封装**：
   - **纯文本**：`CF_UNICODETEXT`（UTF-8 <-> UTF-16LE `std::wstring` 互转）。
   - **HTML**：注册 `"HTML Format"`，写入时自动按微软规范生成并拼接 `Version:0.9\r\nStartHTML:...\r\nEndHTML:...\r\nStartFragment:...\r\nEndFragment:...` 头部；读取时自动解析 `StartFragment` 与 `EndFragment` 偏移提取纯净 HTML（若无 Fragment 标记则回退至 `StartHTML`..`EndHTML`）。
   - **RTF**：注册 `"Rich Text Format"`，直接读写 ANSI/UTF-8 RTF 字节块。
   - **图片**：
     - 优先注册并读写 `"PNG"` 及 `"image/png"` 格式。
     - 同时兼容 Windows 原生 `CF_DIBV5` / `CF_DIB`：写入 PNG 时利用 GDI+ (`Gdiplus::Bitmap`) 同步解码生成 `CF_DIB` 写入剪切板，确保画图（MSPaint）、旧版 Office 等不支持 `"PNG"` 剪切板格式的应用也能正常粘贴；读取时若剪切板仅有 `CF_DIB` / `CF_BITMAP`，通过 GDI+ 编码为内存 PNG 流返回给 Flutter。
   - **文件列表与复制/剪切模式**：
     - 使用 `CF_HDROP`（构造 `DROPFILES` 结构体，`fWide = TRUE`，后接双 `\0` 结尾的 UTF-16 路径序列）。
     - 注册 `"Preferred DropEffect"`：写入 4 字节 `DWORD`，`DROPEFFECT_COPY (1)` 表示复制，`DROPEFFECT_MOVE (2)` 表示剪切（在资源管理器中粘贴后会直接移动文件！）。
   - **隐私与云同步控制（Windows 10 1809+ / Windows 11）**：
     - 注册 `"ExcludeClipboardContentFromMonitorProcessing"`、`"CanIncludeInClipboardHistory"`、`"CanUploadToCloudClipboard"` 格式并写入 `DWORD(0)`，彻底阻止密码被 Windows 剪切板历史（`Win+V`）或云同步捕获。
3. **零轮询实时监听**：
   - 通过 `registrar->RegisterTopLevelWindowProcDelegate` 挂载窗口过程，调用 Win32 `AddClipboardFormatListener(hwnd)` 监听 `WM_CLIPBOARDUPDATE` 消息，由内核直接回调并推送 `GetClipboardSequenceNumber()`。

### 6.5 Linux (`xue_hua_navite_clipboard_plugin.cc`)
1. **双缓冲区支持**：
   - `ClipboardBuffer.general` -> `gtk_clipboard_get(GDK_SELECTION_CLIPBOARD)`
   - `ClipboardBuffer.primarySelection` -> `gtk_clipboard_get(GDK_SELECTION_PRIMARY)`
2. **多 Target 读写**：
   - 使用 `gtk_clipboard_set_with_data` 注册复合 `GtkTargetEntry` 表，在一次剪切板写入中同时提供：
     - `UTF8_STRING` / `STRING` / `text/plain;charset=utf-8`
     - `text/html`
     - `text/rtf` / `application/rtf`
     - `image/png`（同时支持 `gdk_pixbuf` 转换）
     - `text/uri-list` 与 `x-special/gnome-copied-files`（格式为 `"copy\nfile:///path/1\nfile:///path/2"` 或 `"cut\n..."`）以及 `x-special/mate-copied-files`
     - `x-kde-passwordManagerHint`（当 `isSensitive == true` 时返回 `"secret"`）
     - 任意用户自定义 Target Atom
   - 调用 `gtk_clipboard_set_can_store` 确保应用退出后数据仍可保留在桌面环境剪切板管理器中（敏感数据除外）。
3. **实时监听**：
   - 连接 `GtkClipboard` 的 `"owner-change"` GObject 信号，当剪切板所有者或内容发生变更时立即触发 `EventChannel` 事件。

### 6.6 Web (`xue_hua_navite_clipboard_web.dart`)
1. **基于 `package:web` 标准 API**：
   - 使用 `web.window.navigator.clipboard`（`read()`, `write()`, `readText()`, `writeText()`）。
2. **多格式 `ClipboardItem`**：
   - 支持同时写入 `text/plain`、`text/html`、`image/png` 的 `web.Blob`。
   - 对非标准格式（如 RTF、Markdown、自定义 MIME），自动添加 `"web "` 前缀（如 `"web text/rtf"`，符合 W3C Web Custom Formats 规范），并在读取时自动剥离前缀还原。
3. **降级与异常处理**：
   - 当浏览器因非安全上下文（非 HTTPS/localhost）或用户未授权 `clipboard-read` 权限抛出 `NotAllowedError` 时，在 `writeText` / `writeHtml` 场景下提供基于隐藏 DOM 节点 + `document.execCommand('copy')` 的兜底方案，并在读取失败时抛出结构化的 `ClipboardPermissionException`。

---

## 7. 异常处理与边界情况设计 (`ClipboardException`)

| 错误码 (`code`)            | 触发场景                                                                      | 处理策略与说明                                                     |
|:---------------------------|:------------------------------------------------------------------------------|:-------------------------------------------------------------------|
| `CLIPBOARD_BUSY`           | Windows `OpenClipboard` 被其他进程短暂锁死                                    | 原生层自动进行最多 5 次（每次间隔 15ms）重试；仍失败则返回此错误码 |
| `BACKGROUND_RESTRICTED`    | Android 10+ 应用处于后台时尝试读取剪切板                                      | 返回明确异常提示调用方仅在前台（`AppLifecycleState.resumed`）读取  |
| `PERMISSION_DENIED`        | Web 浏览器拒绝剪切板读取权限，或 iOS 16+ 用户在系统粘贴弹窗中点击“不允许粘贴” | 包装为 `ClipboardPermissionException`，便于业务层引导用户          |
| `FORMAT_CONVERSION_FAILED` | 损坏的图片字节或无法解析的编码                                                | 返回详细诊断信息，不影响同条目下其他格式的读取                     |
| `UNSUPPORTED_BUFFER`       | 在不支持命名剪切板或 Primary Selection 的平台上指定了特殊通道                 | 默认优雅降级或按配置抛出提示                                       |

---

## 8. 测试与验证计划

1. **Dart 单元测试 (`test/`)**：
   - Mock `XueHuaNaviteClipboardPlatform` 与 `MethodChannel`，覆盖所有数据模型序列化/反序列化、HTML 纯文本自动回退生成、过期定时器逻辑、异常映射。
2. **平台原生单元测试**：
   - Android (`XueHuaNaviteClipboardPluginTest.kt`)、Windows (`xue_hua_navite_clipboard_plugin_test.cpp`)、Linux (`xue_hua_navite_clipboard_plugin_test.cc`) 基础方法调用测试。
3. **全功能交互式示例应用 (`example/`)**：
   - 构建一个可视化剪切板工作台（Clipboard Inspector & Playground），支持：
     - 实时展示 `onClipboardChanged` 事件流、当前 `changeCount` 与所有底层 `rawPlatformFormats`。
     - 一键测试写入与读取：纯文本、敏感密码（验证系统弹窗隐藏与防历史）、HTML 富文本、RTF、画板生成的 PNG 图片、本地文件复制/剪切、自定义二进制数据、复合多条目。
     - 平台专属开关：Linux `Primary Selection` 切换、macOS `Find Pasteboard` 读写、iOS `localOnly` 与 `expiration` 测试。
