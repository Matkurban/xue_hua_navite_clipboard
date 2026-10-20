import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'xue_hua_navite_clipboard_platform_interface.dart';

/// An implementation of [XueHuaNaviteClipboardPlatform] that uses method channels.
class MethodChannelXueHuaNaviteClipboard extends XueHuaNaviteClipboardPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('xue_hua_navite_clipboard');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
