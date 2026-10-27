## 1.0.8

* fix Android: writing file paths to the clipboard no longer uses `file://` URIs (FileUriExposedException on API 24+); serve via `FileProvider` / content URI with grant flags so cross-app paste works
* test: Android emulator example UI driver on API 28/30/34/36 — clear/text/chinese/html/rtf/png/color/custom/files/monitor + API parity all pass

## 1.0.7

* fix macOS: custom binary formats (MIME/UTI) were dropped after writeObjects — re-declare via addTypes/setData so readCustomData roundtrips
* fix macOS/iOS: nested customFormats map cast no longer silently fails (Flutter delivers [AnyHashable:Any] / NSDictionary)
* fix iOS: multi-file write now emits one pasteboard item per path and reinforces via UIPasteboard.urls
* fix iOS: readItems no longer leaks pasteboard-level string/url across items; file URLs parse from URL/String/Data; hasFiles detects file URLs via pb.urls
* test: macOS + iOS simulator example UI driver (integration_test) — clear/text/chinese/sensitive/html/rtf/png/color/custom/files/metadata/listener + API parity all pass

## 1.0.6

* Windows: full example UI driver verification (integration_test) - clear/text/chinese/sensitive/html/rtf/png/color/custom/files/metadata/listener all pass
* test: switch example UI driver to `material_ui` (no deprecated flutter/material)
* test: API parity smoke covers markdown and URI roundtrips on Windows

## 1.0.5

* example: add ValueKeys, Chinese/Files write actions for UI automation
* example: add integration_test UI driver covering clear/text/html/rtf/png/color/custom/files/listener
* fix Linux CMake: set DOWNLOAD_EXTRACT_TIMESTAMP for googletest FetchContent

## 1.0.4

* fix Windows: write CF_DIB alongside PNG so Paint/Office can paste images
* fix Windows: safely read CF_DIB / CF_DIBV5 / CF_BITMAP (screenshot no longer crashes example on launch)
* example: migrate to standalone `material_ui` package

## 1.0.3

* fix Linux build with CMake 4 by bumping googletest to v1.15.2

## 1.0.2

* fix Windows build with Visual Studio 2026 / CMake 4 by bumping googletest to v1.15.2

## 1.0.1

* set minum flutter sdk to `3.47` version
* fix ios build error

## 1.0.0

* impl plugin
