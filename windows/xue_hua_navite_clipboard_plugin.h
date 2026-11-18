#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_

#include <windows.h>

#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>

#include "clipboard_api.g.h"

namespace xue_hua_navite_clipboard {

class XueHuaNaviteClipboardPlugin : public flutter::Plugin,
                                    public ClipboardHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit XueHuaNaviteClipboardPlugin(
      flutter::PluginRegistrarWindows *registrar = nullptr);

  ~XueHuaNaviteClipboardPlugin() override;

  // Disallow copy and assign.
  XueHuaNaviteClipboardPlugin(const XueHuaNaviteClipboardPlugin&) = delete;
  XueHuaNaviteClipboardPlugin& operator=(
      const XueHuaNaviteClipboardPlugin&) = delete;

  // ClipboardHostApi overrides.
  ErrorOr<bool> WriteItems(
      const ::flutter::EncodableList& items,
      const WireClipboardWriteOptions& options) override;
  ErrorOr<::flutter::EncodableList> ReadItems(
      const WireClipboardReadOptions& options) override;
  void GetMetadata(
      const WireClipboardBufferTarget& target,
      bool detect_patterns,
      std::function<void(ErrorOr<WireClipboardMetadata> reply)> result)
      override;
  ErrorOr<int64_t> GetChangeCount(
      const WireClipboardBufferTarget& target) override;
  ErrorOr<bool> Clear(const WireClipboardBufferTarget& target) override;
  std::optional<FlutterError> SetPollingInterval(int64_t interval_ms) override;
  std::optional<FlutterError> StartClipboardListening() override;
  std::optional<FlutterError> StopClipboardListening() override;

 private:
  HWND GetTargetWindow() const;

  flutter::PluginRegistrarWindows *registrar_ = nullptr;
  std::unique_ptr<ClipboardFlutterApi> flutter_api_;
  bool is_listening_ = false;
  int window_proc_id_ = -1;
  HWND listening_hwnd_ = nullptr;
  DWORD last_sequence_number_ = 0;
};

}  // namespace xue_hua_navite_clipboard

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_
