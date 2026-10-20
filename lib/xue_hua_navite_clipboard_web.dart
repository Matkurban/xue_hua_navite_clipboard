import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'src/exceptions/clipboard_exception.dart';
import 'src/models/clipboard_change_event.dart';
import 'src/models/clipboard_format.dart';
import 'src/models/clipboard_item.dart';
import 'src/models/clipboard_metadata.dart';
import 'src/models/clipboard_read_options.dart';
import 'src/models/clipboard_write_options.dart';
import 'xue_hua_navite_clipboard_platform_interface.dart';

/// A web implementation of the XueHuaNaviteClipboardPlatform of the XueHuaNaviteClipboard plugin.
class XueHuaNaviteClipboardWeb extends XueHuaNaviteClipboardPlatform {
  /// Constructs a XueHuaNaviteClipboardWeb
  XueHuaNaviteClipboardWeb();

  static void registerWith(Registrar registrar) {
    XueHuaNaviteClipboardPlatform.instance = XueHuaNaviteClipboardWeb();
  }

  int _changeCount = 0;
  int? _lastTimestampMs;
  Timer? _expirationTimer;

  StreamController<ClipboardChangeEvent>? _changeController;
  JSFunction? _domClipboardListener;

  void _incrementChangeCount() {
    _changeCount++;
    _lastTimestampMs = DateTime.now().millisecondsSinceEpoch;
    if (_changeController != null && _changeController!.hasListener) {
      _changeController!.add(
        ClipboardChangeEvent(
          buffer: ClipboardBuffer.general,
          changeCount: _changeCount,
          timestampMs: _lastTimestampMs!,
        ),
      );
    }
  }

  void _startDomListening() {
    if (_domClipboardListener != null) return;
    _domClipboardListener = ((web.Event _) {
      _incrementChangeCount();
    }).toJS;
    web.window.document.addEventListener('copy', _domClipboardListener);
    web.window.document.addEventListener('cut', _domClipboardListener);
    web.window.document.addEventListener('paste', _domClipboardListener);
  }

  void _stopDomListening() {
    if (_domClipboardListener == null) return;
    web.window.document.removeEventListener('copy', _domClipboardListener);
    web.window.document.removeEventListener('cut', _domClipboardListener);
    web.window.document.removeEventListener('paste', _domClipboardListener);
    _domClipboardListener = null;
  }

  @override
  Future<String?> getPlatformVersion() async {
    return web.window.navigator.userAgent;
  }

  @override
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) async {
    _expirationTimer?.cancel();
    _expirationTimer = null;

    if (items.isEmpty) return false;
    final first = items.first;

    try {
      final clipboard = web.window.navigator.clipboard;
      // 若仅包含纯文本，优先使用兼容性最广的 writeText
      final onlyPlainText =
          first.plainText != null &&
          first.html == null &&
          first.rtfBytes == null &&
          first.markdown == null &&
          first.imageBytes == null &&
          first.uri == null &&
          first.colorValue == null &&
          first.customFormats.isEmpty;

      if (onlyPlainText) {
        await clipboard.writeText(first.plainText!).toDart;
      } else {
        final fallbackText =
            first.plainText ??
            first.uri?.toString() ??
            first.markdown ??
            (first.colorValue != null
                ? '#${first.colorValue!.toRadixString(16).padLeft(8, '0')}'
                : null) ??
            '';
        await clipboard.writeText(fallbackText).toDart;
      }

      _incrementChangeCount();

      if (options.expiration != null && options.expiration! > Duration.zero) {
        final targetCount = _changeCount;
        _expirationTimer = Timer(options.expiration!, () async {
          if (_changeCount == targetCount) {
            await clear(buffer: options.buffer);
          }
        });
      }
      return true;
    } catch (e) {
      throw ClipboardPermissionException(
        message: 'Failed to write to Web clipboard: $e',
        details: e.toString(),
      );
    }
  }

  @override
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
    String? targetFormat,
  }) async {
    try {
      final text = await web.window.navigator.clipboard.readText().toDart;
      final str = text.toDart;
      if (str.isEmpty) return const <ClipboardDataItem>[];

      Uri? parsedUri;
      if (str.startsWith('http://') ||
          str.startsWith('https://') ||
          str.startsWith('mailto:')) {
        parsedUri = Uri.tryParse(str);
      }

      return <ClipboardDataItem>[
        ClipboardDataItem(
          plainText: str,
          uri: parsedUri,
        ),
      ];
    } catch (e) {
      throw ClipboardPermissionException(
        message: 'Failed to read from Web clipboard: $e',
        details: e.toString(),
      );
    }
  }

  @override
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  }) async {
    bool hasText = false;
    bool hasUri = false;
    final Set<ClipboardDetectedPattern> patterns = <ClipboardDetectedPattern>{};
    try {
      final text = (await web.window.navigator.clipboard.readText().toDart).toDart;
      hasText = text.isNotEmpty;
      if (hasText) {
        final uri = Uri.tryParse(text.trim());
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          hasUri = true;
          if (detectPatterns) {
            patterns.add(ClipboardDetectedPattern.probableWebUrl);
          }
        }
        if (detectPatterns && num.tryParse(text.trim()) != null) {
          patterns.add(ClipboardDetectedPattern.number);
        }
      }
    } catch (_) {
      // 忽略浏览器未授权时的探测异常
    }

    return ClipboardMetadata(
      changeCount: _changeCount,
      timestampMs: _lastTimestampMs,
      itemCount: hasText ? 1 : 0,
      hasPlainText: hasText,
      hasHtml: false,
      hasRtf: false,
      hasMarkdown: false,
      hasUri: hasUri,
      hasImage: false,
      hasFiles: false,
      hasColor: false,
      rawPlatformFormats: hasText ? const <String>['text/plain'] : const <String>[],
      detectedPatterns: patterns,
    );
  }

  @override
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    return _changeCount;
  }

  @override
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    _expirationTimer?.cancel();
    _expirationTimer = null;
    try {
      await web.window.navigator.clipboard.writeText('').toDart;
      _incrementChangeCount();
      return true;
    } catch (e) {
      throw ClipboardPermissionException(
        message: 'Failed to clear Web clipboard: $e',
        details: utf8.encode(e.toString()),
      );
    }
  }

  @override
  Future<void> setPollingInterval(Duration interval) async {
    // Web 端使用 DOM 事件驱动，无需轮询
  }

  @override
  Stream<ClipboardChangeEvent> get onClipboardChanged {
    // 严格按需绑定 DOM 事件监听：仅当有订阅者时挂载，取消订阅时立即卸载
    _changeController ??= StreamController<ClipboardChangeEvent>.broadcast(
      onListen: _startDomListening,
      onCancel: _stopDomListening,
    );
    return _changeController!.stream;
  }
}
