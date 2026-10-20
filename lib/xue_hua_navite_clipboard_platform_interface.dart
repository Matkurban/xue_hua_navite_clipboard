import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/models/clipboard_change_event.dart';
import 'src/models/clipboard_format.dart';
import 'src/models/clipboard_item.dart';
import 'src/models/clipboard_metadata.dart';
import 'src/models/clipboard_read_options.dart';
import 'src/models/clipboard_write_options.dart';
import 'xue_hua_navite_clipboard_method_channel.dart';

abstract class XueHuaNaviteClipboardPlatform extends PlatformInterface {
  /// Constructs a XueHuaNaviteClipboardPlatform.
  XueHuaNaviteClipboardPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteClipboardPlatform _instance =
      MethodChannelXueHuaNaviteClipboard();

  /// The default instance of [XueHuaNaviteClipboardPlatform] to use.
  ///
  /// Defaults to [MethodChannelXueHuaNaviteClipboard].
  static XueHuaNaviteClipboardPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [XueHuaNaviteClipboardPlatform] when
  /// they register themselves.
  static set instance(XueHuaNaviteClipboardPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// 获取平台系统版本信息
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// 写入一个或多个剪切板条目
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) {
    throw UnimplementedError('writeItems() has not been implemented.');
  }

  /// 读取剪切板中的所有条目（可选指定单一 targetFormat 加速按需读取）
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
    String? targetFormat,
  }) {
    throw UnimplementedError('readItems() has not been implemented.');
  }

  /// 获取剪切板元数据（不拉取重型二进制载荷）
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  }) {
    throw UnimplementedError('getMetadata() has not been implemented.');
  }

  /// 获取当前剪切板变更序号（changeCount / SequenceNumber）
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) {
    throw UnimplementedError('getChangeCount() has not been implemented.');
  }

  /// 清空指定剪切板通道
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) {
    throw UnimplementedError('clear() has not been implemented.');
  }

  /// 设置轮询间隔（仅对无系统级剪切板广播的平台如 macOS 生效，且仅在有监听者时运行）
  Future<void> setPollingInterval(Duration interval) {
    throw UnimplementedError('setPollingInterval() has not been implemented.');
  }

  /// 剪切板实时变更事件流：
  /// 仅当 Dart 侧存在活跃订阅者（StreamSubscription）时原生端才会注册系统监听/定时器；
  /// 当所有订阅取消时原生端自动释放监听资源，无空闲开销。
  Stream<ClipboardChangeEvent> get onClipboardChanged {
    throw UnimplementedError('onClipboardChanged has not been implemented.');
  }
}
