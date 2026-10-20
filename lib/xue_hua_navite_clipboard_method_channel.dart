import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/exceptions/clipboard_exception.dart';
import 'src/models/clipboard_change_event.dart';
import 'src/models/clipboard_format.dart';
import 'src/models/clipboard_item.dart';
import 'src/models/clipboard_metadata.dart';
import 'src/models/clipboard_read_options.dart';
import 'src/models/clipboard_write_options.dart';
import 'xue_hua_navite_clipboard_platform_interface.dart';

/// An implementation of [XueHuaNaviteClipboardPlatform] that uses method and event channels.
class MethodChannelXueHuaNaviteClipboard extends XueHuaNaviteClipboardPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('xue_hua_navite_clipboard');

  /// The event channel used to receive clipboard change notifications on demand.
  /// Native listeners are only active while Dart subscribers are listening to this channel.
  @visibleForTesting
  final eventChannel = const EventChannel('xue_hua_navite_clipboard/events');

  Stream<ClipboardChangeEvent>? _onClipboardChangedStream;
  Timer? _expirationTimer;

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

  @override
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) async {
    _expirationTimer?.cancel();
    _expirationTimer = null;

    try {
      final result = await methodChannel.invokeMethod<bool>(
        'writeItems',
        <String, dynamic>{
          'items': items.map((e) => e.toMap()).toList(),
          'options': options.toMap(),
        },
      );

      // 若设置了过期时间，在 Dart 层提供跨平台安全兜底清理（比对写入后的 changeCount，若未被外部新内容覆盖则自动清除）
      if (options.expiration != null && options.expiration! > Duration.zero) {
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

      return result ?? false;
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
      final args = <String, dynamic>{
        'options': options.toMap(),
      };
      if (targetFormat != null) {
        args['targetFormat'] = targetFormat;
      }
      final rawList = await methodChannel.invokeMethod<List<Object?>>(
        'readItems',
        args,
      );
      if (rawList == null) {
        return const <ClipboardDataItem>[];
      }
      return rawList
          .whereType<Map<Object?, Object?>>()
          .map(ClipboardDataItem.fromMap)
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
      final args = <String, dynamic>{
        'buffer': buffer.wireName,
        'detectPatterns': detectPatterns,
      };
      if (customBufferName != null) {
        args['customBufferName'] = customBufferName;
      }
      final rawMap = await methodChannel.invokeMethod<Map<Object?, Object?>>(
        'getMetadata',
        args,
      );
      if (rawMap == null) {
        return const ClipboardMetadata(
          changeCount: 0,
          itemCount: 0,
          hasPlainText: false,
          hasHtml: false,
          hasRtf: false,
          hasMarkdown: false,
          hasUri: false,
          hasImage: false,
          hasFiles: false,
          hasColor: false,
          rawPlatformFormats: <String>[],
        );
      }
      return ClipboardMetadata.fromMap(rawMap);
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
      final args = <String, dynamic>{
        'buffer': buffer.wireName,
      };
      if (customBufferName != null) {
        args['customBufferName'] = customBufferName;
      }
      final count = await methodChannel.invokeMethod<int>(
        'getChangeCount',
        args,
      );
      return count ?? 0;
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
      final args = <String, dynamic>{
        'buffer': buffer.wireName,
      };
      if (customBufferName != null) {
        args['customBufferName'] = customBufferName;
      }
      final cleared = await methodChannel.invokeMethod<bool>(
        'clear',
        args,
      );
      return cleared ?? false;
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Future<void> setPollingInterval(Duration interval) async {
    try {
      await methodChannel.invokeMethod<void>(
        'setPollingInterval',
        <String, dynamic>{
          'intervalMs': interval.inMilliseconds < 100
              ? 100
              : interval.inMilliseconds,
        },
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  @override
  Stream<ClipboardChangeEvent> get onClipboardChanged {
    // EventChannel.receiveBroadcastStream() 内部通过 StreamController.broadcast(onListen, onCancel)
    // 严格保证：只有当外部调用 .listen() 时才会通知原生端开启监听；当最后一个订阅 cancel 时自动通知原生端停止监听。
    return _onClipboardChangedStream ??= eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map(
          (event) =>
              ClipboardChangeEvent.fromMap(event as Map<Object?, Object?>),
        );
  }
}
