import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_clipboard/src/pigeon/clipboard_api.g.dart';
import 'package:xue_hua_navite_clipboard/src/pigeon_clipboard_backend.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String hostPrefix =
      'dev.flutter.pigeon.xue_hua_navite_clipboard.ClipboardHostApi';
  const String flutterEventChannel =
      'dev.flutter.pigeon.xue_hua_navite_clipboard.ClipboardFlutterApi.onClipboardChanged';

  late PigeonClipboardBackend backend;
  late TestDefaultBinaryMessenger messenger;

  bool nativeEventStreamListening = false;
  int currentChangeCount = 7;
  int clearCallCount = 0;
  int? lastPollingIntervalMs;
  List<Object?>? lastWriteArgs;
  WireClipboardReadOptions? lastReadOptions;
  PlatformException? simulatedHostError;

  ByteData? encodeReply({Object? result, PlatformException? error}) {
    return ClipboardHostApi.pigeonChannelCodec.encodeMessage(
      wrapResponse(result: result, error: error),
    );
  }

  void setHostHandler(
    String method,
    Future<Object?>? Function(List<Object?>? args) handler,
  ) {
    messenger.setMockMessageHandler('$hostPrefix.$method', (
      ByteData? message,
    ) async {
      if (simulatedHostError != null) {
        return encodeReply(error: simulatedHostError);
      }
      final Object? decoded = message == null
          ? null
          : ClipboardHostApi.pigeonChannelCodec.decodeMessage(message);
      final List<Object?>? args = decoded as List<Object?>?;
      final Object? res = await handler(args);
      return encodeReply(result: res);
    });
  }

  void clearHostHandlers() {
    for (final method in const <String>[
      'writeItems',
      'readItems',
      'getMetadata',
      'getChangeCount',
      'clear',
      'setPollingInterval',
      'startClipboardListening',
      'stopClipboardListening',
    ]) {
      messenger.setMockMessageHandler('$hostPrefix.$method', null);
    }
  }

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    backend = PigeonClipboardBackend(
      binaryMessenger: messenger,
      useNativeInterop: false,
    );

    nativeEventStreamListening = false;
    currentChangeCount = 7;
    clearCallCount = 0;
    lastPollingIntervalMs = null;
    lastWriteArgs = null;
    lastReadOptions = null;
    simulatedHostError = null;

    setHostHandler('writeItems', (args) async {
      lastWriteArgs = args;
      currentChangeCount++;
      return true;
    });

    setHostHandler('readItems', (args) async {
      lastReadOptions = args![0]! as WireClipboardReadOptions;
      return <WireClipboardItem>[
        WireClipboardItem(
          plainText: 'pigeon text',
          html: '<p>pigeon text</p>',
          uri: 'https://example.com/docs',
          imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
          imageMimeType: 'image/png',
          files: <String>['/Users/test/demo.txt'],
          fileCopyMode: WireFileCopyMode.cut,
          colorValue: 0xFFAABBCC,
          customFormats: <WireCustomFormatEntry>[
            WireCustomFormatEntry(
              format: 'application/x-custom',
              data: Uint8List.fromList(<int>[9, 8]),
            ),
          ],
        ),
      ];
    });

    setHostHandler('getMetadata', (args) async {
      return WireClipboardMetadata(
        changeCount: currentChangeCount,
        timestampMs: 1700000000000,
        itemCount: 1,
        hasPlainText: true,
        hasHtml: true,
        hasRtf: false,
        hasMarkdown: false,
        hasUri: false,
        hasImage: true,
        hasFiles: true,
        hasColor: true,
        rawPlatformFormats: <String>['text/plain', 'text/html', 'image/png'],
        detectedPatterns: <WireClipboardDetectedPattern>[
          WireClipboardDetectedPattern.probableWebUrl,
        ],
      );
    });

    setHostHandler('getChangeCount', (args) async => currentChangeCount);

    setHostHandler('clear', (args) async {
      clearCallCount++;
      currentChangeCount++;
      return true;
    });

    setHostHandler('setPollingInterval', (args) async {
      lastPollingIntervalMs = args![0]! as int;
      return null;
    });

    setHostHandler('startClipboardListening', (args) async {
      nativeEventStreamListening = true;
      return null;
    });

    setHostHandler('stopClipboardListening', (args) async {
      nativeEventStreamListening = false;
      return null;
    });
  });

  tearDown(() async {
    clearHostHandlers();
    await backend.dispose();
  });

  test(
    'writeItems serializes WireClipboardItem and WireClipboardWriteOptions',
    () async {
      final ok = await backend.writeItems(
        <ClipboardDataItem>[
          ClipboardDataItem(
            plainText: 'hello',
            html: '<b>hello</b>',
            uri: Uri.parse('https://example.com'),
            fileCopyMode: FileCopyMode.cut,
            customFormats: <String, Uint8List>{
              'application/x-node': Uint8List.fromList(<int>[4, 5]),
            },
          ),
        ],
        options: const ClipboardWriteOptions(
          buffer: ClipboardBuffer.macOsFind,
          isSensitive: true,
          localOnly: true,
          label: 'secret',
        ),
      );
      expect(ok, isTrue);
      expect(lastWriteArgs, isNotNull);

      final wireItems = (lastWriteArgs![0]! as List<Object?>)
          .cast<WireClipboardItem>();
      expect(wireItems.length, 1);
      expect(wireItems.first.plainText, 'hello');
      expect(wireItems.first.html, '<b>hello</b>');
      expect(wireItems.first.uri, 'https://example.com');
      expect(wireItems.first.fileCopyMode, WireFileCopyMode.cut);
      expect(wireItems.first.customFormats?.first.format, 'application/x-node');

      final wireOptions = lastWriteArgs![1]! as WireClipboardWriteOptions;
      expect(wireOptions.buffer, WireClipboardBuffer.macOsFind);
      expect(wireOptions.isSensitive, isTrue);
      expect(wireOptions.localOnly, isTrue);
      expect(wireOptions.label, 'secret');
    },
  );

  test('readItems and getMetadata deserialize Wire types properly', () async {
    final items = await backend.readItems(
      options: const ClipboardReadOptions(
        buffer: ClipboardBuffer.primarySelection,
        requestedCustomFormats: <String>['application/x-custom'],
      ),
      targetFormat: 'text/plain',
    );
    expect(lastReadOptions?.buffer, WireClipboardBuffer.primarySelection);
    expect(lastReadOptions?.targetFormat, 'text/plain');
    expect(lastReadOptions?.requestedCustomFormats, <String>[
      'application/x-custom',
    ]);

    expect(items.length, 1);
    expect(items.first.plainText, 'pigeon text');
    expect(items.first.html, '<p>pigeon text</p>');
    expect(items.first.uri.toString(), 'https://example.com/docs');
    expect(items.first.fileCopyMode, FileCopyMode.cut);
    expect(items.first.colorValue, 0xFFAABBCC);
    expect(
      items.first.customFormats['application/x-custom'],
      Uint8List.fromList(<int>[9, 8]),
    );

    final meta = await backend.getMetadata(detectPatterns: true);
    expect(meta.changeCount, 7);
    expect(meta.hasPlainText, isTrue);
    expect(meta.hasImage, isTrue);
    expect(
      meta.detectedPatterns.contains(ClipboardDetectedPattern.probableWebUrl),
      isTrue,
    );
  });

  test('maps PlatformException to ClipboardPermissionException and ClipboardException', () async {
    simulatedHostError = PlatformException(
      code: 'PERMISSION_DENIED',
      message: 'denied by policy',
    );
    await expectLater(
      backend.readItems(),
      throwsA(isA<ClipboardPermissionException>()),
    );

    simulatedHostError = PlatformException(
      code: 'BACKGROUND_RESTRICTED',
      message: 'app in background',
    );
    await expectLater(
      backend.getChangeCount(),
      throwsA(
        isA<ClipboardException>().having(
          (e) => e.code,
          'code',
          'BACKGROUND_RESTRICTED',
        ),
      ),
    );
  });

  test('onClipboardChanged manages listening lifecycle and decodes WireClipboardChangeEvent', () async {
    final events = <ClipboardChangeEvent>[];
    final stream = backend.onClipboardChanged;
    expect(nativeEventStreamListening, isFalse);

    final sub = stream.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    expect(nativeEventStreamListening, isTrue);

    final ByteData? encodedEvent = ClipboardFlutterApi.pigeonChannelCodec
        .encodeMessage(<Object?>[
          WireClipboardChangeEvent(
            buffer: WireClipboardBuffer.general,
            changeCount: 42,
            timestampMs: 1700000001234,
          ),
        ]);
    await messenger.handlePlatformMessage(
      flutterEventChannel,
      encodedEvent,
      (_) {},
    );

    await Future<void>.delayed(Duration.zero);
    expect(events.length, 1);
    expect(events.first.buffer, ClipboardBuffer.general);
    expect(events.first.changeCount, 42);
    expect(events.first.timestampMs, 1700000001234);

    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEventStreamListening, isFalse);
  });

  test(
    'writeItems with expiration clears only when changeCount is unchanged',
    () async {
      await backend.writeItems(
        const <ClipboardDataItem>[ClipboardDataItem(plainText: 'temp')],
        options: const ClipboardWriteOptions(
          expiration: Duration(milliseconds: 20),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(clearCallCount, 1);

      await backend.writeItems(
        const <ClipboardDataItem>[ClipboardDataItem(plainText: 'temp2')],
        options: const ClipboardWriteOptions(
          expiration: Duration(milliseconds: 20),
        ),
      );
      // Simulate external overwrite
      currentChangeCount++;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(clearCallCount, 1);
    },
  );

  test('setPollingInterval clamps below 100ms', () async {
    await backend.setPollingInterval(const Duration(milliseconds: 20));
    expect(lastPollingIntervalMs, 100);

    await backend.setPollingInterval(const Duration(milliseconds: 250));
    expect(lastPollingIntervalMs, 250);
  });
}
