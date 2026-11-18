import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'clipboard_backend.dart';
import 'exceptions/clipboard_exception.dart';
import 'models/clipboard_change_event.dart';
import 'models/clipboard_format.dart';
import 'models/clipboard_item.dart';
import 'models/clipboard_metadata.dart';
import 'models/clipboard_read_options.dart';
import 'models/clipboard_write_options.dart';
import 'models/file_copy_mode.dart';
import 'pigeon/clipboard_api.g.dart';

class _PigeonClipboardFlutterHandler implements ClipboardFlutterApi {
  _PigeonClipboardFlutterHandler(this._onChanged);

  final void Function(WireClipboardChangeEvent event) _onChanged;

  @override
  void onClipboardChanged(WireClipboardChangeEvent event) {
    _onChanged(event);
  }
}

/// 基于 Pigeon 30.x 的跨平台原生剪切板后端实现：
/// - Android / iOS / macOS: 自动使用 JNI / Objective-C FFI Native Interop 直调
/// - Windows / Linux: 使用类型安全的 StandardMessageCodec 通道通信
class PigeonClipboardBackend implements ClipboardBackend {
  PigeonClipboardBackend({
    this.binaryMessenger,
    @visibleForTesting this.useNativeInterop,
  });

  static const String _onClipboardChangedChannel =
      'dev.flutter.pigeon.xue_hua_navite_clipboard.ClipboardFlutterApi.onClipboardChanged';

  final BinaryMessenger? binaryMessenger;

  @visibleForTesting
  final bool? useNativeInterop;

  ClipboardHostApi? _cachedApi;
  _PigeonClipboardFlutterHandler? _flutterHandler;
  StreamController<ClipboardChangeEvent>? _changeController;
  Timer? _expirationTimer;

