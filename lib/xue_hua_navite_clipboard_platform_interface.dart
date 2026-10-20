import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'xue_hua_navite_clipboard_method_channel.dart';

abstract class XueHuaNaviteClipboardPlatform extends PlatformInterface {
  /// Constructs a XueHuaNaviteClipboardPlatform.
  XueHuaNaviteClipboardPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteClipboardPlatform _instance = MethodChannelXueHuaNaviteClipboard();

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

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
