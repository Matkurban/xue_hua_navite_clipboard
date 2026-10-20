# xue_hua_navite_clipboard

跨平台全功能原生剪切板 Flutter 插件，完整覆盖 **Android、iOS、macOS、Windows、Linux、Web** 六端原生剪切板的所有核心与高级能力。

详细架构与平台映射请参见 [DESIGN.md](DESIGN.md)。

## 核心特性

- **全格式读写**：纯文本 (`text/plain`)、HTML (`text/html`)、RTF (`text/rtf`)、Markdown (`text/markdown`)、URI/URL、图片 (`PNG`/`JPEG`/`TIFF`/`CF_DIB` 自动无损转 `PNG`)、文件与文件夹路径列表 (`Files`，支持桌面端 `Copy` 复制与 `Cut` 剪切语义)、颜色 (`Color`) 以及任意自定义格式二进制数据 (`customFormats`)。
- **复合条目与多条目 (`Multi-Item`)**：单次写入同一份数据的多种表示形式（如同时写入 HTML + 纯文本回退 + PNG 预览），或在支持的平台上读写多个独立条目。
- **无感元数据探测 (`getMetadata` / `hasFormat` / `getChangeCount`)**：无需拉取二进制载荷即可读取变更序号与格式列表（iOS 14+ 优先使用 `hasStrings`/`hasImages`/`detectPatterns` 避免提前触发系统粘贴横幅）。
- **隐私安全与自动过期 (`ClipboardWriteOptions`)**：支持 `isSensitive`（Android 13+ 隐藏预览弹窗、Windows 禁止进入 `Win+V` 历史记录与云剪切板、macOS/iOS `ConcealedType`、Linux `x-kde-passwordManagerHint`）、`isTransient`、`localOnly` 与 `expiration` 到期自动安全清理。
- **按需零开销实时监听 (`onClipboardChanged`)**：仅当 Dart 侧存在活跃订阅（`.listen()`）时原生端才会注册系统监听或启动定时器；当取消订阅（`.cancel()`）时原生端立即注销监听，无任何空闲开销。
- **多通道切换 (`ClipboardBuffer`)**：支持 Linux `primarySelection`（鼠标选中即复制/中键粘贴）、macOS 全局搜索剪切板（`macOsFind` 等）以及 iOS/macOS 自定义命名剪切板。

## 快速开始

```dart
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

final clipboard = XueHuaNaviteClipboard.instance;

// 1. 写入富文本 HTML（自动生成纯文本降级）
await clipboard.writeHtml('<b>Hello</b> <i>World</i>');

// 2. 写入敏感密码（隐藏系统弹窗预览、禁止历史记录与云同步、30秒后自动清空）
await clipboard.writeSensitiveText(
  'MySecretPassword123!',
  expiration: const Duration(seconds: 30),
);

// 3. 读取图片（各平台原生位图自动无损转为 PNG Uint8List）
final pngBytes = await clipboard.readImage();

// 4. 桌面端复制或剪切本地文件列表
await clipboard.writeFiles(
  ['/path/to/file1.pdf', '/path/to/file2.png'],
  mode: FileCopyMode.cut,
);

// 5. 按需监听剪切板变更（取消订阅后原生端自动停止监听）
final sub = clipboard.onClipboardChanged.listen((event) {
  print('Clipboard changed: count=${event.changeCount}');
});
// 不需要时取消监听，释放原生监听资源
await sub.cancel();
```
