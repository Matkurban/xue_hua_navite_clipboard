/// 剪切板操作统一异常
class ClipboardException implements Exception {
  /// 错误代码（如 CLIPBOARD_BUSY, BACKGROUND_RESTRICTED, PERMISSION_DENIED, FORMAT_CONVERSION_FAILED, UNSUPPORTED_BUFFER）
  final String code;

  /// 人类可读的错误消息
  final String message;

  /// 平台底层附加信息
  final Object? details;

  const ClipboardException({
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'ClipboardException($code): $message';
}

/// 剪切板权限被拒绝异常（如 Web 端非安全上下文/未授权，或 iOS 16+ 用户拒绝粘贴弹窗）
class ClipboardPermissionException extends ClipboardException {
  const ClipboardPermissionException({required super.message, super.details})
    : super(code: 'PERMISSION_DENIED');
}
