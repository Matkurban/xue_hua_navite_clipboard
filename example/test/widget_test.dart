import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xue_hua_navite_clipboard_example/main.dart';

void main() {
  testWidgets('Verify Native Clipboard Example UI renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Text && widget.data!.startsWith('Native Clipboard'),
      ),
      findsOneWidget,
    );
  });
}
