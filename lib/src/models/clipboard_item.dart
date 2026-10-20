import 'dart:convert';
import 'dart:typed_data';

import 'file_copy_mode.dart';

/// 单个剪切板条目（可同时包含同一份数据的多种格式表示）
class ClipboardDataItem {
  /// 纯文本内容
  final String? plainText;

  /// HTML 富文本内容
  final String? html;

  /// RTF 富文本字节数据
  final Uint8List? rtfBytes;

  /// Markdown 文本内容
  final String? markdown;

  /// URL / URI 链接
  final Uri? uri;

  /// 图片二进制数据（写入时自动适配平台标准格式，读取时默认无损转换为 PNG）
  final Uint8List? imageBytes;

  /// 图片格式提示（默认 'image/png'）
  final String? imageMimeType;

  /// 本地文件/文件夹绝对路径或 URI 列表
  final List<String>? files;

  /// 文件操作模式（复制或剪切，默认 FileCopyMode.copy）
  final FileCopyMode fileCopyMode;

  /// ARGB 32位颜色值（对应 Flutter Color.toARGB32() / value）
  final int? colorValue;

  /// 自定义格式字典：Key 为 MIME 类型、UTI 或平台注册格式名，Value 为原始字节数据
  final Map<String, Uint8List> customFormats;

  const ClipboardDataItem({
    this.plainText,
    this.html,
    this.rtfBytes,
    this.markdown,
    this.uri,
    this.imageBytes,
    this.imageMimeType = 'image/png',
    this.files,
    this.fileCopyMode = FileCopyMode.copy,
    this.colorValue,
    this.customFormats = const {},
  });

  /// 获取 RTF 的 UTF-8 字符串形式（若存在）
  String? get rtfString =>
      rtfBytes != null ? utf8.decode(rtfBytes!, allowMalformed: true) : null;

  /// 判断条目是否为空
  bool get isEmpty =>
      plainText == null &&
      html == null &&
      rtfBytes == null &&
      markdown == null &&
      uri == null &&
      imageBytes == null &&
      (files == null || files!.isEmpty) &&
      colorValue == null &&
      customFormats.isEmpty;

  /// 转换为平台通道传输 Map
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{'fileCopyMode': fileCopyMode.wireName};
    if (plainText != null) {
      map['plainText'] = plainText;
    }
    if (html != null) {
      map['html'] = html;
    }
    if (rtfBytes != null) {
      map['rtfBytes'] = rtfBytes;
    }
    if (markdown != null) {
      map['markdown'] = markdown;
    }
    if (uri != null) {
      map['uri'] = uri.toString();
    }
    if (imageBytes != null) {
      map['imageBytes'] = imageBytes;
    }
    if (imageMimeType != null) {
      map['imageMimeType'] = imageMimeType;
    }
    if (files != null && files!.isNotEmpty) {
      map['files'] = files;
    }
    if (colorValue != null) {
      map['colorValue'] = colorValue;
    }
    if (customFormats.isNotEmpty) {
      map['customFormats'] = customFormats;
    }
    return map;
  }

  /// 从平台通道返回的 Map 解析
  factory ClipboardDataItem.fromMap(Map<Object?, Object?> map) {
    final rawFiles = map['files'];
    final List<String>? filesList = rawFiles is List
        ? rawFiles.whereType<String>().toList()
        : null;

    final rawCustom = map['customFormats'];
    final Map<String, Uint8List> parsedCustom = <String, Uint8List>{};
    if (rawCustom is Map) {
      for (final entry in rawCustom.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is Uint8List) {
          parsedCustom[key] = value;
        } else if (key is String && value is List<int>) {
          parsedCustom[key] = Uint8List.fromList(value);
        }
      }
    }

    Uint8List? toUint8List(Object? raw) {
      if (raw is Uint8List) {
        return raw;
      }
      if (raw is List<int>) {
        return Uint8List.fromList(raw);
      }
      return null;
    }

    final uriStr = map['uri'] as String?;
    Uri? parsedUri;
    if (uriStr != null && uriStr.isNotEmpty) {
      parsedUri = Uri.tryParse(uriStr);
    }

    final rawColor = map['colorValue'];
    int? parsedColor;
    if (rawColor is int) {
      parsedColor = rawColor;
    }

    return ClipboardDataItem(
      plainText: map['plainText'] as String?,
      html: map['html'] as String?,
      rtfBytes: toUint8List(map['rtfBytes']),
      markdown: map['markdown'] as String?,
      uri: parsedUri,
      imageBytes: toUint8List(map['imageBytes']),
      imageMimeType: (map['imageMimeType'] as String?) ?? 'image/png',
      files: filesList,
      fileCopyMode: FileCopyMode.fromWireName(map['fileCopyMode'] as String?),
      colorValue: parsedColor,
      customFormats: parsedCustom,
    );
  }

  ClipboardDataItem copyWith({
    String? plainText,
    String? html,
    Uint8List? rtfBytes,
    String? markdown,
    Uri? uri,
    Uint8List? imageBytes,
    String? imageMimeType,
    List<String>? files,
    FileCopyMode? fileCopyMode,
    int? colorValue,
    Map<String, Uint8List>? customFormats,
  }) {
    return ClipboardDataItem(
      plainText: plainText ?? this.plainText,
      html: html ?? this.html,
      rtfBytes: rtfBytes ?? this.rtfBytes,
      markdown: markdown ?? this.markdown,
      uri: uri ?? this.uri,
      imageBytes: imageBytes ?? this.imageBytes,
      imageMimeType: imageMimeType ?? this.imageMimeType,
      files: files ?? this.files,
      fileCopyMode: fileCopyMode ?? this.fileCopyMode,
      colorValue: colorValue ?? this.colorValue,
      customFormats: customFormats ?? this.customFormats,
    );
  }
}
