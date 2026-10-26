import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('writeText and readText integration test', (
    WidgetTester tester,
  ) async {
    final XueHuaNaviteClipboard plugin = XueHuaNaviteClipboard.instance;
    const sample = 'integration_test_clipboard_payload';
    final bool wrote = await plugin.writeText(sample);
    expect(wrote, isTrue);

    final String? readBack = await plugin.readText();
    expect(readBack, sample);
  });

  testWidgets('clear / html / image / metadata roundtrip', (
    WidgetTester tester,
  ) async {
    final plugin = XueHuaNaviteClipboard.instance;
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
}
