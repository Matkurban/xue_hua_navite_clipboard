import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard_method_channel.dart';

class MockXueHuaNaviteClipboardPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteClipboardPlatform {
  List<ClipboardDataItem> storedItems = <ClipboardDataItem>[];
  ClipboardWriteOptions? lastWriteOptions;
  ClipboardReadOptions? lastReadOptions;
  String? lastTargetFormat;
  int changeCount = 0;
  int activeListenerCount = 0;
  Duration lastPollingInterval = const Duration(milliseconds: 500);

  late final StreamController<ClipboardChangeEvent> _controller =
      StreamController<ClipboardChangeEvent>.broadcast(
        onListen: () {
          activeListenerCount++;
        },
        onCancel: () {
          activeListenerCount--;
        },
      );

  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> writeItems(
    List<ClipboardDataItem> items, {
    ClipboardWriteOptions options = const ClipboardWriteOptions(),
  }) async {
    storedItems = List<ClipboardDataItem>.from(items);
    lastWriteOptions = options;
    changeCount++;
    if (_controller.hasListener) {
      _controller.add(
        ClipboardChangeEvent(
          buffer: options.buffer,
          changeCount: changeCount,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return true;
  }

  @override
  Future<List<ClipboardDataItem>> readItems({
    ClipboardReadOptions options = const ClipboardReadOptions(),
    String? targetFormat,
  }) async {
    lastReadOptions = options;
    lastTargetFormat = targetFormat;
    return storedItems;
  }

  @override
  Future<ClipboardMetadata> getMetadata({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
    bool detectPatterns = false,
  }) async {
    final first = storedItems.isNotEmpty ? storedItems.first : null;
    final formats = <String>[
      if (first?.plainText != null) 'text/plain',
      if (first?.html != null) 'text/html',
      if (first?.rtfBytes != null) 'text/rtf',
      if (first?.markdown != null) 'text/markdown',
      if (first?.uri != null) 'text/uri-list',
      if (first?.imageBytes != null) 'image/png',
      if (first?.files != null && first!.files!.isNotEmpty)
        'application/x-file-list',
      if (first?.colorValue != null) 'application/x-color',
      if (first != null) ...first.customFormats.keys,
    ];
    return ClipboardMetadata(
      changeCount: changeCount,
      itemCount: storedItems.length,
      hasPlainText: first?.plainText != null,
      hasHtml: first?.html != null,
      hasRtf: first?.rtfBytes != null,
      hasMarkdown: first?.markdown != null,
      hasUri: first?.uri != null,
      hasImage: first?.imageBytes != null,
      hasFiles: first?.files != null && first!.files!.isNotEmpty,
      hasColor: first?.colorValue != null,
      rawPlatformFormats: formats,
    );
  }

  @override
  Future<int> getChangeCount({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    return changeCount;
  }

  @override
  Future<bool> clear({
    ClipboardBuffer buffer = ClipboardBuffer.general,
    String? customBufferName,
  }) async {
    storedItems = <ClipboardDataItem>[];
    changeCount++;
    return true;
  }

  @override
  Future<void> setPollingInterval(Duration interval) async {
    lastPollingInterval = interval;
  }

  @override
  Stream<ClipboardChangeEvent> get onClipboardChanged => _controller.stream;
}

void main() {
  final XueHuaNaviteClipboardPlatform initialPlatform =
      XueHuaNaviteClipboardPlatform.instance;

  late XueHuaNaviteClipboard clipboard;
  late MockXueHuaNaviteClipboardPlatform fakePlatform;

  setUp(() {
    clipboard = XueHuaNaviteClipboard();
    fakePlatform = MockXueHuaNaviteClipboardPlatform();
    XueHuaNaviteClipboardPlatform.instance = fakePlatform;
  });

  test('$MethodChannelXueHuaNaviteClipboard is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelXueHuaNaviteClipboard>());
  });

  test('getPlatformVersion', () async {
    expect(await clipboard.getPlatformVersion(), '42');
  });

  test('writeText and readText', () async {
    await clipboard.writeText('Hello Native Clipboard');
    expect(await clipboard.readText(), 'Hello Native Clipboard');
    expect(await clipboard.hasFormat('text/plain'), isTrue);
  });

  test('writeSensitiveText sets privacy options automatically', () async {
    await clipboard.writeSensitiveText(
      'MySuperSecretPassword!123',
      expiration: const Duration(seconds: 30),
    );
    expect(fakePlatform.lastWriteOptions?.isSensitive, isTrue);
    expect(fakePlatform.lastWriteOptions?.isTransient, isTrue);
    expect(fakePlatform.lastWriteOptions?.localOnly, isTrue);
    expect(
      fakePlatform.lastWriteOptions?.expiration,
      const Duration(seconds: 30),
    );
    expect(await clipboard.readText(), 'MySuperSecretPassword!123');
  });

  test('writeHtml generates plainText fallback automatically', () async {
    await clipboard.writeHtml('<b>Hello</b><br/><i>World</i>');
    expect(await clipboard.readHtml(), '<b>Hello</b><br/><i>World</i>');
    expect(await clipboard.readText(), 'Hello\nWorld');
  });

  test('writeRtfString and readRtf', () async {
    const rtf = r'{\rtf1\ansi\b Hello RTF\b0}';
    await clipboard.writeRtfString(rtf, plainTextFallback: 'Hello RTF');
    final rtfBytes = await clipboard.readRtf();
    expect(rtfBytes, isNotNull);
    expect(utf8.decode(rtfBytes!), rtf);
    expect(await clipboard.readText(), 'Hello RTF');
  });

  test('writeImage and readImage', () async {
    final pngStub = Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
    await clipboard.writeImage(pngStub);
    expect(await clipboard.readImage(), pngStub);
    expect(await clipboard.hasFormat('image/png'), isTrue);
  });

  test('writeFiles and readFiles with copy/cut mode', () async {
    final paths = <String>['/tmp/a.txt', '/tmp/b.png'];
    await clipboard.writeFiles(paths, mode: FileCopyMode.cut);
    expect(await clipboard.readFiles(), paths);
    expect(await clipboard.readFileCopyMode(), FileCopyMode.cut);
  });

  test('writeColor and readColor', () async {
    await clipboard.writeColor(0xFF336699);
    expect(await clipboard.readColor(), 0xFF336699);
    expect(await clipboard.readText(), '#FF336699');
  });

  test('writeCustomData and readCustomData', () async {
    final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    await clipboard.writeCustomData('application/x-xuehua-node', payload);
    expect(
      await clipboard.readCustomData('application/x-xuehua-node'),
      payload,
    );
    expect(await clipboard.hasFormat('application/x-xuehua-node'), isTrue);
  });

  test('onClipboardChanged only activates native listener when subscribed', () async {
    // 未设置监听时，原生端活跃监听数为 0
    expect(fakePlatform.activeListenerCount, 0);

    final events = <ClipboardChangeEvent>[];
    final sub = clipboard.onClipboardChanged.listen(events.add);

    // 订阅后激活监听
    expect(fakePlatform.activeListenerCount, 1);

    await clipboard.writeText('Trigger event');
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 1);
    expect(events.first.changeCount, 1);

    // 取消订阅后立即释放监听
    await sub.cancel();
    expect(fakePlatform.activeListenerCount, 0);
  });
}
