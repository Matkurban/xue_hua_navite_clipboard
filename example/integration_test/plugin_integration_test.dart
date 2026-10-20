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
}
