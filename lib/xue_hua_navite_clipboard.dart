
import 'xue_hua_navite_clipboard_platform_interface.dart';

class XueHuaNaviteClipboard {
  Future<String?> getPlatformVersion() {
    return XueHuaNaviteClipboardPlatform.instance.getPlatformVersion();
  }
}
