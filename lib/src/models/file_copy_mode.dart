/// 文件写入模式（用于桌面端资源管理器复制或剪切文件）
enum FileCopyMode {
  /// 复制文件（Ctrl+C / Cmd+C）
  copy('copy'),

  /// 剪切/移动文件（Ctrl+X，Windows Preferred DropEffect = DROPEFFECT_MOVE，Linux gnome-copied-files = cut）
  cut('cut');

  final String wireName;
  const FileCopyMode(this.wireName);

  static FileCopyMode fromWireName(String? name) {
    if (name == 'cut') return FileCopyMode.cut;
    return FileCopyMode.copy;
  }
}
