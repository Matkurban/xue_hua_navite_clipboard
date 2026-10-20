#include "xue_hua_navite_clipboard_plugin.h"

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <VersionHelpers.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace xue_hua_navite_clipboard {

namespace {

// UTF-8 <-> UTF-16 helpers
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int count = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (count <= 0) return std::wstring();
  std::wstring wide(count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), count);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int count = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                  static_cast<int>(wide.size()), nullptr, 0,
                                  nullptr, nullptr);
  if (count <= 0) return std::string();
  std::string utf8(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), count, nullptr, nullptr);
  return utf8;
}

// RAII Clipboard Guard with retry logic
class ScopedClipboard {
 public:
  explicit ScopedClipboard(HWND hwnd) {
    for (int i = 0; i < 5; ++i) {
      if (OpenClipboard(hwnd)) {
        opened_ = true;
        break;
      }
      Sleep(15);
    }
  }
  ~ScopedClipboard() {
    if (opened_) {
      CloseClipboard();
    }
  }
  bool IsOpen() const { return opened_; }

 private:
  bool opened_ = false;
};

// Build Win32 CF_HTML payload from an HTML fragment
std::string BuildCfHtmlPayload(const std::string& fragment) {
  const std::string prefix =
      "<html>\r\n<body>\r\n<!--StartFragment-->";
  const std::string suffix =
      "<!--EndFragment-->\r\n</body>\r\n</html>";
  const char* header_template =
      "Version:0.9\r\n"
      "StartHTML:%010u\r\n"
      "EndHTML:%010u\r\n"
      "StartFragment:%010u\r\n"
      "EndFragment:%010u\r\n";

  char dummy_header[200];
  std::snprintf(dummy_header, sizeof(dummy_header), header_template, 0, 0, 0, 0);
  size_t header_len = std::strlen(dummy_header);
  size_t start_html = header_len;
  size_t start_fragment = start_html + prefix.size();
  size_t end_fragment = start_fragment + fragment.size();
  size_t end_html = end_fragment + suffix.size();

  char real_header[200];
  std::snprintf(real_header, sizeof(real_header), header_template,
                static_cast<unsigned int>(start_html),
                static_cast<unsigned int>(end_html),
                static_cast<unsigned int>(start_fragment),
                static_cast<unsigned int>(end_fragment));

  std::string payload(real_header);
  payload += prefix;
  payload += fragment;
  payload += suffix;
  return payload;
}

// Extract clean HTML fragment from Win32 CF_HTML payload
std::string ParseCfHtmlPayload(const std::string& raw) {
  auto find_offset = [&](const char* key) -> size_t {
    size_t pos = raw.find(key);
    if (pos == std::string::npos) return std::string::npos;
    pos += std::strlen(key);
    return static_cast<size_t>(std::strtoul(raw.c_str() + pos, nullptr, 10));
  };

  size_t start_frag = find_offset("StartFragment:");
  size_t end_frag = find_offset("EndFragment:");
  if (start_frag != std::string::npos && end_frag != std::string::npos &&
      end_frag > start_frag && end_frag <= raw.size()) {
    return raw.substr(start_frag, end_frag - start_frag);
  }

  size_t start_html = find_offset("StartHTML:");
  size_t end_html = find_offset("EndHTML:");
  if (start_html != std::string::npos && end_html != std::string::npos &&
      end_html > start_html && end_html <= raw.size()) {
    return raw.substr(start_html, end_html - start_html);
  }
  return raw;
}

bool WriteGlobalBytes(UINT format, const void* data, size_t size) {
  HGLOBAL hmem = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!hmem) return false;
  void* ptr = GlobalLock(hmem);
  if (!ptr) {
    GlobalFree(hmem);
    return false;
  }
  std::memcpy(ptr, data, size);
  GlobalUnlock(hmem);
  if (!SetClipboardData(format, hmem)) {
    GlobalFree(hmem);
    return false;
  }
  return true;
}

