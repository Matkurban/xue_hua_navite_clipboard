import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final plugin = XueHuaNaviteClipboard.instance;

  // 1x1 PNG
  final Uint8List tinyPng = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    ),
  );

  testWidgets('writeText and readText integration test', (
    WidgetTester tester,
  ) async {
    const sample = 'integration_test_clipboard_payload';
    final bool wrote = await plugin.writeText(sample);
    expect(wrote, isTrue);

    final String? readBack = await plugin.readText();
    expect(readBack, sample);
  });

  testWidgets('clear / html / image / metadata roundtrip', (
    WidgetTester tester,
  ) async {
    expect(await plugin.clear(), isTrue);

    expect(
      await plugin.writeHtml(
        '<b>bold</b>',
        plainTextFallback: 'bold',
      ),
      isTrue,
    );
    final html = await plugin.readHtml();
    expect(html, isNotNull);
    expect(html!, contains('bold'));

    final meta = await plugin.getMetadata();
    expect(meta.hasPlainText || meta.hasHtml, isTrue);
    expect(await plugin.clear(), isTrue);
  });

  testWidgets('hasFormat / getChangeCount / setPollingInterval', (
    WidgetTester tester,
  ) async {
    expect(await plugin.clear(), isTrue);
    final before = await plugin.getChangeCount();
    expect(before, isA<int>());

    await plugin.setPollingInterval(const Duration(milliseconds: 250));

    expect(await plugin.writeText('has_format_probe'), isTrue);
    final after = await plugin.getChangeCount();
    expect(after, greaterThanOrEqualTo(before));

    expect(
      await plugin.hasFormat(StandardClipboardFormat.plainText.mimeType),
      isTrue,
    );
    final hasHtml = await plugin.hasFormat(
      StandardClipboardFormat.html.mimeType,
    );
    expect(hasHtml, isA<bool>());

    expect(await plugin.clear(), isTrue);
  });

  testWidgets('markdown / uri / color / custom / rtf bytes / writeItems', (
    WidgetTester tester,
  ) async {
    expect(await plugin.clear(), isTrue);

    const md = '# XueHua\n**bold**';
    expect(await plugin.writeMarkdown(md), isTrue);
    final readMd = await plugin.readMarkdown();
    expect(readMd, isNotNull);
    expect(readMd!.contains('XueHua') || readMd.contains('bold'), isTrue);

    final uri = Uri.parse('https://example.com/xuehua-clipboard');
    expect(await plugin.writeUri(uri), isTrue);
    final readUriVal = await plugin.readUri();
    final uriText = await plugin.readText();
    expect(
      (readUriVal != null && readUriVal.toString().contains('example.com')) ||
          (uriText != null && uriText.contains('example.com')),
      isTrue,
    );

    expect(await plugin.writeColor(0xFF2196F3), isTrue);
    final color = await plugin.readColor();
    final colorText = await plugin.readText();
    expect(
      color == 0xFF2196F3 ||
          (colorText != null && colorText.toUpperCase().contains('2196F3')),
      isTrue,
    );

    final customBytes = Uint8List.fromList(utf8.encode('{"k":1}'));
    expect(
      await plugin.writeCustomData(
        'application/x-xuehua-custom',
        customBytes,
        plainTextFallback: 'custom-fallback',
      ),
      isTrue,
    );
    final custom = await plugin.readCustomData('application/x-xuehua-custom');
    expect(custom, isNotNull);
    expect(utf8.decode(custom!), contains('"k":1'));

    final rtf = Uint8List.fromList(
      utf8.encode(r'{\rtf1\ansi\b RTF bytes\b0}'),
    );
    expect(
      await plugin.writeRtf(rtf, plainTextFallback: 'RTF bytes'),
      isTrue,
    );
    final rtfBack = await plugin.readRtf();
    final rtfPlain = await plugin.readText();
    expect(
      rtfBack != null || (rtfPlain != null && rtfPlain.contains('RTF')),
      isTrue,
    );

    expect(
      await plugin.writeItems(<ClipboardDataItem>[
        ClipboardDataItem(plainText: 'item-a'),
        ClipboardDataItem(plainText: 'item-b'),
      ]),
      isTrue,
    );
    final items = await plugin.readItems();
    expect(items, isNotEmpty);
    expect(items.first.plainText, isNotNull);

    expect(await plugin.writeImage(tinyPng), isTrue);
    final img = await plugin.readImage();
    expect(img, isNotNull);
    expect(img!.first, 0x89);

    expect(XueHuaNaviteClipboard.stripHtmlTags('<p>Hi&nbsp;<b>X</b></p>'), 'Hi X');

    expect(await plugin.clear(), isTrue);
  });

  testWidgets('files write/read + readFileCopyMode + change stream', (
    WidgetTester tester,
  ) async {
    expect(await plugin.clear(), isTrue);

    final tmp = await Directory.systemTemp.createTemp('xh_clip_it_');
    final a = File('${tmp.path}/demo_a.txt')..writeAsStringSync('a');
    final b = File('${tmp.path}/demo_b.txt')..writeAsStringSync('b');

    expect(
      await plugin.writeFiles(
        <String>[a.path, b.path],
        mode: FileCopyMode.copy,
      ),
      isTrue,
    );
    final files = await plugin.readFiles();
    expect(files.length, greaterThanOrEqualTo(1));
    final joined = files.join('|');
    expect(
      joined.contains('demo_a.txt') || joined.contains('demo_b.txt'),
      isTrue,
    );

    final mode = await plugin.readFileCopyMode();
    // iOS may not expose Preferred DropEffect; null is acceptable.
    expect(mode == null || mode == FileCopyMode.copy, isTrue);

    final completer = Completer<ClipboardChangeEvent>();
    late StreamSubscription<ClipboardChangeEvent> sub;
    sub = plugin.onClipboardChanged.listen((e) {
      if (!completer.isCompleted) {
        completer.complete(e);
      }
    });
    expect(await plugin.writeText('stream_probe_${DateTime.now().millisecondsSinceEpoch}'), isTrue);
    final event = await completer.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    expect(event.changeCount, greaterThanOrEqualTo(0));

    expect(await plugin.writeSensitiveText('Secret_IT', expiration: const Duration(seconds: 30)), isTrue);
    final secret = await plugin.readText();
    expect(secret, 'Secret_IT');

    expect(await plugin.clear(), isTrue);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
}
