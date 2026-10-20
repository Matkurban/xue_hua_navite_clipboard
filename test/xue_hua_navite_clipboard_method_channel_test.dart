import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelXueHuaNaviteClipboard platform =
      MethodChannelXueHuaNaviteClipboard();
  const MethodChannel channel = MethodChannel('xue_hua_navite_clipboard');
  const MethodChannel eventMethodChannel =
      MethodChannel('xue_hua_navite_clipboard/events');

  bool nativeEventStreamListening = false;
  MethodCall? lastMethodCall;

  setUp(() {
    nativeEventStreamListening = false;
    lastMethodCall = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          lastMethodCall = methodCall;
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'writeItems':
              return true;
            case 'readItems':
              return <Map<String, Object?>>[
                <String, Object?>{
                  'plainText': 'channel text',
                  'html': '<p>channel text</p>',
                  'imageBytes': Uint8List.fromList(<int>[1, 2, 3]),
                  'imageMimeType': 'image/png',
                  'files': <String>['/Users/test/demo.txt'],
                  'fileCopyMode': 'cut',
                  'colorValue': 0xFFAABBCC,
                },
              ];
            case 'getMetadata':
              return <String, Object?>{
                'changeCount': 7,
                'timestampMs': 1700000000000,
                'itemCount': 1,
                'hasPlainText': true,
                'hasHtml': true,
                'hasRtf': false,
                'hasMarkdown': false,
                'hasUri': false,
                'hasImage': true,
                'hasFiles': true,
                'hasColor': true,
                'rawPlatformFormats': <String>['text/plain', 'text/html', 'image/png'],
                'detectedPatterns': <String>['probableWebUrl'],
              };
            case 'getChangeCount':
              return 7;
            case 'clear':
              return true;
            case 'setPollingInterval':
              return null;
            default:
              return null;
          }
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventMethodChannel, (MethodCall call) async {
          if (call.method == 'listen') {
            nativeEventStreamListening = true;
            return null;
          } else if (call.method == 'cancel') {
            nativeEventStreamListening = false;
            return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventMethodChannel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('writeItems serializes items and options properly', () async {
    final ok = await platform.writeItems(
      <ClipboardDataItem>[
        const ClipboardDataItem(
          plainText: 'hello',
          html: '<b>hello</b>',
        ),
      ],
      options: const ClipboardWriteOptions(
        buffer: ClipboardBuffer.macOsFind,
        isSensitive: true,
        localOnly: true,
      ),
    );
    expect(ok, isTrue);
    expect(lastMethodCall?.method, 'writeItems');
    final args = lastMethodCall?.arguments as Map<Object?, Object?>;
    final options = args['options'] as Map<Object?, Object?>;
    expect(options['buffer'], 'macOsFind');
    expect(options['isSensitive'], isTrue);
    expect(options['localOnly'], isTrue);
  });

  test('readItems and getMetadata deserialize properly', () async {
    final items = await platform.readItems();
    expect(items.length, 1);
    expect(items.first.plainText, 'channel text');
    expect(items.first.html, '<p>channel text</p>');
    expect(items.first.fileCopyMode, FileCopyMode.cut);
    expect(items.first.colorValue, 0xFFAABBCC);

    final meta = await platform.getMetadata(detectPatterns: true);
    expect(meta.changeCount, 7);
    expect(meta.hasPlainText, isTrue);
    expect(meta.hasImage, isTrue);
    expect(
      meta.detectedPatterns.contains(ClipboardDetectedPattern.probableWebUrl),
      isTrue,
    );
  });

  test('EventChannel does not listen until subscribed and cancels when unsubscribed', () async {
    // Accessing the stream property alone does not start native listening
    final stream = platform.onClipboardChanged;
    expect(nativeEventStreamListening, isFalse);

    // Subscribing triggers EventChannel 'listen' on native side
    final sub = stream.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(nativeEventStreamListening, isTrue);

    // Cancelling triggers EventChannel 'cancel' on native side
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEventStreamListening, isFalse);
  });
}