bool WriteDwordFormat(const wchar_t* format_name, DWORD value) {
  UINT fmt = RegisterClipboardFormatW(format_name);
  if (fmt == 0) return false;
  return WriteGlobalBytes(fmt, &value, sizeof(DWORD));
}

// Convert CF_DIB global memory to PNG bytes using GDI+
std::vector<uint8_t> ConvertDibToPng(HGLOBAL hdib) {
  std::vector<uint8_t> png_bytes;
  if (!hdib) return png_bytes;

  void* dib_ptr = GlobalLock(hdib);
  if (!dib_ptr) return png_bytes;

  Gdiplus::GdiplusStartupInput gdiplusStartupInput;
  ULONG_PTR gdiplusToken = 0;
  if (Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, nullptr) ==
      Gdiplus::Ok) {
    BITMAPINFO* bmi = static_cast<BITMAPINFO*>(dib_ptr);
    size_t palette_bytes = 0;
    if (bmi->bmiHeader.biBitCount <= 8) {
      DWORD colors = bmi->bmiHeader.biClrUsed
                         ? bmi->bmiHeader.biClrUsed
                         : (1u << bmi->bmiHeader.biBitCount);
      palette_bytes = colors * sizeof(RGBQUAD);
    } else if (bmi->bmiHeader.biCompression == BI_BITFIELDS) {
      palette_bytes = 3 * sizeof(DWORD);
    }
    void* bits = reinterpret_cast<uint8_t*>(dib_ptr) +
                 bmi->bmiHeader.biSize + palette_bytes;

    std::unique_ptr<Gdiplus::Bitmap> bitmap(
        Gdiplus::Bitmap::FromBITMAPINFO(bmi, bits));
    if (bitmap && bitmap->GetLastStatus() == Gdiplus::Ok) {
      CLSID png_clsid = {0x557cf406,
                         0x1a04,
                         0x11d3,
                         {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
      IStream* stream = nullptr;
      if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) == S_OK && stream) {
        if (bitmap->Save(stream, &png_clsid, nullptr) == Gdiplus::Ok) {
          HGLOBAL hstream_mem = nullptr;
          if (GetHGlobalFromStream(stream, &hstream_mem) == S_OK &&
              hstream_mem) {
            SIZE_T stream_size = GlobalSize(hstream_mem);
            void* stream_ptr = GlobalLock(hstream_mem);
            if (stream_ptr && stream_size > 0) {
              png_bytes.resize(stream_size);
              std::memcpy(png_bytes.data(), stream_ptr, stream_size);
              GlobalUnlock(hstream_mem);
            }
          }
        }
        stream->Release();
      }
    }
    Gdiplus::GdiplusShutdown(gdiplusToken);
  }

  GlobalUnlock(hdib);
  return png_bytes;
}

const flutter::EncodableValue* GetMapValue(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end() || it->second.IsNull()) return nullptr;
  return &(it->second);
}

}  // namespace

// static
void XueHuaNaviteClipboardPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "xue_hua_navite_clipboard",
          &flutter::StandardMethodCodec::GetInstance());

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "xue_hua_navite_clipboard/events",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<XueHuaNaviteClipboardPlugin>(registrar);
  auto* plugin_pointer = plugin.get();

  method_channel->SetMethodCallHandler(
      [plugin_pointer](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto stream_handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        plugin_pointer->StartListening(std::move(events));
        return nullptr;
      },
      [plugin_pointer](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        plugin_pointer->StopListening();
        return nullptr;
      });

  event_channel->SetStreamHandler(std::move(stream_handler));

  registrar->AddPlugin(std::move(plugin));
}

XueHuaNaviteClipboardPlugin::XueHuaNaviteClipboardPlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {}

XueHuaNaviteClipboardPlugin::~XueHuaNaviteClipboardPlugin() {
  StopListening();
}

