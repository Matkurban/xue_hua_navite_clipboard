---
name: xue_hua_navite_clipboard-usage
description: >-
  Use when reading, writing, inspecting, or monitoring the system clipboard in Flutter across Android, iOS, macOS, Windows, Linux, and Web using package:xue_hua_navite_clipboard.
---

# Using `package:xue_hua_navite_clipboard`

`xue_hua_navite_clipboard` provides full-featured cross-platform native clipboard operations for Flutter, including plain text, HTML, RTF, Markdown, URIs, lossless PNG images, file copy/cut lists, colors, custom binary formats, privacy/sensitivity flags, and on-demand clipboard change monitoring.

## Guidelines

* **Use the singleton instance**: Access clipboard methods via `XueHuaNaviteClipboard.instance` (or construct `XueHuaNaviteClipboard()` when injecting a custom instance for testing).
* **Protect sensitive secrets**: Always use `writeSensitiveText()` (or set `ClipboardWriteOptions(isSensitive: true, isTransient: true, localOnly: true, expiration: ...)`) when copying passwords, tokens, seed phrases, or verification codes so the OS conceals previews, skips clipboard history (`Win+V`), and prevents cloud syncing.
* **Include plain-text fallbacks for rich formats**: When calling `writeHtml()`, `writeRtf()`, `writeMarkdown()`, or `writeCustomData()`, provide `plainTextFallback` (or rely on `writeHtml`'s automatic HTML tag stripping) so plain-text editors can still paste the content.
* **Write composite items in a single call**: When copying an object that has multiple representations (e.g., HTML + plain text + PNG preview), use `writeItem(ClipboardDataItem(...))` rather than sequential `write*` calls, because each write overwrites the previous clipboard contents.
* **Inspect before reading heavy payloads**: Call `getMetadata()` or `hasFormat()` to check available formats (`hasImage`, `hasFiles`, `hasHtml`, `changeCount`) before calling `readImage()` or `readItems()`. On iOS 14+, `getMetadata()` checks `hasStrings`/`hasImages`/`hasURLs` without prematurely triggering the system paste banner.
* **Cancel `onClipboardChanged` subscriptions when done**: Native clipboard listeners and polling timers are strictly on-demand—they start only when `onClipboardChanged.listen(...)` is called and stop immediately when the last `StreamSubscription` is cancelled. Always cancel your subscription in `dispose()`.
* **Handle `ClipboardException`**: Wrap clipboard reads/writes in `try`/`catch` for `ClipboardPermissionException` (Web permission denied or iOS user denied paste) and `ClipboardException` (e.g., `BACKGROUND_RESTRICTED` on Android 10+ when in background, or `CLIPBOARD_BUSY` on Windows).

## Examples

### Writing and reading rich formats (HTML, RTF, Images, Files)

```dart
import 'dart:typed_data';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

final clipboard = XueHuaNaviteClipboard.instance;

Future<void> copyAndReadExamples(Uint8List pngBytes) async {
  // 1. Write HTML with automatic plain-text fallback
  await clipboard.writeHtml(
    '<h2>Report Summary</h2><p>Status: <b>Passed</b></p>',
  );

  // 2. Write a composite item (HTML + Plain Text + PNG snapshot simultaneously)
  await clipboard.writeItem(
    ClipboardDataItem(
      plainText: 'Report Summary - Status: Passed',
      html: '<h2>Report Summary</h2><p>Status: <b>Passed</b></p>',
      imageBytes: pngBytes,
    ),
  );

  // 3. Copy or cut local files for desktop file managers (Finder / Explorer / Nautilus)
  await clipboard.writeFiles(
    <String>['/path/to/document.pdf', '/path/to/photo.png'],
    mode: FileCopyMode.copy,
  );

  // 4. Inspect metadata before reading heavy image data
  final meta = await clipboard.getMetadata(detectPatterns: true);
  if (meta.hasImage) {
    // Native bitmaps (TIFF on macOS, CF_DIB on Windows, GdkPixbuf on Linux)
    // are automatically converted to lossless PNG bytes.
    final Uint8List? image = await clipboard.readImage();
    if (image != null) {
      // Render directly with Image.memory(image)
    }
  }
}
```

### Copying sensitive passwords with auto-expiration

```dart
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

Future<void> copySecret(String apiKey) async {
  // Marks content as sensitive (Android 13+ hidden preview, Windows excluded from
  // Win+V history & cloud sync, macOS ConcealedType, iOS localOnly) and clears after 30s.
  await XueHuaNaviteClipboard.instance.writeSensitiveText(
    apiKey,
    expiration: const Duration(seconds: 30),
  );
}
```

### On-demand clipboard change monitoring

```dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

class ClipboardWatcherWidget extends StatefulWidget {
  const ClipboardWatcherWidget({super.key});

  @override
  State<ClipboardWatcherWidget> createState() => _ClipboardWatcherWidgetState();
}

class _ClipboardWatcherWidgetState extends State<ClipboardWatcherWidget> {
  StreamSubscription<ClipboardChangeEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    // Native listener is registered only while this subscription is active.
    _subscription = XueHuaNaviteClipboard.instance.onClipboardChanged.listen(
      (ClipboardChangeEvent event) async {
        final text = await XueHuaNaviteClipboard.instance.readText();
        debugPrint('Clipboard changed (#${event.changeCount}): $text');
      },
    );
  }

  @override
  void dispose() {
    // Always cancel to release native OS hooks / timers immediately.
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
```
