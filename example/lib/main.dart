import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xue_hua_navite_clipboard/xue_hua_navite_clipboard.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final XueHuaNaviteClipboard _clipboard = XueHuaNaviteClipboard.instance;

  String _platformVersion = 'Unknown';
  ClipboardBuffer _selectedBuffer = ClipboardBuffer.general;
  ClipboardMetadata? _metadata;
  ClipboardDataItem? _currentItem;
  String _statusLog = 'Ready';

  StreamSubscription<ClipboardChangeEvent>? _clipboardSub;
  int _receivedEventsCount = 0;

  @override
  void initState() {
    super.initState();
    _initPlatformState();
  }

  @override
  void dispose() {
    _clipboardSub?.cancel();
    super.dispose();
  }

  Future<void> _initPlatformState() async {
    String platformVersion;
    try {
      platformVersion =
          await _clipboard.getPlatformVersion() ?? 'Unknown platform version';
    } on Exception catch (e) {
      platformVersion = 'Failed to get platform version: $e';
    }

    if (!mounted) return;
    setState(() {
      _platformVersion = platformVersion;
    });
    await _refreshClipboardInspection();
  }

  void _toggleMonitoring(bool enable) {
    setState(() {
      if (enable) {
        _clipboardSub ??= _clipboard.onClipboardChanged.listen((event) {
          if (!mounted) return;
          setState(() {
            _receivedEventsCount++;
            _statusLog =
                'Event #$_receivedEventsCount: buffer=${event.buffer.wireName}, changeCount=${event.changeCount}';
          });
          _refreshClipboardInspection();
        });
        _statusLog = 'Native clipboard listener enabled';
      } else {
        _clipboardSub?.cancel();
        _clipboardSub = null;
        _statusLog = 'Native clipboard listener stopped (zero idle overhead)';
      }
    });
  }

  Future<void> _refreshClipboardInspection() async {
    try {
      final meta = await _clipboard.getMetadata(
        buffer: _selectedBuffer,
        detectPatterns: true,
      );
      final item = await _clipboard.readItem(
        options: ClipboardReadOptions(
          buffer: _selectedBuffer,
          requestedCustomFormats: const <String>['application/x-xuehua-custom'],
        ),
      );
      if (!mounted) return;
      setState(() {
        _metadata = meta;
        _currentItem = item;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusLog = 'Inspection error: $e';
      });
    }
  }

  Future<Uint8List> _generateSamplePng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(240, 100);
    final paint = Paint()..color = const Color(0xFF1E88E5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      paint,
    );
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'XueHua PNG Clip',
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, const Offset(30, 36));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final isMonitoring = _clipboardSub != null;
    return MaterialApp(
      title: 'XueHua Native Clipboard Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text('Native Clipboard ($_platformVersion)'),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh Metadata & Read',
              onPressed: _refreshClipboardInspection,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear Clipboard',
              onPressed: () async {
                await _clipboard.clear(buffer: _selectedBuffer);
                setState(() => _statusLog = 'Clipboard cleared');
                await _refreshClipboardInspection();
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        const Text(
                          'On-Demand Change Listener (onClipboardChanged)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Switch(
                          value: isMonitoring,
                          onChanged: _toggleMonitoring,
                        ),
                      ],
                    ),
                    Text('Status: $_statusLog'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<ClipboardBuffer>(
                      initialValue: _selectedBuffer,
                      decoration: const InputDecoration(
                        labelText: 'Target Clipboard Buffer',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: ClipboardBuffer.values
                          .map(
                            (b) => DropdownMenuItem<ClipboardBuffer>(
                              value: b,
                              child: Text(b.wireName),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedBuffer = val);
                          _refreshClipboardInspection();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () async {
                    await _clipboard.writeText(
                      'Hello from XueHuaNaviteClipboard @ ${DateTime.now().toIso8601String()}',
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write Plain Text'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    await _clipboard.writeSensitiveText(
                      'SecretToken_${DateTime.now().millisecondsSinceEpoch}',
                      expiration: const Duration(seconds: 30),
                      buffer: _selectedBuffer,
                    );
                    setState(() {
                      _statusLog =
                          'Wrote sensitive text (concealed/no-history, expires in 30s)';
                    });
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write Sensitive Secret'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    await _clipboard.writeHtml(
                      '<h3 style="color:#1E88E5;">Rich HTML Title</h3><p>With <b>bold</b> and <i>italic</i> content.</p>',
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write HTML + Fallback'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    await _clipboard.writeRtfString(
                      r'{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\pard \b Rich Text Format (RTF)\b0\par}',
                      plainTextFallback: 'Rich Text Format (RTF)',
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write RTF'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    final pngBytes = await _generateSamplePng();
                    await _clipboard.writeImage(
                      pngBytes,
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write Generated PNG'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    await _clipboard.writeColor(
                      0xFF673AB7,
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write Color (#FF673AB7)'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    final data = Uint8List.fromList(
                      utf8.encode('{"customPayload":42}'),
                    );
                    await _clipboard.writeCustomData(
                      'application/x-xuehua-custom',
                      data,
                      plainTextFallback: 'Custom Payload Fallback',
                      options: ClipboardWriteOptions(buffer: _selectedBuffer),
                    );
                    await _refreshClipboardInspection();
                  },
                  child: const Text('Write Custom Binary'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_metadata != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Metadata (changeCount: ${_metadata!.changeCount}, items: ${_metadata!.itemCount})',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Flags: text=${_metadata!.hasPlainText}, html=${_metadata!.hasHtml}, '
                        'rtf=${_metadata!.hasRtf}, md=${_metadata!.hasMarkdown}, '
                        'uri=${_metadata!.hasUri}, image=${_metadata!.hasImage}, '
                        'files=${_metadata!.hasFiles}, color=${_metadata!.hasColor}',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Raw Formats: ${_metadata!.rawPlatformFormats.join(', ')}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_currentItem != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Current Clipboard Item Snapshot',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      if (_currentItem!.plainText != null)
                        Text('PlainText: ${_currentItem!.plainText}'),
                      if (_currentItem!.html != null)
                        Text('HTML: ${_currentItem!.html}'),
                      if (_currentItem!.rtfString != null)
                        Text('RTF: ${_currentItem!.rtfString}'),
                      if (_currentItem!.uri != null)
                        Text('URI: ${_currentItem!.uri}'),
                      if (_currentItem!.files != null &&
                          _currentItem!.files!.isNotEmpty)
                        Text(
                          'Files (${_currentItem!.fileCopyMode.wireName}): ${_currentItem!.files!.join(', ')}',
                        ),
                      if (_currentItem!.colorValue != null)
                        Row(
                          children: <Widget>[
                            const Text('Color: '),
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: Color(_currentItem!.colorValue!),
                                border: Border.all(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '#${_currentItem!.colorValue!.toRadixString(16).toUpperCase()}',
                            ),
                          ],
                        ),
                      if (_currentItem!.customFormats.isNotEmpty)
                        Text(
                          'Custom Formats: ${_currentItem!.customFormats.entries.map((e) => '${e.key} (${e.value.length} bytes)').join(', ')}',
                        ),
                      if (_currentItem!.imageBytes != null) ...<Widget>[
                        const SizedBox(height: 8),
                        const Text('Image Preview (PNG):'),
                        const SizedBox(height: 4),
                        Image.memory(
                          _currentItem!.imageBytes!,
                          height: 100,
                          fit: BoxFit.contain,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