HWND XueHuaNaviteClipboardPlugin::GetTargetWindow() const {
  if (registrar_ && registrar_->GetView()) {
    HWND view_hwnd = registrar_->GetView()->GetNativeWindow();
    if (view_hwnd) {
      HWND root = GetAncestor(view_hwnd, GA_ROOT);
      return root ? root : view_hwnd;
    }
  }
  return nullptr;
}

void XueHuaNaviteClipboardPlugin::StartListening(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  StopListening();
  event_sink_ = std::move(events);
  last_sequence_number_ = GetClipboardSequenceNumber();

  HWND hwnd = GetTargetWindow();
  if (!hwnd || !registrar_) return;

  if (AddClipboardFormatListener(hwnd)) {
    listening_hwnd_ = hwnd;
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
            -> std::optional<LRESULT> {
          if (message == WM_CLIPBOARDUPDATE && event_sink_) {
            DWORD seq = GetClipboardSequenceNumber();
            if (seq != last_sequence_number_) {
              last_sequence_number_ = seq;
              auto now_ms =
                  std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();
              flutter::EncodableMap payload = {
                  {flutter::EncodableValue("buffer"),
                   flutter::EncodableValue("general")},
                  {flutter::EncodableValue("changeCount"),
                   flutter::EncodableValue(static_cast<int64_t>(seq))},
                  {flutter::EncodableValue("timestampMs"),
                   flutter::EncodableValue(static_cast<int64_t>(now_ms))},
              };
              event_sink_->Success(flutter::EncodableValue(payload));
            }
          }
          return std::nullopt;
        });
  }
}

void XueHuaNaviteClipboardPlugin::StopListening() {
  if (window_proc_id_ != -1 && registrar_) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    window_proc_id_ = -1;
  }
  if (listening_hwnd_) {
    RemoveClipboardFormatListener(listening_hwnd_);
    listening_hwnd_ = nullptr;
  }
  event_sink_.reset();
}

void XueHuaNaviteClipboardPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
    return;
  }

  if (method == "getChangeCount") {
    DWORD seq = GetClipboardSequenceNumber();
    result->Success(flutter::EncodableValue(static_cast<int64_t>(seq)));
    return;
  }

  if (method == "setPollingInterval") {
    result->Success();
    return;
  }

  if (method == "clear") {
    ScopedClipboard clip(GetTargetWindow());
    if (!clip.IsOpen()) {
      result->Error("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
      return;
    }
    EmptyClipboard();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  const auto* args_map =
      std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "writeItems") {
    if (!args_map) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    const auto* items_val = GetMapValue(*args_map, "items");
    const auto* items_list =
        items_val ? std::get_if<flutter::EncodableList>(items_val) : nullptr;
    if (!items_list || items_list->empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    const auto* item_map =
        std::get_if<flutter::EncodableMap>(&((*items_list)[0]));
    if (!item_map) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    bool is_sensitive = false;
    bool is_transient = false;
    bool local_only = false;
    if (const auto* opts_val = GetMapValue(*args_map, "options")) {
      if (const auto* opts = std::get_if<flutter::EncodableMap>(opts_val)) {
        if (const auto* v = GetMapValue(*opts, "isSensitive")) {
          if (const auto* b = std::get_if<bool>(v)) is_sensitive = *b;
        }
        if (const auto* v = GetMapValue(*opts, "isTransient")) {
          if (const auto* b = std::get_if<bool>(v)) is_transient = *b;
        }
        if (const auto* v = GetMapValue(*opts, "localOnly")) {
          if (const auto* b = std::get_if<bool>(v)) local_only = *b;
        }
      }
    }

    ScopedClipboard clip(GetTargetWindow());
    if (!clip.IsOpen()) {
      result->Error("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
      return;
    }
    EmptyClipboard();

    // 1. Plain text
    if (const auto* text_val = GetMapValue(*item_map, "plainText")) {
      if (const auto* text_str = std::get_if<std::string>(text_val)) {
        std::wstring wide = Utf8ToWide(*text_str);
        WriteGlobalBytes(CF_UNICODETEXT, wide.c_str(),
                         (wide.size() + 1) * sizeof(wchar_t));
      }
    }

    // 2. HTML Format
    if (const auto* html_val = GetMapValue(*item_map, "html")) {
      if (const auto* html_str = std::get_if<std::string>(html_val)) {
        UINT cf_html = RegisterClipboardFormatW(L"HTML Format");
        if (cf_html != 0) {
          std::string payload = BuildCfHtmlPayload(*html_str);
          WriteGlobalBytes(cf_html, payload.c_str(), payload.size() + 1);
        }
      }
    }

    // 3. Rich Text Format (RTF)
    if (const auto* rtf_val = GetMapValue(*item_map, "rtfBytes")) {
      if (const auto* rtf_bytes = std::get_if<std::vector<uint8_t>>(rtf_val)) {
        UINT cf_rtf = RegisterClipboardFormatW(L"Rich Text Format");
        if (cf_rtf != 0 && !rtf_bytes->empty()) {
          WriteGlobalBytes(cf_rtf, rtf_bytes->data(), rtf_bytes->size());
        }
      }
    }

    // 4. Markdown
    if (const auto* md_val = GetMapValue(*item_map, "markdown")) {
      if (const auto* md_str = std::get_if<std::string>(md_val)) {
        UINT cf_md = RegisterClipboardFormatW(L"text/markdown");
        if (cf_md != 0) {
          WriteGlobalBytes(cf_md, md_str->c_str(), md_str->size() + 1);
        }
      }
    }

    // 5. URI / URL
    if (const auto* uri_val = GetMapValue(*item_map, "uri")) {
      if (const auto* uri_str = std::get_if<std::string>(uri_val)) {
        UINT cf_url = RegisterClipboardFormatW(L"UniformResourceLocatorW");
        if (cf_url != 0) {
          std::wstring wide_url = Utf8ToWide(*uri_str);
          WriteGlobalBytes(cf_url, wide_url.c_str(),
                           (wide_url.size() + 1) * sizeof(wchar_t));
        }
      }
    }

    // 6. Image (PNG)
    if (const auto* img_val = GetMapValue(*item_map, "imageBytes")) {
      if (const auto* img_bytes = std::get_if<std::vector<uint8_t>>(img_val)) {
        if (!img_bytes->empty()) {
          UINT cf_png = RegisterClipboardFormatW(L"PNG");
          if (cf_png != 0) {
            WriteGlobalBytes(cf_png, img_bytes->data(), img_bytes->size());
          }
          UINT cf_mime_png = RegisterClipboardFormatW(L"image/png");
          if (cf_mime_png != 0) {
            WriteGlobalBytes(cf_mime_png, img_bytes->data(), img_bytes->size());
          }
        }
      }
    }

    // 7. Files (CF_HDROP + Preferred DropEffect)
    if (const auto* files_val = GetMapValue(*item_map, "files")) {
      if (const auto* files_list =
              std::get_if<flutter::EncodableList>(files_val)) {
        std::vector<wchar_t> multi_sz;
        for (const auto& f : *files_list) {
          if (const auto* path_str = std::get_if<std::string>(&f)) {
            std::wstring wpath = Utf8ToWide(*path_str);
            if (!wpath.empty()) {
              multi_sz.insert(multi_sz.end(), wpath.begin(), wpath.end());
              multi_sz.push_back(L'\0');
            }
          }
        }
        if (!multi_sz.empty()) {
          multi_sz.push_back(L'\0');
          size_t total_size =
              sizeof(DROPFILES) + multi_sz.size() * sizeof(wchar_t);
          HGLOBAL hdrop = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total_size);
          if (hdrop) {
            auto* df = static_cast<DROPFILES*>(GlobalLock(hdrop));
            if (df) {
              df->pFiles = sizeof(DROPFILES);
              df->fWide = TRUE;
              std::memcpy(reinterpret_cast<uint8_t*>(df) + sizeof(DROPFILES),
                          multi_sz.data(), multi_sz.size() * sizeof(wchar_t));
              GlobalUnlock(hdrop);
              if (!SetClipboardData(CF_HDROP, hdrop)) {
                GlobalFree(hdrop);
              }
            } else {
              GlobalFree(hdrop);
            }
          }

          DWORD drop_effect = DROPEFFECT_COPY;
          if (const auto* mode_val = GetMapValue(*item_map, "fileCopyMode")) {
            if (const auto* mode_str = std::get_if<std::string>(mode_val)) {
              if (*mode_str == "cut") {
                drop_effect = DROPEFFECT_MOVE;
              }
            }
          }
          WriteDwordFormat(L"Preferred DropEffect", drop_effect);
        }
      }
    }

    // 8. Color
    if (const auto* color_val = GetMapValue(*item_map, "colorValue")) {
      int64_t color_int = 0;
      if (const auto* i32 = std::get_if<int32_t>(color_val)) {
        color_int = *i32;
      } else if (const auto* i64 = std::get_if<int64_t>(color_val)) {
        color_int = *i64;
      }
      UINT cf_color = RegisterClipboardFormatW(L"application/x-color");
      if (cf_color != 0) {
        WriteGlobalBytes(cf_color, &color_int, sizeof(int64_t));
      }
    }

    // 9. Custom Formats
    if (const auto* custom_val = GetMapValue(*item_map, "customFormats")) {
      if (const auto* custom_map =
              std::get_if<flutter::EncodableMap>(custom_val)) {
        for (const auto& kv : *custom_map) {
          const auto* fmt_name = std::get_if<std::string>(&kv.first);
          const auto* fmt_bytes = std::get_if<std::vector<uint8_t>>(&kv.second);
          if (fmt_name && fmt_bytes && !fmt_name->empty()) {
            UINT cf_custom =
                RegisterClipboardFormatW(Utf8ToWide(*fmt_name).c_str());
            if (cf_custom != 0) {
              WriteGlobalBytes(cf_custom, fmt_bytes->data(), fmt_bytes->size());
            }
          }
        }
      }
    }

    // 10. Privacy & Cloud Clipboard Exclusion Flags (Windows 10/11)
    if (is_sensitive) {
      WriteDwordFormat(L"ExcludeClipboardContentFromMonitorProcessing", 0);
      WriteDwordFormat(L"CanIncludeInClipboardHistory", 0);
      WriteDwordFormat(L"CanUploadToCloudClipboard", 0);
    } else {
      if (is_transient) {
        WriteDwordFormat(L"CanIncludeInClipboardHistory", 0);
      }
      if (local_only) {
        WriteDwordFormat(L"CanUploadToCloudClipboard", 0);
      }
    }

    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "readItems") {
    ScopedClipboard clip(GetTargetWindow());
    if (!clip.IsOpen()) {
      result->Error("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
      return;
    }

    flutter::EncodableMap item;

    // 1. Plain Text
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
      HANDLE hdata = GetClipboardData(CF_UNICODETEXT);
      if (hdata) {
        const wchar_t* wstr = static_cast<const wchar_t*>(GlobalLock(hdata));
        if (wstr) {
          item[flutter::EncodableValue("plainText")] =
              flutter::EncodableValue(WideToUtf8(wstr));
          GlobalUnlock(hdata);
        }
      }
    }

    // 2. HTML
    UINT cf_html = RegisterClipboardFormatW(L"HTML Format");
    if (cf_html != 0 && IsClipboardFormatAvailable(cf_html)) {
      HANDLE hdata = GetClipboardData(cf_html);
      if (hdata) {
        const char* cstr = static_cast<const char*>(GlobalLock(hdata));
        size_t sz = GlobalSize(hdata);
        if (cstr && sz > 0) {
          size_t len = strnlen(cstr, sz);
          std::string raw_html(cstr, len);
          item[flutter::EncodableValue("html")] =
              flutter::EncodableValue(ParseCfHtmlPayload(raw_html));
          GlobalUnlock(hdata);
        }
      }
    }

    // 3. RTF
    UINT cf_rtf = RegisterClipboardFormatW(L"Rich Text Format");
    if (cf_rtf != 0 && IsClipboardFormatAvailable(cf_rtf)) {
      HANDLE hdata = GetClipboardData(cf_rtf);
      if (hdata) {
        const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
        size_t sz = GlobalSize(hdata);
        if (ptr && sz > 0) {
          // Strip trailing null byte if present
          while (sz > 0 && ptr[sz - 1] == 0) --sz;
          std::vector<uint8_t> rtf_vec(ptr, ptr + sz);
          item[flutter::EncodableValue("rtfBytes")] =
              flutter::EncodableValue(rtf_vec);
          GlobalUnlock(hdata);
        }
      }
    }

    // 4. Markdown
    UINT cf_md = RegisterClipboardFormatW(L"text/markdown");
    if (cf_md != 0 && IsClipboardFormatAvailable(cf_md)) {
      HANDLE hdata = GetClipboardData(cf_md);
      if (hdata) {
        const char* cstr = static_cast<const char*>(GlobalLock(hdata));
        size_t sz = GlobalSize(hdata);
        if (cstr && sz > 0) {
          size_t len = strnlen(cstr, sz);
          item[flutter::EncodableValue("markdown")] =
              flutter::EncodableValue(std::string(cstr, len));
          GlobalUnlock(hdata);
        }
      }
    }

    // 5. URI
    UINT cf_url = RegisterClipboardFormatW(L"UniformResourceLocatorW");
    if (cf_url != 0 && IsClipboardFormatAvailable(cf_url)) {
      HANDLE hdata = GetClipboardData(cf_url);
      if (hdata) {
        const wchar_t* wstr = static_cast<const wchar_t*>(GlobalLock(hdata));
        if (wstr) {
          item[flutter::EncodableValue("uri")] =
              flutter::EncodableValue(WideToUtf8(wstr));
          GlobalUnlock(hdata);
        }
      }
    }

    // 6. Image (Prefer PNG, fallback to CF_DIB -> PNG conversion)
    UINT cf_png = RegisterClipboardFormatW(L"PNG");
    UINT cf_mime_png = RegisterClipboardFormatW(L"image/png");
    std::vector<uint8_t> image_bytes;
    if (cf_png != 0 && IsClipboardFormatAvailable(cf_png)) {
      HANDLE hdata = GetClipboardData(cf_png);
      if (hdata) {
        const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
        size_t sz = GlobalSize(hdata);
        if (ptr && sz > 0) {
          image_bytes.assign(ptr, ptr + sz);
        }
        GlobalUnlock(hdata);
      }
    } else if (cf_mime_png != 0 && IsClipboardFormatAvailable(cf_mime_png)) {
      HANDLE hdata = GetClipboardData(cf_mime_png);
      if (hdata) {
        const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
        size_t sz = GlobalSize(hdata);
        if (ptr && sz > 0) {
          image_bytes.assign(ptr, ptr + sz);
        }
        GlobalUnlock(hdata);
      }
    } else if (IsClipboardFormatAvailable(CF_DIB)) {
      HANDLE hdib = GetClipboardData(CF_DIB);
      image_bytes = ConvertDibToPng(hdib);
    }

    if (!image_bytes.empty()) {
      item[flutter::EncodableValue("imageBytes")] =
          flutter::EncodableValue(image_bytes);
      item[flutter::EncodableValue("imageMimeType")] =
          flutter::EncodableValue("image/png");
    }

    // 7. Files (CF_HDROP + Preferred DropEffect)
    if (IsClipboardFormatAvailable(CF_HDROP)) {
      HANDLE hdrop = GetClipboardData(CF_HDROP);
      if (hdrop) {
        HDROP drop = static_cast<HDROP>(GlobalLock(hdrop));
        if (drop) {
          UINT file_count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
          flutter::EncodableList files;
          for (UINT i = 0; i < file_count; ++i) {
            UINT char_len = DragQueryFileW(drop, i, nullptr, 0);
            if (char_len > 0) {
              std::wstring wpath(char_len + 1, L'\0');
              DragQueryFileW(drop, i, wpath.data(), char_len + 1);
              wpath.resize(char_len);
              files.push_back(flutter::EncodableValue(WideToUtf8(wpath)));
            }
          }
          GlobalUnlock(hdrop);
          if (!files.empty()) {
            item[flutter::EncodableValue("files")] =
                flutter::EncodableValue(files);
          }
        }
      }

      std::string copy_mode = "copy";
      UINT cf_effect = RegisterClipboardFormatW(L"Preferred DropEffect");
      if (cf_effect != 0 && IsClipboardFormatAvailable(cf_effect)) {
        HANDLE heffect = GetClipboardData(cf_effect);
        if (heffect && GlobalSize(heffect) >= sizeof(DWORD)) {
          const DWORD* effect_ptr =
              static_cast<const DWORD*>(GlobalLock(heffect));
          if (effect_ptr) {
            if ((*effect_ptr & DROPEFFECT_MOVE) != 0) {
              copy_mode = "cut";
            }
            GlobalUnlock(heffect);
          }
        }
      }
      item[flutter::EncodableValue("fileCopyMode")] =
          flutter::EncodableValue(copy_mode);
    }

    // 8. Color
    UINT cf_color = RegisterClipboardFormatW(L"application/x-color");
    if (cf_color != 0 && IsClipboardFormatAvailable(cf_color)) {
      HANDLE hdata = GetClipboardData(cf_color);
      if (hdata && GlobalSize(hdata) >= sizeof(int64_t)) {
        const int64_t* cptr = static_cast<const int64_t*>(GlobalLock(hdata));
        if (cptr) {
          item[flutter::EncodableValue("colorValue")] =
              flutter::EncodableValue(*cptr);
          GlobalUnlock(hdata);
        }
      }
    }

    // 9. Requested Custom Formats
    if (args_map) {
      if (const auto* opts_val = GetMapValue(*args_map, "options")) {
        if (const auto* opts = std::get_if<flutter::EncodableMap>(opts_val)) {
          if (const auto* req_val =
                  GetMapValue(*opts, "requestedCustomFormats")) {
            if (const auto* req_list =
                    std::get_if<flutter::EncodableList>(req_val)) {
              flutter::EncodableMap custom_map;
              for (const auto& fmt_entry : *req_list) {
                if (const auto* fmt_name =
                        std::get_if<std::string>(&fmt_entry)) {
                  UINT cf_custom = RegisterClipboardFormatW(
                      Utf8ToWide(*fmt_name).c_str());
                  if (cf_custom != 0 &&
                      IsClipboardFormatAvailable(cf_custom)) {
                    HANDLE hdata = GetClipboardData(cf_custom);
                    if (hdata) {
                      const uint8_t* ptr =
                          static_cast<const uint8_t*>(GlobalLock(hdata));
                      size_t sz = GlobalSize(hdata);
                      if (ptr && sz > 0) {
                        std::vector<uint8_t> bytes(ptr, ptr + sz);
                        custom_map[flutter::EncodableValue(*fmt_name)] =
                            flutter::EncodableValue(bytes);
                      }
                      GlobalUnlock(hdata);
                    }
                  }
                }
              }
              if (!custom_map.empty()) {
                item[flutter::EncodableValue("customFormats")] =
                    flutter::EncodableValue(custom_map);
              }
            }
          }
        }
      }
    }

    flutter::EncodableList items_out;
    if (!item.empty()) {
      items_out.push_back(flutter::EncodableValue(item));
    }
    result->Success(flutter::EncodableValue(items_out));
    return;
  }

  if (method == "getMetadata") {
    DWORD seq = GetClipboardSequenceNumber();
    ScopedClipboard clip(GetTargetWindow());

    flutter::EncodableList raw_formats;
    bool has_text = IsClipboardFormatAvailable(CF_UNICODETEXT) != FALSE;
    UINT cf_html = RegisterClipboardFormatW(L"HTML Format");
    bool has_html = cf_html != 0 && IsClipboardFormatAvailable(cf_html);
    UINT cf_rtf = RegisterClipboardFormatW(L"Rich Text Format");
    bool has_rtf = cf_rtf != 0 && IsClipboardFormatAvailable(cf_rtf);
    UINT cf_md = RegisterClipboardFormatW(L"text/markdown");
    bool has_md = cf_md != 0 && IsClipboardFormatAvailable(cf_md);
    UINT cf_url = RegisterClipboardFormatW(L"UniformResourceLocatorW");
    bool has_uri = cf_url != 0 && IsClipboardFormatAvailable(cf_url);
    UINT cf_png = RegisterClipboardFormatW(L"PNG");
    bool has_image = (cf_png != 0 && IsClipboardFormatAvailable(cf_png)) ||
                     IsClipboardFormatAvailable(CF_DIB) ||
                     IsClipboardFormatAvailable(CF_BITMAP);
    bool has_files = IsClipboardFormatAvailable(CF_HDROP) != FALSE;
    UINT cf_color = RegisterClipboardFormatW(L"application/x-color");
    bool has_color = cf_color != 0 && IsClipboardFormatAvailable(cf_color);

    if (clip.IsOpen()) {
      UINT fmt = 0;
      wchar_t name_buf[256];
      while ((fmt = EnumClipboardFormats(fmt)) != 0) {
        int len = GetClipboardFormatNameW(fmt, name_buf, 256);
        if (len > 0) {
          raw_formats.push_back(
              flutter::EncodableValue(WideToUtf8(std::wstring(name_buf, len))));
        } else {
          switch (fmt) {
            case CF_UNICODETEXT:
              raw_formats.push_back(flutter::EncodableValue("CF_UNICODETEXT"));
              break;
            case CF_DIB:
              raw_formats.push_back(flutter::EncodableValue("CF_DIB"));
              break;
            case CF_HDROP:
              raw_formats.push_back(flutter::EncodableValue("CF_HDROP"));
              break;
            default:
              break;
          }
        }
      }
    }

    bool any_item = has_text || has_html || has_rtf || has_md || has_uri ||
                    has_image || has_files || has_color || !raw_formats.empty();

    flutter::EncodableMap meta = {
        {flutter::EncodableValue("changeCount"),
         flutter::EncodableValue(static_cast<int64_t>(seq))},
        {flutter::EncodableValue("itemCount"),
         flutter::EncodableValue(any_item ? 1 : 0)},
        {flutter::EncodableValue("hasPlainText"),
         flutter::EncodableValue(has_text)},
        {flutter::EncodableValue("hasHtml"),
         flutter::EncodableValue(has_html)},
        {flutter::EncodableValue("hasRtf"), flutter::EncodableValue(has_rtf)},
        {flutter::EncodableValue("hasMarkdown"),
         flutter::EncodableValue(has_md)},
        {flutter::EncodableValue("hasUri"), flutter::EncodableValue(has_uri)},
        {flutter::EncodableValue("hasImage"),
         flutter::EncodableValue(has_image)},
        {flutter::EncodableValue("hasFiles"),
         flutter::EncodableValue(has_files)},
        {flutter::EncodableValue("hasColor"),
         flutter::EncodableValue(has_color)},
        {flutter::EncodableValue("rawPlatformFormats"),
         flutter::EncodableValue(raw_formats)},
        {flutter::EncodableValue("detectedPatterns"),
         flutter::EncodableValue(flutter::EncodableList())},
    };
    result->Success(flutter::EncodableValue(meta));
    return;
  }

  result->NotImplemented();
}

}  // namespace xue_hua_navite_clipboard
