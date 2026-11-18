import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    appDirectory: 'example/',
    configDirectory: '.',
    dartOut: 'lib/src/pigeon/clipboard_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/kurban/xue_hua_navite_clipboard/ClipboardApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.kurban.xue_hua_navite_clipboard',
      useJni: true,
    ),
    swiftOut: <String>[
      'ios/xue_hua_navite_clipboard/Sources/xue_hua_navite_clipboard/ClipboardApi.g.swift',
      'macos/xue_hua_navite_clipboard/Sources/xue_hua_navite_clipboard/ClipboardApi.g.swift',
    ],
    swiftOptions: SwiftOptions(
      useFfi: true,
      ffiModuleName: 'xue_hua_navite_clipboard',
    ),
    cppHeaderOut: 'windows/clipboard_api.g.h',
    cppSourceOut: 'windows/clipboard_api.g.cpp',
    cppOptions: CppOptions(namespace: 'xue_hua_navite_clipboard'),
    gobjectHeaderOut: 'linux/clipboard_api.g.h',
    gobjectSourceOut: 'linux/clipboard_api.g.cc',
    gobjectOptions: GObjectOptions(module: 'Clipboard'),
  ),
)
enum WireClipboardBuffer {
  general,
  primarySelection,
  macOsFind,
  macOsDrag,
  macOsFont,
  macOsRuler,
  named,
}

enum WireFileCopyMode { copy, cut }

enum WireClipboardDetectedPattern {
  probableWebUrl,
  probableWebSearch,
  number,
  emailAddress,
  phoneNumber,
  postalAddress,
  flightNumber,
  shipmentTrackingNumber,
  moneyAmount,
}

class WireClipboardBufferTarget {
  WireClipboardBufferTarget({
    this.buffer = WireClipboardBuffer.general,
    this.customBufferName,
  });

  WireClipboardBuffer buffer;
  String? customBufferName;
}

class WireCustomFormatEntry {
  WireCustomFormatEntry({required this.format, required this.data});

  String format;
  Uint8List data;
}

class WireClipboardItem {
  WireClipboardItem({
    this.plainText,
    this.html,
    this.rtfBytes,
    this.markdown,
    this.uri,
    this.imageBytes,
    this.imageMimeType = 'image/png',
    this.files,
    this.fileCopyMode = WireFileCopyMode.copy,
    this.colorValue,
    this.customFormats,
  });

  String? plainText;
  String? html;
  Uint8List? rtfBytes;
  String? markdown;
  String? uri;
  Uint8List? imageBytes;
  String? imageMimeType;
  List<String>? files;
  WireFileCopyMode fileCopyMode;
  int? colorValue;
  List<WireCustomFormatEntry>? customFormats;
}

class WireClipboardWriteOptions {
  WireClipboardWriteOptions({
    this.buffer = WireClipboardBuffer.general,
    this.customBufferName,
    this.isSensitive = false,
    this.isTransient = false,
    this.localOnly = false,
    this.expirationMs,
    this.label,
  });

  WireClipboardBuffer buffer;
  String? customBufferName;
  bool isSensitive;
  bool isTransient;
  bool localOnly;
  int? expirationMs;
  String? label;
}

class WireClipboardReadOptions {
  WireClipboardReadOptions({
    this.buffer = WireClipboardBuffer.general,
    this.customBufferName,
    this.preferredImageFormat = 'image/png',
    this.requestedCustomFormats = const <String>[],
    this.targetFormat,
  });

  WireClipboardBuffer buffer;
  String? customBufferName;
  String preferredImageFormat;
  List<String> requestedCustomFormats;
  String? targetFormat;
}

class WireClipboardMetadata {
  WireClipboardMetadata({
    required this.changeCount,
    this.timestampMs,
    required this.itemCount,
    required this.hasPlainText,
    required this.hasHtml,
    required this.hasRtf,
    required this.hasMarkdown,
    required this.hasUri,
    required this.hasImage,
    required this.hasFiles,
    required this.hasColor,
    required this.rawPlatformFormats,
    required this.detectedPatterns,
  });

  int changeCount;
  int? timestampMs;
  int itemCount;
  bool hasPlainText;
  bool hasHtml;
  bool hasRtf;
  bool hasMarkdown;
  bool hasUri;
  bool hasImage;
  bool hasFiles;
  bool hasColor;
  List<String> rawPlatformFormats;
  List<WireClipboardDetectedPattern> detectedPatterns;
}

class WireClipboardChangeEvent {
  WireClipboardChangeEvent({
    required this.buffer,
    required this.changeCount,
    required this.timestampMs,
  });

  WireClipboardBuffer buffer;
  int changeCount;
  int timestampMs;
}

@HostApi()
abstract class ClipboardHostApi {
  bool writeItems(
    List<WireClipboardItem> items,
    WireClipboardWriteOptions options,
  );

  List<WireClipboardItem> readItems(WireClipboardReadOptions options);

  @async
  WireClipboardMetadata getMetadata(
    WireClipboardBufferTarget target,
    bool detectPatterns,
  );

  int getChangeCount(WireClipboardBufferTarget target);

  bool clear(WireClipboardBufferTarget target);

  void setPollingInterval(int intervalMs);

  void startClipboardListening();

  void stopClipboardListening();
}

@FlutterApi()
abstract class ClipboardFlutterApi {
  void onClipboardChanged(WireClipboardChangeEvent event);
}
