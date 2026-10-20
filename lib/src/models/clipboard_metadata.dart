/// iOS / Android 文本内容模式预探测结果
enum ClipboardDetectedPattern {
  probableWebUrl('probableWebUrl'),
  probableWebSearch('probableWebSearch'),
  number('number'),
  emailAddress('emailAddress'),
  phoneNumber('phoneNumber'),
  postalAddress('postalAddress'),
  flightNumber('flightNumber'),
  shipmentTrackingNumber('shipmentTrackingNumber'),
  moneyAmount('moneyAmount');

  final String wireName;
  const ClipboardDetectedPattern(this.wireName);

  static ClipboardDetectedPattern? fromWireName(String? name) {
    for (final value in ClipboardDetectedPattern.values) {
      if (value.wireName == name) {
        return value;
      }
    }
    return null;
  }
}

/// 剪切板实时状态与元数据（不读取重型二进制内容）
class ClipboardMetadata {
  /// 系统剪切板变更序号（macOS/iOS changeCount, Windows SequenceNumber）
  final int changeCount;

  /// 内容写入时间戳（毫秒，若平台支持如 Android 8.0+）
  final int? timestampMs;

  /// 当前剪切板中包含的条目数量（Multi-item count）
  final int itemCount;

  /// 快速布尔判断
  final bool hasPlainText;
  final bool hasHtml;
  final bool hasRtf;
  final bool hasMarkdown;
  final bool hasUri;
  final bool hasImage;
  final bool hasFiles;
  final bool hasColor;

  /// 平台底层报告的所有原生格式标识符列表（MIME Types / UTIs / Win32 Format Names / GdkAtoms）
  final List<String> rawPlatformFormats;

  /// 预探测到的文本语义模式（iOS 14+ UIPasteboard.detectPatterns / Android 12+ TextClassifier）
  final Set<ClipboardDetectedPattern> detectedPatterns;

  const ClipboardMetadata({
    required this.changeCount,
    this.timestampMs,
    required this.itemCount,
    required this.hasPlainText,
    required this.hasHtml,
    required this.hasRtf,
    required this.hasMarkdown,
    required this.hasUri,
    required this.hasImage,
    required this.hasFiles,
    required this.hasColor,
    required this.rawPlatformFormats,
    this.detectedPatterns = const {},
  });

  factory ClipboardMetadata.fromMap(Map<Object?, Object?> map) {
    final rawFormats = map['rawPlatformFormats'];
    final List<String> formats = rawFormats is List
        ? rawFormats.whereType<String>().toList()
        : <String>[];

    final rawPatterns = map['detectedPatterns'];
    final Set<ClipboardDetectedPattern> patterns = <ClipboardDetectedPattern>{};
    if (rawPatterns is List) {
      for (final item in rawPatterns) {
        if (item is String) {
          final parsed = ClipboardDetectedPattern.fromWireName(item);
          if (parsed != null) {
            patterns.add(parsed);
          }
        }
      }
    }

    return ClipboardMetadata(
      changeCount: (map['changeCount'] as int?) ?? 0,
      timestampMs: map['timestampMs'] as int?,
      itemCount: (map['itemCount'] as int?) ?? 0,
      hasPlainText: (map['hasPlainText'] as bool?) ?? false,
      hasHtml: (map['hasHtml'] as bool?) ?? false,
      hasRtf: (map['hasRtf'] as bool?) ?? false,
      hasMarkdown: (map['hasMarkdown'] as bool?) ?? false,
      hasUri: (map['hasUri'] as bool?) ?? false,
      hasImage: (map['hasImage'] as bool?) ?? false,
      hasFiles: (map['hasFiles'] as bool?) ?? false,
      hasColor: (map['hasColor'] as bool?) ?? false,
      rawPlatformFormats: formats,
      detectedPatterns: patterns,
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'changeCount': changeCount,
      'itemCount': itemCount,
      'hasPlainText': hasPlainText,
      'hasHtml': hasHtml,
      'hasRtf': hasRtf,
      'hasMarkdown': hasMarkdown,
      'hasUri': hasUri,
      'hasImage': hasImage,
      'hasFiles': hasFiles,
      'hasColor': hasColor,
      'rawPlatformFormats': rawPlatformFormats,
      'detectedPatterns': detectedPatterns.map((e) => e.wireName).toList(),
    };
    if (timestampMs != null) {
      map['timestampMs'] = timestampMs;
    }
    return map;
  }
}
