import 'models/clipboard_change_event.dart';
import 'models/clipboard_format.dart';
import 'models/clipboard_item.dart';
import 'models/clipboard_metadata.dart';
import 'models/clipboard_read_options.dart';
import 'models/clipboard_write_options.dart';
import 'pigeon_clipboard_backend.dart';

/// 内部跨平台剪切板后端契约（由 Pigeon 原生后端或 Web 后端实现）
abstract class ClipboardBackend {
  /// 当前活跃的剪切板后端实例（默认使用基于 Pigeon 的原生后端）
  static ClipboardBackend instance = PigeonClipboardBackend();

  /// 写入一个或多个剪切板条目
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  });

  /// 读取剪切板中的所有条目（可选指定单一 targetFormat 加速按需读取）
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
    String? targetFormat,
  });

  /// 获取剪切板元数据（不拉取重型二进制载荷）
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  });

  /// 获取当前剪切板变更序号（changeCount / SequenceNumber）
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  });

  /// 清空指定剪切板通道
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  });

  /// 设置轮询间隔（仅对无系统级剪切板广播的平台如 macOS 生效，且仅在有监听者时运行）
  Future<void> setPollingInterval(Duration interval);

  /// 剪切板实时变更事件流：
  /// 仅当 Dart 侧存在活跃订阅者时原生端才会注册系统监听/定时器；
  /// 当所有订阅取消时原生端自动释放监听资源。
  Stream<ClipboardChangeEvent> get onClipboardChanged;
}
