import Flutter
import UIKit
import UniformTypeIdentifiers

public class XueHuaNaviteClipboardPlugin: NSObject, FlutterPlugin, ClipboardHostApi {
  private var registrar: FlutterPluginRegistrar?
  private var pasteboardChangedObserver: NSObjectProtocol?
  private var appActiveObserver: NSObjectProtocol?
  private var lastObservedChangeCount: Int = UIPasteboard.general.changeCount

  private static let utiPlainText = "public.utf8-plain-text"
  private static let utiHtml = "public.html"
  private static let utiRtf = "public.rtf"
  private static let utiMarkdown = "net.daringfireball.markdown"
  private static let utiUrl = "public.url"
  private static let utiPng = "public.png"
  private static let utiJpeg = "public.jpeg"
  private static let utiFileUrl = "public.file-url"
  private static let utiConcealed = "org.nspasteboard.ConcealedType"
  private static let utiTransient = "org.nspasteboard.TransientType"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = XueHuaNaviteClipboardPlugin()
    instance.registrar = registrar
    registrar.publish(instance)
    ClipboardHostApiSetup.register(api: instance, registrar: registrar)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    try? stopClipboardListening()
    ClipboardHostApiSetup.unregister(api: self, registrar: registrar)
    self.registrar = nil
  }

  deinit {
    stopListeningInternal()
  }

  // MARK: - Listening

  func startClipboardListening() throws {
    guard pasteboardChangedObserver == nil else { return }
    lastObservedChangeCount = UIPasteboard.general.changeCount

    pasteboardChangedObserver = NotificationCenter.default.addObserver(
      forName: UIPasteboard.changedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitIfChanged()
    }

    appActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitIfChanged()
    }
  }

  func stopClipboardListening() throws {
    stopListeningInternal()
  }

  private func stopListeningInternal() {
    if let obs = pasteboardChangedObserver {
      NotificationCenter.default.removeObserver(obs)
      pasteboardChangedObserver = nil
    }
    if let obs = appActiveObserver {
      NotificationCenter.default.removeObserver(obs)
      appActiveObserver = nil
    }
  }

  private func emitIfChanged() {
    let current = UIPasteboard.general.changeCount
    if current != lastObservedChangeCount {
      lastObservedChangeCount = current
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
      guard let registrar = self.registrar,
            let flutterApi = ClipboardFlutterApiRegistrar.getInstance(registrar: registrar) else {
        return
      }
      try? flutterApi.onClipboardChanged(
        event: WireClipboardChangeEvent(
          buffer: .general,
          changeCount: Int64(current),
          timestampMs: nowMs
        )
      )
    }
  }

  // MARK: - Pasteboard Resolution

  private func resolvePasteboard(buffer: WireClipboardBuffer, customName: String?) -> UIPasteboard {
    if buffer == .named, let name = customName, !name.isEmpty {
      return UIPasteboard(name: UIPasteboard.Name(name), create: true) ?? .general
    }
    return .general
  }

  // MARK: - ClipboardHostApi

  func writeItems(items: [WireClipboardItem], options: WireClipboardWriteOptions) throws -> Bool {
    guard !items.isEmpty else {
      return false
    }

    let pb = resolvePasteboard(buffer: options.buffer, customName: options.customBufferName)
    let isSensitive = options.isSensitive
    let isTransient = options.isTransient
    let localOnly = options.localOnly
    let expirationMs = options.expirationMs

    var pbItems: [[String: Any]] = []

    for item in items {
      var dict: [String: Any] = [:]

      if let plainText = item.plainText {
        dict[Self.utiPlainText] = plainText
      }
      if let html = item.html, let data = html.data(using: .utf8) {
        dict[Self.utiHtml] = data
      }
      if let rtfBytes = item.rtfBytes {
        dict[Self.utiRtf] = Data(rtfBytes)
      }
      if let markdown = item.markdown, let data = markdown.data(using: .utf8) {
        dict[Self.utiMarkdown] = data
        if dict[Self.utiPlainText] == nil {
          dict[Self.utiPlainText] = markdown
        }
      }
      if let uriStr = item.uri, let url = URL(string: uriStr) {
        dict[Self.utiUrl] = url
      }
      if let imageBytes = item.imageBytes {
        let rawData = Data(imageBytes)
        if let image = UIImage(data: rawData), let pngData = image.pngData() {
          dict[Self.utiPng] = pngData
        } else {
          dict[Self.utiPng] = rawData
        }
      }
      if let files = item.files, !files.isEmpty {
        for (idx, filePath) in files.enumerated() {
          let fileUrl = URL(fileURLWithPath: filePath)
          if idx == 0 {
            dict[Self.utiFileUrl] = fileUrl
          } else {
            pbItems.append([Self.utiFileUrl: fileUrl])
          }
        }
      }
      if let colorValue = item.colorValue {
        let a = CGFloat((colorValue >> 24) & 0xFF) / 255.0
        let r = CGFloat((colorValue >> 16) & 0xFF) / 255.0
        let g = CGFloat((colorValue >> 8) & 0xFF) / 255.0
        let b = CGFloat(colorValue & 0xFF) / 255.0
        dict["com.apple.uikit.color"] = UIColor(red: r, green: g, blue: b, alpha: a)
      }
      if let customFormats = item.customFormats {
        for entry in customFormats {
          dict[entry.format] = Data(entry.data)
        }
      }
      if isSensitive {
        dict[Self.utiConcealed] = Data()
      }
      if isTransient {
        dict[Self.utiTransient] = Data()
      }

      if !dict.isEmpty {
        pbItems.append(dict)
      }
    }

    var pbOptions: [UIPasteboard.OptionsKey: Any] = [:]
    if localOnly || isSensitive {
      pbOptions[.localOnly] = true
    }
    if let expMs = expirationMs, expMs > 0 {
      pbOptions[.expirationDate] = Date().addingTimeInterval(Double(expMs) / 1000.0)
    }

    pb.setItems(pbItems, options: pbOptions)

    var allFileUrls: [URL] = []
    for item in items {
      if let files = item.files {
        allFileUrls.append(contentsOf: files.map { URL(fileURLWithPath: $0) })
      }
    }
    if !allFileUrls.isEmpty {
      let onlyFiles = pbItems.allSatisfy { dict in
        Set(dict.keys.map { "\($0)" })
          .subtracting([Self.utiFileUrl, Self.utiConcealed, Self.utiTransient])
          .isEmpty
      }
      if onlyFiles {
        pb.urls = allFileUrls
      }
    }

    return true
  }

  func readItems(options: WireClipboardReadOptions) throws -> [WireClipboardItem] {
    let pb = resolvePasteboard(buffer: options.buffer, customName: options.customBufferName)
    let requestedCustom = options.requestedCustomFormats

    let rawItems = pb.items
    if rawItems.isEmpty {
      return []
    }

    func dataString(_ value: Any?) -> String? {
      if let s = value as? String { return s }
      if let d = value as? Data { return String(data: d, encoding: .utf8) }
      return nil
    }

    func extractFilePath(_ value: Any?) -> String? {
      if let url = value as? URL {
        return url.isFileURL ? url.path : url.absoluteString
      }
      if let s = value as? String {
        if s.hasPrefix("file:"), let url = URL(string: s) {
          return url.path
        }
        return s
      }
      if let d = value as? Data, let s = String(data: d, encoding: .utf8) {
        if s.hasPrefix("file:"), let url = URL(string: s) {
          return url.path
        }
        return s
      }
      return nil
    }

    var results: [WireClipboardItem] = []

    for itemDict in rawItems {
      var plainText: String?
      if let textVal = itemDict[Self.utiPlainText] as? String {
        plainText = textVal
      } else if let textData = itemDict[Self.utiPlainText] as? Data {
        plainText = String(data: textData, encoding: .utf8)
      }

      var html: String?
      if let htmlData = itemDict[Self.utiHtml] as? Data {
        html = String(data: htmlData, encoding: .utf8)
      } else if let htmlStr = itemDict[Self.utiHtml] as? String {
        html = htmlStr
      }

      var rtfBytes: [UInt8]?
      if let rtfData = itemDict[Self.utiRtf] as? Data {
        rtfBytes = [UInt8](rtfData)
      }

      var markdown: String?
      if let mdData = itemDict[Self.utiMarkdown] as? Data {
        markdown = String(data: mdData, encoding: .utf8)
      } else if let mdStr = itemDict[Self.utiMarkdown] as? String {
        markdown = mdStr
      }

      var uriStr: String?
      if let urlVal = itemDict[Self.utiUrl] as? URL {
        uriStr = urlVal.absoluteString
      } else if let urlStr = dataString(itemDict[Self.utiUrl]) {
        uriStr = urlStr
      }

      var imageBytes: [UInt8]?
      if let pngData = itemDict[Self.utiPng] as? Data {
        imageBytes = [UInt8](pngData)
      } else if let uiImg = itemDict[Self.utiPng] as? UIImage, let pngData = uiImg.pngData() {
        imageBytes = [UInt8](pngData)
      } else if let jpegData = itemDict[Self.utiJpeg] as? Data,
                let uiImg = UIImage(data: jpegData),
                let pngData = uiImg.pngData() {
        imageBytes = [UInt8](pngData)
      }

      var files: [String] = []
      if let path = extractFilePath(itemDict[Self.utiFileUrl]) {
        files.append(path)
      }
      if files.isEmpty, let urlVal = itemDict[Self.utiUrl] as? URL, urlVal.isFileURL {
        files.append(urlVal.path)
      }

      var colorValue: Int64?
      if let uiColor = itemDict["com.apple.uikit.color"] as? UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
          let ai = Int64(round(a * 255)) & 0xFF
          let ri = Int64(round(r * 255)) & 0xFF
          let gi = Int64(round(g * 255)) & 0xFF
          let bi = Int64(round(b * 255)) & 0xFF
          colorValue = (ai << 24) | (ri << 16) | (gi << 8) | bi
        }
      }

      var customEntries: [WireCustomFormatEntry] = []
      for fmt in requestedCustom {
        if let rawData = itemDict[fmt] as? Data {
          customEntries.append(WireCustomFormatEntry(format: fmt, data: [UInt8](rawData)))
        } else if let rawStr = itemDict[fmt] as? String, let data = rawStr.data(using: .utf8) {
          customEntries.append(WireCustomFormatEntry(format: fmt, data: [UInt8](data)))
        } else if let typed = itemDict[fmt] as? FlutterStandardTypedData {
          customEntries.append(WireCustomFormatEntry(format: fmt, data: [UInt8](typed.data)))
        }
      }

      if !files.isEmpty {
        if let pt = plainText, pt.hasPrefix("file:") { plainText = nil }
        if let u = uriStr, u.hasPrefix("file:") { uriStr = nil }
      }

      results.append(
        WireClipboardItem(
          plainText: plainText,
          html: html,
          rtfBytes: rtfBytes,
          markdown: markdown,
          uri: uriStr,
          imageBytes: imageBytes,
          imageMimeType: "image/png",
          files: files.isEmpty ? nil : files,
          fileCopyMode: .copy,
          colorValue: colorValue,
          customFormats: customEntries.isEmpty ? nil : customEntries
        )
      )
    }

    if let urls = pb.urls, !urls.isEmpty {
      let existing = Set(results.compactMap { $0.files }.flatMap { $0 })
      let missing = urls.filter { $0.isFileURL && !existing.contains($0.path) }
      if !missing.isEmpty && results.allSatisfy({ $0.files == nil }) {
        if results.count == 1, results[0].files == nil {
          results[0].files = missing.map { $0.path }
        } else if results.isEmpty {
          results.append(
            WireClipboardItem(
              plainText: nil,
              html: nil,
              rtfBytes: nil,
              markdown: nil,
              uri: nil,
              imageBytes: nil,
              imageMimeType: "image/png",
              files: missing.map { $0.path },
              fileCopyMode: .copy,
              colorValue: nil,
              customFormats: nil
            )
          )
        }
      }
    }

    return results
  }

  func getMetadata(
    target: WireClipboardBufferTarget,
    detectPatterns: Bool
  ) async throws -> WireClipboardMetadata {
    let pb = resolvePasteboard(buffer: target.buffer, customName: target.customBufferName)

    let allTypes = pb.types
    let lowerTypes = Set(allTypes.map { $0.lowercased() })

    let hasPlainText = pb.hasStrings || lowerTypes.contains(Self.utiPlainText)
    let hasHtml = lowerTypes.contains(Self.utiHtml) || lowerTypes.contains("text/html")
    let hasRtf = lowerTypes.contains(Self.utiRtf) || lowerTypes.contains("text/rtf")
    let hasMarkdown = lowerTypes.contains(Self.utiMarkdown) || lowerTypes.contains("text/markdown")
    let hasUri = pb.hasURLs || lowerTypes.contains(Self.utiUrl)
    let hasImage = pb.hasImages || lowerTypes.contains(Self.utiPng) || lowerTypes.contains(Self.utiJpeg)
    let hasFiles = lowerTypes.contains(Self.utiFileUrl)
      || (pb.hasURLs && (pb.urls?.contains(where: { $0.isFileURL }) ?? false))
    let hasColor = pb.hasColors

    if detectPatterns {
      let probableWebURL: PartialKeyPath<UIPasteboard.DetectedValues> = \.probableWebURL
      let probableWebSearch: PartialKeyPath<UIPasteboard.DetectedValues> = \.probableWebSearch
      let number: PartialKeyPath<UIPasteboard.DetectedValues> = \.number
      let emailAddresses: PartialKeyPath<UIPasteboard.DetectedValues> = \.emailAddresses
      let phoneNumbers: PartialKeyPath<UIPasteboard.DetectedValues> = \.phoneNumbers
      let postalAddresses: PartialKeyPath<UIPasteboard.DetectedValues> = \.postalAddresses
      let flightNumbers: PartialKeyPath<UIPasteboard.DetectedValues> = \.flightNumbers
      let shipmentTrackingNumbers: PartialKeyPath<UIPasteboard.DetectedValues> = \.shipmentTrackingNumbers
      let moneyAmounts: PartialKeyPath<UIPasteboard.DetectedValues> = \.moneyAmounts
      let patternsToCheck: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [
        probableWebURL,
        probableWebSearch,
        number,
        emailAddresses,
        phoneNumbers,
        postalAddresses,
        flightNumbers,
        shipmentTrackingNumbers,
        moneyAmounts
      ]

      return await withCheckedContinuation { continuation in
        pb.detectPatterns(for: patternsToCheck) { [weak pb] detectResult in
          var detected: [WireClipboardDetectedPattern] = []
          if case .success(let found) = detectResult {
            if found.contains(probableWebURL) { detected.append(.probableWebUrl) }
            if found.contains(probableWebSearch) { detected.append(.probableWebSearch) }
            if found.contains(number) { detected.append(.number) }
            if found.contains(emailAddresses) { detected.append(.emailAddress) }
            if found.contains(phoneNumbers) { detected.append(.phoneNumber) }
            if found.contains(postalAddresses) { detected.append(.postalAddress) }
            if found.contains(flightNumbers) { detected.append(.flightNumber) }
            if found.contains(shipmentTrackingNumbers) { detected.append(.shipmentTrackingNumber) }
            if found.contains(moneyAmounts) { detected.append(.moneyAmount) }
          }
          continuation.resume(
            returning: WireClipboardMetadata(
              changeCount: Int64(pb?.changeCount ?? 0),
              timestampMs: nil,
              itemCount: Int64(pb?.numberOfItems ?? 0),
              hasPlainText: hasPlainText,
              hasHtml: hasHtml,
              hasRtf: hasRtf,
              hasMarkdown: hasMarkdown,
              hasUri: hasUri,
              hasImage: hasImage,
              hasFiles: hasFiles,
              hasColor: hasColor,
              rawPlatformFormats: allTypes,
              detectedPatterns: detected
            )
          )
        }
      }
    }

    return WireClipboardMetadata(
      changeCount: Int64(pb.changeCount),
      timestampMs: nil,
      itemCount: Int64(pb.numberOfItems),
      hasPlainText: hasPlainText,
      hasHtml: hasHtml,
      hasRtf: hasRtf,
      hasMarkdown: hasMarkdown,
      hasUri: hasUri,
      hasImage: hasImage,
      hasFiles: hasFiles,
      hasColor: hasColor,
      rawPlatformFormats: allTypes,
      detectedPatterns: []
    )
  }

  func getChangeCount(target: WireClipboardBufferTarget) throws -> Int64 {
    let pb = resolvePasteboard(buffer: target.buffer, customName: target.customBufferName)
    return Int64(pb.changeCount)
  }

  func clear(target: WireClipboardBufferTarget) throws -> Bool {
    let pb = resolvePasteboard(buffer: target.buffer, customName: target.customBufferName)
    pb.items = []
    return true
  }

  func setPollingInterval(intervalMs: Int64) throws {
    // iOS uses UIPasteboard.changedNotification and didBecomeActiveNotification.
  }
}
