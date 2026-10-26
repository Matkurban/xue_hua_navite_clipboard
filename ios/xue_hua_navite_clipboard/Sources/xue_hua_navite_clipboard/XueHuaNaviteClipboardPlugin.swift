import Flutter
import UIKit
import UniformTypeIdentifiers

public class XueHuaNaviteClipboardPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
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
    let methodChannel = FlutterMethodChannel(
      name: "xue_hua_navite_clipboard",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "xue_hua_navite_clipboard/events",
      binaryMessenger: registrar.messenger()
    )
    let instance = XueHuaNaviteClipboardPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  deinit {
    stopListening()
  }

  // MARK: - FlutterStreamHandler (Lazy on-demand listener)

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    startListening()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopListening()
    self.eventSink = nil
    return nil
  }

  private func startListening() {
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

  private func stopListening() {
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
      eventSink?([
        "buffer": "general",
        "changeCount": current,
        "timestampMs": nowMs
      ])
    }
  }

  // MARK: - Pasteboard Resolution

  private func resolvePasteboard(buffer: String?, customName: String?) -> UIPasteboard {
    if buffer == "named", let name = customName, !name.isEmpty {
      return UIPasteboard(name: UIPasteboard.Name(name), create: true) ?? .general
    }
    return .general
  }

  // MARK: - MethodCall Handler

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "writeItems":
      result(handleWriteItems(args: args))
    case "readItems":
      result(handleReadItems(args: args))
    case "getMetadata":
      handleGetMetadata(args: args, result: result)
    case "getChangeCount":
      let pb = resolvePasteboard(
        buffer: args?["buffer"] as? String,
        customName: args?["customBufferName"] as? String
      )
      result(pb.changeCount)
    case "clear":
      let pb = resolvePasteboard(
        buffer: args?["buffer"] as? String,
        customName: args?["customBufferName"] as? String
      )
      pb.items = []
      result(true)
    case "setPollingInterval":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleWriteItems(args: [String: Any]?) -> Bool {
    guard let rawItems = args?["items"] as? [[String: Any]], !rawItems.isEmpty else {
      return false
    }
    let options = args?["options"] as? [String: Any]
    let pb = resolvePasteboard(
      buffer: options?["buffer"] as? String,
      customName: options?["customBufferName"] as? String
    )
    let isSensitive = options?["isSensitive"] as? Bool ?? false
    let isTransient = options?["isTransient"] as? Bool ?? false
    let localOnly = options?["localOnly"] as? Bool ?? false
    let expirationMs = options?["expirationMs"] as? Int

    var pbItems: [[String: Any]] = []

    for item in rawItems {
      var dict: [String: Any] = [:]

      if let plainText = item["plainText"] as? String {
        dict[Self.utiPlainText] = plainText
      }
      if let html = item["html"] as? String, let data = html.data(using: .utf8) {
        dict[Self.utiHtml] = data
      }
      if let rtfTyped = item["rtfBytes"] as? FlutterStandardTypedData {
        dict[Self.utiRtf] = rtfTyped.data
      }
      if let markdown = item["markdown"] as? String, let data = markdown.data(using: .utf8) {
        dict[Self.utiMarkdown] = data
        if dict[Self.utiPlainText] == nil {
          dict[Self.utiPlainText] = markdown
        }
      }
      if let uriStr = item["uri"] as? String, let url = URL(string: uriStr) {
        dict[Self.utiUrl] = url
      }
      if let imgTyped = item["imageBytes"] as? FlutterStandardTypedData {
        if let image = UIImage(data: imgTyped.data), let pngData = image.pngData() {
          dict[Self.utiPng] = pngData
        } else {
          dict[Self.utiPng] = imgTyped.data
        }
      }
      // UIPasteboard represents multiple files as multiple items; keep the
      // first URL on this item and emit extra items for the rest so readFiles
      // (which aggregates across items) returns the full list.
      if let files = item["files"] as? [String], !files.isEmpty {
        for (idx, filePath) in files.enumerated() {
          let fileUrl = URL(fileURLWithPath: filePath)
          if idx == 0 {
            dict[Self.utiFileUrl] = fileUrl
          } else {
            pbItems.append([Self.utiFileUrl: fileUrl])
          }
        }
      }
      if let colorValue = item["colorValue"] as? Int {
        let a = CGFloat((colorValue >> 24) & 0xFF) / 255.0
        let r = CGFloat((colorValue >> 16) & 0xFF) / 255.0
        let g = CGFloat((colorValue >> 8) & 0xFF) / 255.0
        let b = CGFloat(colorValue & 0xFF) / 255.0
        dict["com.apple.uikit.color"] = UIColor(red: r, green: g, blue: b, alpha: a)
      }
      // Flutter nested maps arrive as [AnyHashable: Any]; a direct cast to
      // [String: FlutterStandardTypedData] silently fails and drops custom data.
      if let customFormats = item["customFormats"] as? [AnyHashable: Any] {
        for (rawKey, rawValue) in customFormats {
          guard let fmtKey = rawKey as? String else { continue }
          if let typed = rawValue as? FlutterStandardTypedData {
            dict[fmtKey] = typed.data
          } else if let rawData = rawValue as? Data {
            dict[fmtKey] = rawData
          } else if let bytes = rawValue as? [UInt8] {
            dict[fmtKey] = Data(bytes)
          }
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

    // Reinforce file URLs via the dedicated API — more reliable on iOS than
    // public.file-url dictionary entries alone for multi-file readback.
    var allFileUrls: [URL] = []
    for item in rawItems {
      if let files = item["files"] as? [String] {
        allFileUrls.append(contentsOf: files.map { URL(fileURLWithPath: $0) })
      }
    }
    if !allFileUrls.isEmpty {
      // If the pasteboard only contains files, prefer urls setter.
      let onlyFiles = pbItems.allSatisfy { dict in
        Set(dict.keys.map { "\($0)" }).subtracting([Self.utiFileUrl, Self.utiConcealed, Self.utiTransient]).isEmpty
      }
      if onlyFiles {
        pb.urls = allFileUrls
      }
    }

    return true
  }

  private func handleReadItems(args: [String: Any]?) -> [[String: Any?]] {
    let options = args?["options"] as? [String: Any]
    let pb = resolvePasteboard(
      buffer: options?["buffer"] as? String,
      customName: options?["customBufferName"] as? String
    )
    let requestedCustom = (options?["requestedCustomFormats"] as? [String]) ?? []

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
        if s.hasPrefix("/") { return s }
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

    var results: [[String: Any?]] = []

    for itemDict in rawItems {
      // Prefer per-item values. Avoid UIPasteboard.string/url/image which
      // reflect only one "best" representation and leak across items.
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

      var rtfBytes: FlutterStandardTypedData?
      if let rtfData = itemDict[Self.utiRtf] as? Data {
        rtfBytes = FlutterStandardTypedData(bytes: rtfData)
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

      var imageBytes: FlutterStandardTypedData?
      if let pngData = itemDict[Self.utiPng] as? Data {
        imageBytes = FlutterStandardTypedData(bytes: pngData)
      } else if let uiImg = itemDict[Self.utiPng] as? UIImage, let pngData = uiImg.pngData() {
        imageBytes = FlutterStandardTypedData(bytes: pngData)
      } else if let jpegData = itemDict[Self.utiJpeg] as? Data,
                let uiImg = UIImage(data: jpegData),
                let pngData = uiImg.pngData() {
        imageBytes = FlutterStandardTypedData(bytes: pngData)
      }

      var files: [String] = []
      // public.file-url may arrive as URL, String, or Data.
      if let path = extractFilePath(itemDict[Self.utiFileUrl]) {
        files.append(path)
      }
      // Some iOS versions also expose file URLs under public.url.
      if files.isEmpty, let urlVal = itemDict[Self.utiUrl] as? URL, urlVal.isFileURL {
        files.append(urlVal.path)
      }

      var colorValue: Int?
      if let uiColor = itemDict["com.apple.uikit.color"] as? UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
          let ai = Int(round(a * 255)) & 0xFF
          let ri = Int(round(r * 255)) & 0xFF
          let gi = Int(round(g * 255)) & 0xFF
          let bi = Int(round(b * 255)) & 0xFF
          colorValue = (ai << 24) | (ri << 16) | (gi << 8) | bi
        }
      }

      var customMap: [String: FlutterStandardTypedData] = [:]
      for fmt in requestedCustom {
        if let rawData = itemDict[fmt] as? Data {
          customMap[fmt] = FlutterStandardTypedData(bytes: rawData)
        } else if let rawStr = itemDict[fmt] as? String, let data = rawStr.data(using: .utf8) {
          customMap[fmt] = FlutterStandardTypedData(bytes: data)
        } else if let typed = itemDict[fmt] as? FlutterStandardTypedData {
          customMap[fmt] = typed
        }
      }

      // If this item is file-only, do not surface the file URL as plainText/uri.
      if !files.isEmpty {
        if let pt = plainText, pt.hasPrefix("file:") { plainText = nil }
        if let u = uriStr, u.hasPrefix("file:") { uriStr = nil }
      }

      results.append([
        "plainText": plainText,
        "html": html,
        "rtfBytes": rtfBytes,
        "markdown": markdown,
        "uri": uriStr,
        "imageBytes": imageBytes,
        "imageMimeType": "image/png",
        "files": files.isEmpty ? nil : files,
        "fileCopyMode": "copy",
        "colorValue": colorValue,
        "customFormats": customMap
      ])
    }

    // Aggregate pasteboard-level URLs if per-item extraction missed them.
    if let urls = pb.urls, !urls.isEmpty {
      let existing = Set(results.compactMap { $0["files"] as? [String] }.flatMap { $0 })
      let missing = urls.filter { $0.isFileURL && !existing.contains($0.path) }
      if !missing.isEmpty && results.allSatisfy({ ($0["files"] as? [String]) == nil }) {
        // Replace empty file slots with a single aggregated entry when needed.
        if results.count == 1, results[0]["files"] == nil {
          results[0]["files"] = missing.map { $0.path }
        } else if results.isEmpty {
          results.append([
            "plainText": nil,
            "html": nil,
            "rtfBytes": nil,
            "markdown": nil,
            "uri": nil,
            "imageBytes": nil,
            "imageMimeType": "image/png",
            "files": missing.map { $0.path },
            "fileCopyMode": "copy",
            "colorValue": nil,
            "customFormats": [String: FlutterStandardTypedData]()
          ])
        }
      }
    }

    return results
  }

  private func handleGetMetadata(args: [String: Any]?, result: @escaping FlutterResult) {
    let pb = resolvePasteboard(
      buffer: args?["buffer"] as? String,
      customName: args?["customBufferName"] as? String
    )
    let shouldDetectPatterns = args?["detectPatterns"] as? Bool ?? false

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

    if shouldDetectPatterns {
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

      pb.detectPatterns(for: patternsToCheck) { [weak pb] detectResult in
        var detected: [String] = []
        if case .success(let found) = detectResult {
          if found.contains(probableWebURL) { detected.append("probableWebUrl") }
          if found.contains(probableWebSearch) { detected.append("probableWebSearch") }
          if found.contains(number) { detected.append("number") }
          if found.contains(emailAddresses) { detected.append("emailAddress") }
          if found.contains(phoneNumbers) { detected.append("phoneNumber") }
          if found.contains(postalAddresses) { detected.append("postalAddress") }
          if found.contains(flightNumbers) { detected.append("flightNumber") }
          if found.contains(shipmentTrackingNumbers) { detected.append("shipmentTrackingNumber") }
          if found.contains(moneyAmounts) { detected.append("moneyAmount") }
        }
        DispatchQueue.main.async {
          result([
            "changeCount": pb?.changeCount ?? 0,
            "timestampMs": nil,
            "itemCount": pb?.numberOfItems ?? 0,
            "hasPlainText": hasPlainText,
            "hasHtml": hasHtml,
            "hasRtf": hasRtf,
            "hasMarkdown": hasMarkdown,
            "hasUri": hasUri,
            "hasImage": hasImage,
            "hasFiles": hasFiles,
            "hasColor": hasColor,
            "rawPlatformFormats": allTypes,
            "detectedPatterns": detected
          ])
        }
      }
      return
    }

    result([
      "changeCount": pb.changeCount,
      "timestampMs": nil,
      "itemCount": pb.numberOfItems,
      "hasPlainText": hasPlainText,
      "hasHtml": hasHtml,
      "hasRtf": hasRtf,
      "hasMarkdown": hasMarkdown,
      "hasUri": hasUri,
      "hasImage": hasImage,
      "hasFiles": hasFiles,
      "hasColor": hasColor,
      "rawPlatformFormats": allTypes,
      "detectedPatterns": [String]()
    ])
  }
}
