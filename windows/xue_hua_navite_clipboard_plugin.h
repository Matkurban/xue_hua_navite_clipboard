#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>

namespace xue_hua_navite_clipboard {

class XueHuaNaviteClipboardPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit XueHuaNaviteClipboardPlugin(
      flutter::PluginRegistrarWindows *registrar = nullptr);

  virtual ~XueHuaNaviteClipboardPlugin();

  // Disallow copy and assign.
  XueHuaNaviteClipboardPlugin(const XueHuaNaviteClipboardPlugin&) = delete;
  XueHuaNaviteClipboardPlugin& operator=(const XueHuaNaviteClipboardPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  void StartListening(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events);
  void StopListening();
  HWND GetTargetWindow() const;

  flutter::PluginRegistrarWindows *registrar_ = nullptr;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  int window_proc_id_ = -1;
  HWND listening_hwnd_ = nullptr;
  DWORD last_sequence_number_ = 0;
};

}  // namespace xue_hua_navite_clipboard

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CLIPBOARD_PLUGIN_H_
