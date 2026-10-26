import 'dart:io';

Future<List<String>> createDemoClipboardFiles() async {
  final tmp = await Directory.systemTemp.createTemp('xh_clip_ui_');
  final f1 = File('${tmp.path}/demo_a.txt')..writeAsStringSync('demo-a');
  final f2 = File('${tmp.path}/demo_b.txt')..writeAsStringSync('demo-b');
  return <String>[f1.path, f2.path];
}
