import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';
import 'package:xue_hua_navite_clipboard_example/main.dart' as app;

/// UI-driven coverage of the example app.
///
/// Flutter currently recommends [integration_test] over the legacy
/// `flutter_driver` package; this suite uses the same WidgetTester-driven
/// approach to tap example buttons and assert clipboard/UI state.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final clipboard = XueHuaNaviteClipboard.instance;

  Future<void> pumpSettle(WidgetTester tester, [Duration d = const Duration(milliseconds: 400)]) async {
    await tester.pumpAndSettle(d);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await pumpSettle(tester, const Duration(milliseconds: 200));
    await tester.tap(finder);
    await pumpSettle(tester);
  }

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 8),
    String label = 'condition',
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (predicate()) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('Timed out waiting for $label');
  }

  testWidgets('example UI: clear / text / chinese / html / rtf / png / color / custom / files / monitor', (
    WidgetTester tester,
  ) async {
    app.main();
    await pumpSettle(tester, const Duration(seconds: 1));

    expect(find.text('Native Clipboard Inspector'), findsOneWidget);
    expect(find.byKey(const Key('status_log')), findsOneWidget);

    // --- Clear ---
    await tapKey(tester, 'btn_clear');
    await waitUntil(
      tester,
      () {
        final text = tester.widget<Text>(find.byKey(const Key('status_log'))).data ?? '';
        return text.contains('Clipboard cleared');
      },
      label: 'clear status',
    );
    final afterClear = await clipboard.readText();
    expect(afterClear == null || afterClear.isEmpty, isTrue);

    // --- Plain text ---
    await tapKey(tester, 'btn_write_text');
    await waitUntil(
      tester,
      () => find.byKey(const Key('preview_plain')).evaluate().isNotEmpty,
      label: 'plain preview',
    );
    final plain = await clipboard.readText();
    expect(plain, isNotNull);
    expect(plain!, contains('Hello from XueHuaNaviteClipboard'));
    expect(find.textContaining('Hello from XueHuaNaviteClipboard'), findsWidgets);

    // --- Chinese text ---
    await tapKey(tester, 'btn_write_chinese');
    await waitUntil(
      tester,
      () {
        final texts = find.byKey(const Key('preview_plain')).evaluate();
        if (texts.isEmpty) return false;
        final data = tester.widget<Text>(find.byKey(const Key('preview_plain'))).data ?? '';
        return data.contains('雪花');
      },
      label: 'chinese preview',
    );
    final zh = await clipboard.readText();
    expect(zh, '雪花剪贴板测试 Hello 中文 🎉');

    // --- Sensitive secret (still readable as text) ---
    await tapKey(tester, 'btn_write_sensitive');
    await waitUntil(
      tester,
      () {
        final texts = find.byKey(const Key('preview_plain')).evaluate();
        if (texts.isEmpty) return false;
        final data = tester.widget<Text>(find.byKey(const Key('preview_plain'))).data ?? '';
        return data.contains('SecretToken_');
      },
      label: 'sensitive preview',
    );
    final secret = await clipboard.readText();
    expect(secret, isNotNull);
    expect(secret!, startsWith('SecretToken_'));

    // --- HTML ---
    await tapKey(tester, 'btn_write_html');
    await waitUntil(
      tester,
      () => find.byKey(const Key('preview_html')).evaluate().isNotEmpty,
      label: 'html preview',
    );
    final html = await clipboard.readHtml();
    expect(html, isNotNull);
    expect(html!, contains('Rich HTML Title'));
    final htmlMeta = await clipboard.getMetadata();
    expect(htmlMeta.hasHtml || htmlMeta.hasPlainText, isTrue);

    // --- RTF ---
    await tapKey(tester, 'btn_write_rtf');
    await waitUntil(
      tester,
      () {
        final hasRtf = find.byKey(const Key('preview_rtf')).evaluate().isNotEmpty;
        final hasPlain = find.byKey(const Key('preview_plain')).evaluate().isNotEmpty;
        return hasRtf || hasPlain;
      },
      label: 'rtf preview',
    );
    final rtfBytes = await clipboard.readRtf();
    final rtfPlain = await clipboard.readText();
    expect(rtfBytes != null || (rtfPlain != null && rtfPlain.contains('RTF')), isTrue);

    // --- Generated PNG ---
    await tapKey(tester, 'btn_write_png');
    await waitUntil(
      tester,
      () => find.byKey(const Key('preview_image')).evaluate().isNotEmpty,
      label: 'png preview',
    );
    final png = await clipboard.readImage();
    expect(png, isNotNull);
    expect(png!.length, greaterThan(32));
    expect(png[0], 0x89);
    expect(png[1], 0x50); // P
    final imgMeta = await clipboard.getMetadata();
    expect(imgMeta.hasImage, isTrue);

    // --- Color ---
    await tapKey(tester, 'btn_write_color');
    await waitUntil(
      tester,
      () {
        final hasColor = find.byKey(const Key('preview_color')).evaluate().isNotEmpty;
        final hasPlain = find.byKey(const Key('preview_plain')).evaluate().isNotEmpty;
        return hasColor || hasPlain;
      },
      label: 'color preview',
    );
    final color = await clipboard.readColor();
    final colorText = await clipboard.readText();
    expect(
      color == 0xFF673AB7 || (colorText != null && colorText.toUpperCase().contains('673AB7')),
      isTrue,
      reason: 'color=$color text=$colorText',
    );

    // --- Custom binary ---
    await tapKey(tester, 'btn_write_custom');
    await waitUntil(
      tester,
      () {
        final hasCustom = find.byKey(const Key('preview_custom')).evaluate().isNotEmpty;
        final hasPlain = find.byKey(const Key('preview_plain')).evaluate().isNotEmpty;
        return hasCustom || hasPlain;
      },
      label: 'custom preview',
    );
    final custom = await clipboard.readCustomData('application/x-xuehua-custom');
    expect(custom, isNotNull);
    expect(utf8.decode(custom!), contains('customPayload'));

    // --- Files ---
    await tapKey(tester, 'btn_write_files');
    await waitUntil(
      tester,
      () => find.byKey(const Key('preview_files')).evaluate().isNotEmpty,
      label: 'files preview',
    );
    final files = await clipboard.readFiles();
    expect(files.length, greaterThanOrEqualTo(2));
    final joined = files.join('|');
    expect(joined.contains('demo_a.txt'), isTrue);
    expect(joined.contains('demo_b.txt'), isTrue);

    // --- Refresh metadata button ---
    await tapKey(tester, 'btn_refresh');
    expect(find.byKey(const Key('card_metadata')), findsOneWidget);
    expect(find.byKey(const Key('metadata_flags')), findsOneWidget);

    // --- Listener toggle ---
    await tapKey(tester, 'switch_monitor');
    await waitUntil(
      tester,
      () {
        final text = tester.widget<Text>(find.byKey(const Key('status_log'))).data ?? '';
        return text.contains('listener enabled');
      },
      label: 'listener enabled',
    );

    final completer = Completer<ClipboardChangeEvent>();
    late StreamSubscription<ClipboardChangeEvent> sub;
    sub = clipboard.onClipboardChanged.listen((e) {
      if (!completer.isCompleted) {
        completer.complete(e);
      }
    });
    await tapKey(tester, 'btn_write_chinese');
    final event = await completer.future.timeout(const Duration(seconds: 8));
    await sub.cancel();
    expect(event.changeCount, greaterThanOrEqualTo(0));

    await waitUntil(
      tester,
      () {
        final text = tester.widget<Text>(find.byKey(const Key('status_log'))).data ?? '';
        return text.contains('Event #') || text.contains('Wrote Chinese');
      },
      label: 'listener event status',
    );

    // Turn listener off
    await tapKey(tester, 'switch_monitor');
    await waitUntil(
      tester,
      () {
        final text = tester.widget<Text>(find.byKey(const Key('status_log'))).data ?? '';
        return text.contains('listener stopped');
      },
      label: 'listener stopped',
    );

    // Final clear
    await tapKey(tester, 'btn_clear');
    await waitUntil(
      tester,
      () {
        final text = tester.widget<Text>(find.byKey(const Key('status_log'))).data ?? '';
        return text.contains('Clipboard cleared');
      },
      label: 'final clear',
    );
  });

  testWidgets('API parity smoke alongside UI app', (WidgetTester tester) async {
    app.main();
    await pumpSettle(tester, const Duration(seconds: 1));

    final sample = 'api_parity_雪花_${DateTime.now().millisecondsSinceEpoch}';
    expect(await clipboard.writeText(sample), isTrue);
    expect(await clipboard.readText(), sample);

    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    expect(await clipboard.writeImage(Uint8List.fromList(png)), isTrue);
    final readPng = await clipboard.readImage();
    expect(readPng, isNotNull);
    expect(readPng!.first, 0x89);

    final tmp = await Directory.systemTemp.createTemp('xh_clip_api_');
    final f = File('${tmp.path}/one.txt')..writeAsStringSync('one');
    expect(await clipboard.writeFiles(<String>[f.path]), isTrue);
    final files = await clipboard.readFiles();
    expect(files.any((p) => p.contains('one.txt')), isTrue);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}

    expect(await clipboard.clear(), isTrue);
  });
}
