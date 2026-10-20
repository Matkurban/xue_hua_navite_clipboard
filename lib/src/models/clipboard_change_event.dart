import 'clipboard_format.dart';

/// 剪切板变更事件数据
class ClipboardChangeEvent {
  /// 发生变更的剪切板通道
  final ClipboardBuffer buffer;

  /// 当前最新变更序号（changeCount / SequenceNumber）
  final int changeCount;

  /// 事件触发时间戳（毫秒）
  final int timestampMs;

  const ClipboardChangeEvent({
    required this.buffer,
    required this.changeCount,
    required this.timestampMs,
  });

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  factory ClipboardChangeEvent.fromMap(Map<Object?, Object?> map) {
    return ClipboardChangeEvent(
      buffer: ClipboardBuffer.fromWireName(map['buffer'] as String?),
      changeCount: (map['changeCount'] as int?) ?? 0,
      timestampMs:
          (map['timestampMs'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'buffer': buffer.wireName,
      'changeCount': changeCount,
      'timestampMs': timestampMs,
    };
  }
}
