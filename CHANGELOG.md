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
