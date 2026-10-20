import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard_platform_interface.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockXueHuaNaviteClipboardPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteClipboardPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final XueHuaNaviteClipboardPlatform initialPlatform = XueHuaNaviteClipboardPlatform.instance;

  test('$MethodChannelXueHuaNaviteClipboard is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelXueHuaNaviteClipboard>());
  });

  test('getPlatformVersion', () async {
    XueHuaNaviteClipboard xueHuaNaviteClipboardPlugin = XueHuaNaviteClipboard();
    MockXueHuaNaviteClipboardPlatform fakePlatform = MockXueHuaNaviteClipboardPlatform();
    XueHuaNaviteClipboardPlatform.instance = fakePlatform;

    expect(await xueHuaNaviteClipboardPlugin.getPlatformVersion(), '42');
  });
}
