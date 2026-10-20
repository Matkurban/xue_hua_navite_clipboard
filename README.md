English | [简体中文](README.zh-CN.md)

# xue_hua_navite_clipboard

A cross-platform, full-featured native clipboard plugin for Flutter. It covers the core and advanced clipboard capabilities on **Android, iOS, macOS, Windows, Linux, and Web**.

See [DESIGN.md](DESIGN.md) for the architecture and platform mapping.

## Features

- **Full-format read and write**: plain text (`text/plain`), HTML (`text/html`), RTF (`text/rtf`), Markdown (`text/markdown`), URI/URL, images (`PNG` / `JPEG` / `TIFF` / `CF_DIB`, converted losslessly to `PNG`), file and folder path lists (`Files`, including desktop `Copy` and `Cut`), colors (`Color`), and arbitrary custom-format binary data (`customFormats`).
- **Compound items and multi-item (`Multi-Item`)**: write several representations of the same data in one call (for example HTML plus a plain-text fallback plus a PNG preview), or read and write multiple independent items on platforms that support it.
- **Metadata probing without payloads (`getMetadata` / `hasFormat` / `getChangeCount`)**: read the change count and format list without fetching binary payloads. On iOS 14+, `hasStrings`, `hasImages`, and `detectPatterns` are preferred so the system paste banner is not triggered early.
- **Privacy and automatic expiration (`ClipboardWriteOptions`)**: `isSensitive` (hide the preview popup on Android 13+, keep the item out of `Win+V` history and the cloud clipboard on Windows, `ConcealedType` on macOS/iOS, `x-kde-passwordManagerHint` on Linux), plus `isTransient`, `localOnly`, and `expiration` for automatic secure clearing.
- **On-demand listening with no idle cost (`onClipboardChanged`)**: the native side registers a system listener or starts a timer only while Dart has an active subscription (`.listen()`). Cancelling the subscription (`.cancel()`) unregisters that listener immediately.
- **Multiple buffers (`ClipboardBuffer`)**: Linux `primarySelection` (select-to-copy and middle-click paste), the macOS global find pasteboard (`macOsFind` and others), and custom named pasteboards on iOS and macOS.

## Quick start

```dart
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

final clipboard = XueHuaNaviteClipboard.instance;

// 1. Write rich HTML (a plain-text fallback is generated automatically)
await clipboard.writeHtml('<b>Hello</b> <i>World</i>');

// 2. Write a sensitive password (hide the system preview, exclude it from
//    history and cloud sync, and clear it automatically after 30 seconds)
await clipboard.writeSensitiveText(
  'MySecretPassword123!',
  expiration: const Duration(seconds: 30),
);

// 3. Read an image (native bitmaps are converted losslessly to a PNG Uint8List)
final pngBytes = await clipboard.readImage();

// 4. Copy or cut a list of local files on desktop
await clipboard.writeFiles(
  ['/path/to/file1.pdf', '/path/to/file2.png'],
  mode: FileCopyMode.cut,
);

// 5. Listen for clipboard changes only while subscribed
//    (the native listener stops when the subscription is cancelled)
final sub = clipboard.onClipboardChanged.listen((event) {
  print('Clipboard changed: count=${event.changeCount}');
});
// Cancel when you no longer need updates to release the native listener
await sub.cancel();
```