  bool get _shouldUseNativeInterop {
    final override = useNativeInterop;
    if (override != null) {
      return override;
    }
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  ClipboardHostApi get _api => _cachedApi ??= _shouldUseNativeInterop
      ? ClipboardHostApi.createWithNativeInteropApi(
          binaryMessenger: binaryMessenger,
        )
      : ClipboardHostApi(binaryMessenger: binaryMessenger);

  ClipboardException _mapPlatformException(PlatformException e) {
    if (e.code == 'PERMISSION_DENIED') {
      return ClipboardPermissionException(
        message: e.message ?? 'Clipboard permission denied.',
        details: e.details,
      );
    }
    return ClipboardException(
      code: e.code,
      message: e.message ?? 'Native clipboard operation failed.',
      details: e.details,
    );
  }

  void _setUpFlutterApi(ClipboardFlutterApi? api) {
    if (_shouldUseNativeInterop) {
      ClipboardFlutterApi.setUp(api, binaryMessenger: binaryMessenger);
      return;
    }
    final channel = BasicMessageChannel<Object?>(
      _onClipboardChangedChannel,
      ClipboardFlutterApi.pigeonChannelCodec,
      binaryMessenger: binaryMessenger,
    );
    if (api == null) {
      channel.setMessageHandler(null);
      return;
    }
    channel.setMessageHandler((Object? message) async {
      final args = message! as List<Object?>;
      final event = args[0]! as WireClipboardChangeEvent;
      try {
        api.onClipboardChanged(event);
        return wrapResponse(empty: true);
      } on PlatformException catch (e) {
        return wrapResponse(error: e);
      } catch (e) {
        return wrapResponse(
          error: PlatformException(code: 'error', message: e.toString()),
        );
      }
    });
  }

  void _startListening() {
    final handler = _flutterHandler ??= _PigeonClipboardFlutterHandler(
      _handleClipboardChanged,
    );
    _setUpFlutterApi(handler);
    unawaited(
      _api.startClipboardListening().then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          final controller = _changeController;
          if (controller != null &&
              !controller.isClosed &&
              controller.hasListener) {
            final mapped = error is PlatformException
                ? _mapPlatformException(error)
                : error;
            controller.addError(mapped, stackTrace);
          }
        },
      ),
    );
  }

  void _stopListening() {
    _setUpFlutterApi(null);
    unawaited(
      _api.stopClipboardListening().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  void _handleClipboardChanged(WireClipboardChangeEvent event) {
    final controller = _changeController;
    if (controller != null && !controller.isClosed && controller.hasListener) {
      controller.add(_fromWireChangeEvent(event));
    }
  }

  @override
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) async {
    _expirationTimer?.cancel();
    _expirationTimer = null;

    try {
      final wireItems = items.map(_toWireItem).toList();
      final wireOptions = _toWireWriteOptions(options);
      final result = await _api.writeItems(wireItems, wireOptions);

      // 若设置了过期时间，在 Dart 层提供跨平台安全兜底清理（比对写入后的 changeCount，若未被外部新内容覆盖则自动清除）
      if (result &&
          options.expiration != null &&
          options.expiration! > Duration.zero) {
        final writtenChangeCount = await getChangeCount(
          buffer: options.buffer,
          customBufferName: options.customBufferName,
        );
        _expirationTimer = Timer(options.expiration!, () async {
          try {
            final currentCount = await getChangeCount(
              buffer: options.buffer,
              customBufferName: options.customBufferName,
            );
            if (currentCount == writtenChangeCount) {
              await clear(
                buffer: options.buffer,
                customBufferName: options.customBufferName,
              );
            }
          } catch (_) {
            // 忽略后台到期清理异常
          }
        });
      }

      return result;
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
    String? targetFormat,
  }) async {
    try {
      final wireOptions = _toWireReadOptions(
        options,
        targetFormat: targetFormat,
      );
      final rawItems = await _api.readItems(wireOptions);
      return rawItems
          .map(_fromWireItem)
          .where((item) => !item.isEmpty)
          .toList();
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  }) async {
    try {
      final target = WireClipboardBufferTarget(
        buffer: _toWireBuffer(buffer),
        customBufferName: customBufferName,
      );
      final wireMeta = await _api.getMetadata(target, detectPatterns);
      return _fromWireMetadata(wireMeta);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    try {
      final target = WireClipboardBufferTarget(
        buffer: _toWireBuffer(buffer),
        customBufferName: customBufferName,
      );
      return await _api.getChangeCount(target);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    _expirationTimer?.cancel();
    _expirationTimer = null;
    try {
      final target = WireClipboardBufferTarget(
        buffer: _toWireBuffer(buffer),
        customBufferName: customBufferName,
      );
      return await _api.clear(target);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<void> setPollingInterval(Duration interval) async {
    try {
      final intervalMs = interval.inMilliseconds < 100
          ? 100
          : interval.inMilliseconds;
      await _api.setPollingInterval(intervalMs);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Stream<ClipboardChangeEvent> get onClipboardChanged {
    _changeController ??= StreamController<ClipboardChangeEvent>.broadcast(
      onListen: _startListening,
      onCancel: _stopListening,
    );
    return _changeController!.stream;
  }

  /// 释放测试或生命周期结束时持有的定时器与流控制器
  @visibleForTesting
  Future<void> dispose() async {
    _expirationTimer?.cancel();
    _expirationTimer = null;
    if (_changeController != null) {
      await _changeController!.close();
      _changeController = null;
    }
  }

  // ==================== Wire Type Converters ====================

  static WireClipboardBuffer _toWireBuffer(ClipboardBuffer buffer) {
    switch (buffer) {
      case ClipboardBuffer.general:
        return WireClipboardBuffer.general;
      case ClipboardBuffer.primarySelection:
        return WireClipboardBuffer.primarySelection;
      case ClipboardBuffer.macOsFind:
        return WireClipboardBuffer.macOsFind;
      case ClipboardBuffer.macOsDrag:
        return WireClipboardBuffer.macOsDrag;
      case ClipboardBuffer.macOsFont:
        return WireClipboardBuffer.macOsFont;
      case ClipboardBuffer.macOsRuler:
        return WireClipboardBuffer.macOsRuler;
      case ClipboardBuffer.named:
        return WireClipboardBuffer.named;
    }
  }

  static ClipboardBuffer _fromWireBuffer(WireClipboardBuffer buffer) {
    switch (buffer) {
      case WireClipboardBuffer.general:
        return ClipboardBuffer.general;
      case WireClipboardBuffer.primarySelection:
        return ClipboardBuffer.primarySelection;
      case WireClipboardBuffer.macOsFind:
        return ClipboardBuffer.macOsFind;
      case WireClipboardBuffer.macOsDrag:
        return ClipboardBuffer.macOsDrag;
      case WireClipboardBuffer.macOsFont:
        return ClipboardBuffer.macOsFont;
      case WireClipboardBuffer.macOsRuler:
        return ClipboardBuffer.macOsRuler;
      case WireClipboardBuffer.named:
        return ClipboardBuffer.named;
    }
  }

  static WireFileCopyMode _toWireFileCopyMode(FileCopyMode mode) {
    switch (mode) {
      case FileCopyMode.copy:
        return WireFileCopyMode.copy;
      case FileCopyMode.cut:
        return WireFileCopyMode.cut;
    }
  }

  static FileCopyMode _fromWireFileCopyMode(WireFileCopyMode mode) {
    switch (mode) {
      case WireFileCopyMode.copy:
        return FileCopyMode.copy;
      case WireFileCopyMode.cut:
        return FileCopyMode.cut;
    }
  }

  static ClipboardDetectedPattern _fromWireDetectedPattern(
    WireClipboardDetectedPattern pattern,
  ) {
    switch (pattern) {
      case WireClipboardDetectedPattern.probableWebUrl:
        return ClipboardDetectedPattern.probableWebUrl;
      case WireClipboardDetectedPattern.probableWebSearch:
        return ClipboardDetectedPattern.probableWebSearch;
      case WireClipboardDetectedPattern.number:
        return ClipboardDetectedPattern.number;
      case WireClipboardDetectedPattern.emailAddress:
        return ClipboardDetectedPattern.emailAddress;
      case WireClipboardDetectedPattern.phoneNumber:
        return ClipboardDetectedPattern.phoneNumber;
      case WireClipboardDetectedPattern.postalAddress:
        return ClipboardDetectedPattern.postalAddress;
      case WireClipboardDetectedPattern.flightNumber:
        return ClipboardDetectedPattern.flightNumber;
      case WireClipboardDetectedPattern.shipmentTrackingNumber:
        return ClipboardDetectedPattern.shipmentTrackingNumber;
      case WireClipboardDetectedPattern.moneyAmount:
        return ClipboardDetectedPattern.moneyAmount;
    }
  }

  static WireClipboardItem _toWireItem(ClipboardDataItem item) {
    return WireClipboardItem(
      plainText: item.plainText,
      html: item.html,
      rtfBytes: item.rtfBytes,
      markdown: item.markdown,
      uri: item.uri?.toString(),
      imageBytes: item.imageBytes,
      imageMimeType: item.imageMimeType,
      files: item.files != null && item.files!.isNotEmpty ? item.files : null,
      fileCopyMode: _toWireFileCopyMode(item.fileCopyMode),
      colorValue: item.colorValue,
      customFormats: item.customFormats.isEmpty
          ? null
          : item.customFormats.entries
                .map(
                  (entry) => WireCustomFormatEntry(
                    format: entry.key,
                    data: entry.value,
                  ),
                )
                .toList(),
    );
  }

  static ClipboardDataItem _fromWireItem(WireClipboardItem wire) {
    final uriStr = wire.uri;
    final parsedUri = (uriStr != null && uriStr.isNotEmpty)
        ? Uri.tryParse(uriStr)
        : null;

    final customMap = <String, Uint8List>{};
    final wireCustomFormats = wire.customFormats;
    if (wireCustomFormats != null) {
      for (final entry in wireCustomFormats) {
        customMap[entry.format] = entry.data;
      }
    }

    return ClipboardDataItem(
      plainText: wire.plainText,
      html: wire.html,
      rtfBytes: wire.rtfBytes,
      markdown: wire.markdown,
      uri: parsedUri,
      imageBytes: wire.imageBytes,
      imageMimeType: wire.imageMimeType ?? 'image/png',
      files: wire.files,
      fileCopyMode: _fromWireFileCopyMode(wire.fileCopyMode),
      colorValue: wire.colorValue,
      customFormats: customMap,
    );
  }

  static WireClipboardWriteOptions _toWireWriteOptions(
    ClipboardWriteOptions options,
  ) {
    return WireClipboardWriteOptions(
      buffer: _toWireBuffer(options.buffer),
      customBufferName: options.customBufferName,
      isSensitive: options.isSensitive,
      isTransient: options.isTransient,
      localOnly: options.localOnly,
      expirationMs: options.expiration?.inMilliseconds,
      label: options.label,
    );
  }

  static WireClipboardReadOptions _toWireReadOptions(
    ClipboardReadOptions options, {
    String? targetFormat,
  }) {
    return WireClipboardReadOptions(
      buffer: _toWireBuffer(options.buffer),
      customBufferName: options.customBufferName,
      preferredImageFormat: options.preferredImageFormat.mimeType,
      requestedCustomFormats: options.requestedCustomFormats,
      targetFormat: targetFormat,
    );
  }

  static ClipboardMetadata _fromWireMetadata(WireClipboardMetadata wire) {
    return ClipboardMetadata(
      changeCount: wire.changeCount,
      timestampMs: wire.timestampMs,
      itemCount: wire.itemCount,
      hasPlainText: wire.hasPlainText,
      hasHtml: wire.hasHtml,
      hasRtf: wire.hasRtf,
      hasMarkdown: wire.hasMarkdown,
      hasUri: wire.hasUri,
      hasImage: wire.hasImage,
      hasFiles: wire.hasFiles,
      hasColor: wire.hasColor,
      rawPlatformFormats: wire.rawPlatformFormats,
      detectedPatterns: wire.detectedPatterns
          .map(_fromWireDetectedPattern)
          .toSet(),
    );
  }

  static ClipboardChangeEvent _fromWireChangeEvent(
    WireClipboardChangeEvent wire,
  ) {
    return ClipboardChangeEvent(
      buffer: _fromWireBuffer(wire.buffer),
      changeCount: wire.changeCount,
      timestampMs: wire.timestampMs,
    );
  }
}
