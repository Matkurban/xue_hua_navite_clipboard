import 'clipboard_format.dart';

/// 剪切板读取选项
class ClipboardReadOptions {
  /// 目标剪切板通道
  final ClipboardBuffer buffer;

  /// 自定义命名剪切板名称
  final String? customBufferName;

  /// 期望读取的图片目标格式（默认转换输出为无损 PNG）
  final StandardClipboardFormat preferredImageFormat;

  /// 指定需要一并提取的自定义格式名称列表
  final List<String> requestedCustomFormats;

  const ClipboardReadOptions({
    this.buffer = ClipboardBuffer.general,
    this.customBufferName,
    this.preferredImageFormat = StandardClipboardFormat.png,
    this.requestedCustomFormats = const [],
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'buffer': buffer.wireName,
      'preferredImageFormat': preferredImageFormat.mimeType,
    };
    if (customBufferName != null) {
      map['customBufferName'] = customBufferName;
    }
    if (requestedCustomFormats.isNotEmpty) {
      map['requestedCustomFormats'] = requestedCustomFormats;
    }
    return map;
  }
}
