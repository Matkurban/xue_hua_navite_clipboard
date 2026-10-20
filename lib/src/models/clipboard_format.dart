/// 剪切板目标通道/缓冲区类型
enum ClipboardBuffer {
  /// 系统默认通用剪切板（所有平台均支持）
  general('general'),

  /// Linux X11/Wayland 鼠标选中缓冲区（中键粘贴，仅 Linux 原生生效，其他平台回退至 general）
  primarySelection('primarySelection'),

  /// macOS 全局查找剪切板（Cmd+E 跨应用共享搜索词，仅 macOS 原生生效）
  macOsFind('macOsFind'),

  /// macOS 拖拽剪切板
  macOsDrag('macOsDrag'),

  /// macOS 字体样式剪切板
  macOsFont('macOsFont'),

  /// macOS 标尺样式剪切板
  macOsRuler('macOsRuler'),

  /// iOS / macOS 自定义命名剪切板（配合 customBufferName 使用）
  named('named');

  final String wireName;
  const ClipboardBuffer(this.wireName);

  static ClipboardBuffer fromWireName(String? name) {
    for (final value in ClipboardBuffer.values) {
      if (value.wireName == name) {
        return value;
      }
    }
    return ClipboardBuffer.general;
  }
}

/// 标准剪切板数据格式
enum StandardClipboardFormat {
  plainText('text/plain'),
  html('text/html'),
  rtf('text/rtf'),
  markdown('text/markdown'),
  uri('text/uri-list'),
  png('image/png'),
  jpeg('image/jpeg'),
  gif('image/gif'),
  webp('image/webp'),
  tiff('image/tiff'),
  bmp('image/bmp'),
  svg('image/svg+xml'),
  fileList('application/x-file-list'),
  color('application/x-color');

  final String mimeType;
  const StandardClipboardFormat(this.mimeType);

  static StandardClipboardFormat? fromMimeType(String? mime) {
    if (mime == null) {
      return null;
    }
    final normalized = mime.toLowerCase().trim();
    for (final fmt in StandardClipboardFormat.values) {
      if (fmt.mimeType == normalized) {
        return fmt;
      }
    }
    if (normalized == 'application/rtf') {
      return StandardClipboardFormat.rtf;
    }
    if (normalized == 'image/jpg') {
      return StandardClipboardFormat.jpeg;
    }
    return null;
  }
}
