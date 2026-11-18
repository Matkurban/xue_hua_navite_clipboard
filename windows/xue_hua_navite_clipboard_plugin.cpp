#include "xue_hua_navite_clipboard_plugin.h"

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <objidl.h>
#include <gdiplus.h>

#include <flutter/plugin_registrar_windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
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
  std::wstring wide(static_cast<size_t>(count), L'\0');
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
  std::string utf8(static_cast<size_t>(count), '\0');
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

// Trim GlobalSize padding so PNG payload ends at IEND.
size_t EffectivePngSize(const uint8_t* data, size_t size) {
  if (!data || size < 8 || data[0] != 0x89 || data[1] != 'P') {
    return size;
  }
  for (size_t i = 8; i + 12 <= size; ++i) {
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 &&
        data[i + 3] == 0 && data[i + 4] == 'I' && data[i + 5] == 'E' &&
        data[i + 6] == 'N' && data[i + 7] == 'D') {
      return i + 12;
    }
  }
  return size;
}

// Convert PNG bytes to CF_DIB (BITMAPINFOHEADER + 32bpp top-down pixels).
// Returns nullptr on failure; caller must SetClipboardData or GlobalFree.
HGLOBAL ConvertPngToDib(const uint8_t* png_data, size_t png_size) {
  if (!png_data || png_size == 0) return nullptr;

  Gdiplus::GdiplusStartupInput gdiplusStartupInput;
  ULONG_PTR gdiplusToken = 0;
  if (Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, nullptr) !=
      Gdiplus::Ok) {
    return nullptr;
  }

  HGLOBAL result = nullptr;
  HGLOBAL hpng = GlobalAlloc(GMEM_MOVEABLE, png_size);
  if (hpng) {
    void* locked = GlobalLock(hpng);
    if (locked) {
      std::memcpy(locked, png_data, png_size);
      GlobalUnlock(hpng);
      IStream* stream = nullptr;
      // TRUE: stream owns and frees hpng on Release.
      if (CreateStreamOnHGlobal(hpng, TRUE, &stream) == S_OK && stream) {
        hpng = nullptr;
        std::unique_ptr<Gdiplus::Bitmap> bitmap(
            Gdiplus::Bitmap::FromStream(stream));
        stream->Release();

        if (bitmap && bitmap->GetLastStatus() == Gdiplus::Ok) {
          const UINT width = bitmap->GetWidth();
          const UINT height = bitmap->GetHeight();
          if (width > 0 && height > 0) {
            Gdiplus::Bitmap converted(width, height, PixelFormat32bppARGB);
            {
              Gdiplus::Graphics graphics(&converted);
              graphics.DrawImage(bitmap.get(), 0, 0,
                                 static_cast<INT>(width),
                                 static_cast<INT>(height));
            }

            Gdiplus::BitmapData data = {};
            Gdiplus::Rect rect(0, 0, static_cast<INT>(width),
                               static_cast<INT>(height));
            if (converted.LockBits(&rect, Gdiplus::ImageLockModeRead,
                                   PixelFormat32bppARGB, &data) ==
                Gdiplus::Ok) {
              const size_t row_bytes =
                  ((static_cast<size_t>(width) * 4u + 3u) / 4u) * 4u;
              const size_t image_size = row_bytes * height;
              const size_t total = sizeof(BITMAPINFOHEADER) + image_size;
              HGLOBAL hdib = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total);
              if (hdib) {
                auto* bih = static_cast<BITMAPINFOHEADER*>(GlobalLock(hdib));
                if (bih) {
                  bih->biSize = sizeof(BITMAPINFOHEADER);
                  bih->biWidth = static_cast<LONG>(width);
                  // Negative height => top-down DIB matching GDI+ scan order.
                  bih->biHeight = -static_cast<LONG>(height);
                  bih->biPlanes = 1;
                  bih->biBitCount = 32;
                  bih->biCompression = BI_RGB;
                  bih->biSizeImage = static_cast<DWORD>(image_size);

                  auto* dest = reinterpret_cast<uint8_t*>(bih + 1);
                  const auto* src = static_cast<const uint8_t*>(data.Scan0);
                  for (UINT y = 0; y < height; ++y) {
                    std::memcpy(
                        dest + y * row_bytes,
                        src + static_cast<size_t>(y) *
                                  static_cast<size_t>(
                                      data.Stride < 0 ? -data.Stride
                                                      : data.Stride),
                        static_cast<size_t>(width) * 4u);
                  }
                  GlobalUnlock(hdib);
                  result = hdib;
                } else {
                  GlobalFree(hdib);
                }
              }
              converted.UnlockBits(&data);
            }
          }
        }
      } else if (hpng) {
        GlobalFree(hpng);
        hpng = nullptr;
      }
    } else {
      GlobalFree(hpng);
    }
  }

  Gdiplus::GdiplusShutdown(gdiplusToken);
  return result;
}

// Save a GDI+ Bitmap to PNG bytes (trimmed at IEND).
std::vector<uint8_t> SaveBitmapToPng(Gdiplus::Bitmap* bitmap) {
  std::vector<uint8_t> png_bytes;
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) return png_bytes;

  CLSID png_clsid = {0x557cf406,
                     0x1a04,
                     0x11d3,
                     {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK || !stream) {
    return png_bytes;
  }
  if (bitmap->Save(stream, &png_clsid, nullptr) == Gdiplus::Ok) {
    HGLOBAL hstream_mem = nullptr;
    if (GetHGlobalFromStream(stream, &hstream_mem) == S_OK && hstream_mem) {
      SIZE_T stream_size = GlobalSize(hstream_mem);
      void* stream_ptr = GlobalLock(hstream_mem);
      if (stream_ptr && stream_size > 0) {
        const auto* sp = static_cast<const uint8_t*>(stream_ptr);
        const size_t eff = EffectivePngSize(sp, stream_size);
        png_bytes.assign(sp, sp + eff);
        GlobalUnlock(hstream_mem);
      }
    }
  }
  stream->Release();
  return png_bytes;
}

// Convert an HBITMAP (e.g. CF_BITMAP) to PNG. Does not delete hbmp.
// BitBlt into a 32bpp DIB section is the most reliable path for clipboard
// DDBs (PrintScreen); Bitmap::FromHBITMAP is unreliable for many DDBs.
std::vector<uint8_t> ConvertHBitmapToPng(HBITMAP hbmp) {
  std::vector<uint8_t> png_bytes;
  if (!hbmp) return png_bytes;

  BITMAP bm = {};
  if (GetObject(hbmp, sizeof(bm), &bm) == 0 || bm.bmWidth <= 0 ||
      bm.bmHeight <= 0) {
    return png_bytes;
  }
  if (bm.bmWidth > 16384 || bm.bmHeight > 16384) {
    return png_bytes;
  }

  const int width = bm.bmWidth;
  const int height = bm.bmHeight;
  const size_t stride = static_cast<size_t>(width) * 4u;
  const size_t pixel_bytes = stride * static_cast<size_t>(height);

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  bmi.bmiHeader.biSizeImage = static_cast<DWORD>(pixel_bytes);

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return png_bytes;

  void* section_bits = nullptr;
  HBITMAP section = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS,
                                     &section_bits, nullptr, 0);
  if (!section || !section_bits) {
    if (section) DeleteObject(section);
    ReleaseDC(nullptr, screen_dc);
    return png_bytes;
  }

  HDC src_dc = CreateCompatibleDC(screen_dc);
  HDC dst_dc = CreateCompatibleDC(screen_dc);
  bool blt_ok = false;
  if (src_dc && dst_dc) {
    HGDIOBJ old_src = SelectObject(src_dc, hbmp);
    HGDIOBJ old_dst = SelectObject(dst_dc, section);
    blt_ok = BitBlt(dst_dc, 0, 0, width, height, src_dc, 0, 0, SRCCOPY) != 0;
    SelectObject(src_dc, old_src);
    SelectObject(dst_dc, old_dst);
  }
  if (src_dc) DeleteDC(src_dc);
  if (dst_dc) DeleteDC(dst_dc);
  ReleaseDC(nullptr, screen_dc);

  if (!blt_ok) {
    DeleteObject(section);
    return png_bytes;
  }

  std::vector<uint8_t> pixels(
      static_cast<const uint8_t*>(section_bits),
      static_cast<const uint8_t*>(section_bits) + pixel_bytes);
  DeleteObject(section);

  Gdiplus::GdiplusStartupInput gdiplusStartupInput;
  ULONG_PTR gdiplusToken = 0;
  if (Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, nullptr) !=
      Gdiplus::Ok) {
    return png_bytes;
  }

  {
    Gdiplus::Bitmap bitmap(width, height, static_cast<INT>(stride),
                           PixelFormat32bppARGB, pixels.data());
    if (bitmap.GetLastStatus() == Gdiplus::Ok) {
      png_bytes = SaveBitmapToPng(&bitmap);
    }
  }

  Gdiplus::GdiplusShutdown(gdiplusToken);
  return png_bytes;
}

// Color-table / mask bytes that follow biSize for a CF_DIB payload.
size_t DibColorTableBytes(const BITMAPINFOHEADER* bih) {
  if (!bih) return 0;
  if (bih->biBitCount <= 8) {
    const DWORD colors =
        bih->biClrUsed ? bih->biClrUsed : (1u << bih->biBitCount);
    return colors * sizeof(RGBQUAD);
  }
  // Masks are embedded inside BITMAPV4/V5 headers; only classic INFOHEADER
  // carries 3 DWORDs after biSize for BI_BITFIELDS.
  if (bih->biCompression == BI_BITFIELDS &&
      bih->biSize == sizeof(BITMAPINFOHEADER)) {
    return 3 * sizeof(DWORD);
  }
  return 0;
}

// Convert CF_DIB / CF_DIBV5 global memory to PNG.
// Avoids Gdiplus::Bitmap::FromBITMAPINFO on clipboard memory (AVs on common
// screenshot DIBs: 32bpp BI_RGB, BITMAPV5HEADER, BI_BITFIELDS).
std::vector<uint8_t> ConvertDibToPng(HGLOBAL hdib) {
  std::vector<uint8_t> png_bytes;
  if (!hdib) return png_bytes;

  const SIZE_T total_size = GlobalSize(hdib);
  void* dib_ptr = GlobalLock(hdib);
  if (!dib_ptr || total_size < sizeof(BITMAPINFOHEADER)) {
    if (dib_ptr) GlobalUnlock(hdib);
    return png_bytes;
  }

  // Copy out of clipboard memory before unlocking - GDI must not touch the
  // clipboard HGLOBAL after we return / unlock.
  std::vector<uint8_t> dib_copy(
      static_cast<const uint8_t*>(dib_ptr),
      static_cast<const uint8_t*>(dib_ptr) + total_size);
  GlobalUnlock(hdib);

  auto* bih = reinterpret_cast<BITMAPINFOHEADER*>(dib_copy.data());
  if (bih->biSize < sizeof(BITMAPINFOHEADER) || bih->biSize > dib_copy.size() ||
      bih->biWidth <= 0 || bih->biHeight == 0 || bih->biPlanes != 1) {
    return png_bytes;
  }

  const LONG abs_h = bih->biHeight < 0 ? -bih->biHeight : bih->biHeight;
  // Guard against corrupt / hostile headers that would OOM or AV.
  if (bih->biWidth > 16384 || abs_h > 16384) {
    return png_bytes;
  }

  const size_t color_table = DibColorTableBytes(bih);
  const size_t bits_offset = static_cast<size_t>(bih->biSize) + color_table;
  if (bits_offset >= dib_copy.size()) {
    return png_bytes;
  }
  void* bits = dib_copy.data() + bits_offset;
  auto* bmi = reinterpret_cast<BITMAPINFO*>(dib_copy.data());

  HDC hdc = GetDC(nullptr);
  if (!hdc) return png_bytes;

  HBITMAP hbmp =
      CreateDIBitmap(hdc, bih, CBM_INIT, bits, bmi, DIB_RGB_COLORS);

  if (!hbmp) {
    const int width = static_cast<int>(bih->biWidth);
    const int height = static_cast<int>(abs_h);
    HDC mem_dc = CreateCompatibleDC(hdc);
    if (mem_dc) {
      hbmp = CreateCompatibleBitmap(hdc, width, height);
      if (hbmp) {
        HGDIOBJ old = SelectObject(mem_dc, hbmp);
        const int copied =
            SetDIBits(mem_dc, hbmp, 0, height, bits, bmi, DIB_RGB_COLORS);
        SelectObject(mem_dc, old);
        if (copied == 0) {
          DeleteObject(hbmp);
          hbmp = nullptr;
        }
      }
      DeleteDC(mem_dc);
    }
  }

  ReleaseDC(nullptr, hdc);

  if (!hbmp) {
    return png_bytes;
  }

  png_bytes = ConvertHBitmapToPng(hbmp);
  DeleteObject(hbmp);
  return png_bytes;
}

}  // namespace

// static
void XueHuaNaviteClipboardPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<XueHuaNaviteClipboardPlugin>(registrar);
  ClipboardHostApi::SetUp(registrar->messenger(), plugin.get());
  registrar->AddPlugin(std::move(plugin));
}

XueHuaNaviteClipboardPlugin::XueHuaNaviteClipboardPlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {
  if (registrar_ && registrar_->messenger()) {
    flutter_api_ =
        std::make_unique<ClipboardFlutterApi>(registrar_->messenger());
  }
}

XueHuaNaviteClipboardPlugin::~XueHuaNaviteClipboardPlugin() {
  StopClipboardListening();
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

std::optional<FlutterError>
XueHuaNaviteClipboardPlugin::StartClipboardListening() {
  StopClipboardListening();
  is_listening_ = true;
  last_sequence_number_ = GetClipboardSequenceNumber();

  HWND hwnd = GetTargetWindow();
  if (!hwnd || !registrar_) {
    return std::nullopt;
  }

  if (AddClipboardFormatListener(hwnd)) {
    listening_hwnd_ = hwnd;
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND /*hWnd*/, UINT message, WPARAM /*wParam*/,
               LPARAM /*lParam*/) -> std::optional<LRESULT> {
          if (message == WM_CLIPBOARDUPDATE && is_listening_ && flutter_api_) {
            DWORD seq = GetClipboardSequenceNumber();
            if (seq != last_sequence_number_) {
              last_sequence_number_ = seq;
              auto now_ms =
                  std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();
              flutter_api_->OnClipboardChanged(
                  WireClipboardChangeEvent(
                      WireClipboardBuffer::kGeneral,
                      static_cast<int64_t>(seq),
                      static_cast<int64_t>(now_ms)),
                  []() {},
                  [](const FlutterError& /*error*/) {});
            }
          }
          return std::nullopt;
        });
  }
  return std::nullopt;
}

std::optional<FlutterError>
XueHuaNaviteClipboardPlugin::StopClipboardListening() {
  is_listening_ = false;
  if (window_proc_id_ != -1 && registrar_) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    window_proc_id_ = -1;
  }
  if (listening_hwnd_) {
    RemoveClipboardFormatListener(listening_hwnd_);
    listening_hwnd_ = nullptr;
  }
  return std::nullopt;
}

ErrorOr<bool> XueHuaNaviteClipboardPlugin::WriteItems(
    const ::flutter::EncodableList& items,
    const WireClipboardWriteOptions& options) {
  if (items.empty()) {
    return false;
  }

  const auto* custom_val = std::get_if<flutter::CustomEncodableValue>(&items[0]);
  if (!custom_val || custom_val->type() != typeid(WireClipboardItem)) {
    return false;
  }
  const auto& item = std::any_cast<const WireClipboardItem&>(*custom_val);

  const bool is_sensitive = options.is_sensitive();
  const bool is_transient = options.is_transient();
  const bool local_only = options.local_only();

  ScopedClipboard clip(GetTargetWindow());
  if (!clip.IsOpen()) {
    return FlutterError("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
  }
  EmptyClipboard();

  // 1. Plain text
  if (const std::string* plain_text = item.plain_text()) {
    std::wstring wide = Utf8ToWide(*plain_text);
    WriteGlobalBytes(CF_UNICODETEXT, wide.c_str(),
                     (wide.size() + 1) * sizeof(wchar_t));
  }

  // 2. HTML Format
  if (const std::string* html = item.html()) {
    UINT cf_html = RegisterClipboardFormatW(L"HTML Format");
    if (cf_html != 0) {
      std::string payload = BuildCfHtmlPayload(*html);
      WriteGlobalBytes(cf_html, payload.c_str(), payload.size() + 1);
    }
  }

  // 3. Rich Text Format (RTF)
  if (const std::vector<uint8_t>* rtf_bytes = item.rtf_bytes()) {
    UINT cf_rtf = RegisterClipboardFormatW(L"Rich Text Format");
    if (cf_rtf != 0 && !rtf_bytes->empty()) {
      WriteGlobalBytes(cf_rtf, rtf_bytes->data(), rtf_bytes->size());
    }
  }

  // 4. Markdown
  if (const std::string* md = item.markdown()) {
    UINT cf_md = RegisterClipboardFormatW(L"text/markdown");
    if (cf_md != 0) {
      WriteGlobalBytes(cf_md, md->c_str(), md->size() + 1);
    }
  }

  // 5. URI / URL
  if (const std::string* uri = item.uri()) {
    UINT cf_url = RegisterClipboardFormatW(L"UniformResourceLocatorW");
    if (cf_url != 0) {
      std::wstring wide_url = Utf8ToWide(*uri);
      WriteGlobalBytes(cf_url, wide_url.c_str(),
                       (wide_url.size() + 1) * sizeof(wchar_t));
    }
  }

  // 6. Image (PNG + CF_DIB so Paint/Office/etc. can paste)
  if (const std::vector<uint8_t>* img_bytes = item.image_bytes()) {
    if (!img_bytes->empty()) {
      UINT cf_png = RegisterClipboardFormatW(L"PNG");
      if (cf_png != 0) {
        WriteGlobalBytes(cf_png, img_bytes->data(), img_bytes->size());
      }
      UINT cf_mime_png = RegisterClipboardFormatW(L"image/png");
      if (cf_mime_png != 0) {
        WriteGlobalBytes(cf_mime_png, img_bytes->data(), img_bytes->size());
      }
      HGLOBAL hdib = ConvertPngToDib(img_bytes->data(), img_bytes->size());
      if (hdib) {
        if (!SetClipboardData(CF_DIB, hdib)) {
          GlobalFree(hdib);
        }
      }
    }
  }

  // 7. Files (CF_HDROP + Preferred DropEffect)
  if (const ::flutter::EncodableList* files_list = item.files()) {
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

      DWORD drop_effect =
          item.file_copy_mode() == WireFileCopyMode::kCut ? DROPEFFECT_MOVE
                                                          : DROPEFFECT_COPY;
      WriteDwordFormat(L"Preferred DropEffect", drop_effect);
    }
  }

  // 8. Color
  if (const int64_t* color_val = item.color_value()) {
    UINT cf_color = RegisterClipboardFormatW(L"application/x-color");
    if (cf_color != 0) {
      WriteGlobalBytes(cf_color, color_val, sizeof(int64_t));
    }
  }

  // 9. Custom Formats
  if (const ::flutter::EncodableList* custom_list = item.custom_formats()) {
    for (const auto& entry_val : *custom_list) {
      const auto* entry_custom =
          std::get_if<flutter::CustomEncodableValue>(&entry_val);
      if (!entry_custom ||
          entry_custom->type() != typeid(WireCustomFormatEntry)) {
        continue;
      }
      const auto& entry =
          std::any_cast<const WireCustomFormatEntry&>(*entry_custom);
      if (!entry.format().empty()) {
        UINT cf_custom =
            RegisterClipboardFormatW(Utf8ToWide(entry.format()).c_str());
        if (cf_custom != 0) {
          WriteGlobalBytes(cf_custom, entry.data().data(), entry.data().size());
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

  return true;
}

ErrorOr<::flutter::EncodableList> XueHuaNaviteClipboardPlugin::ReadItems(
    const WireClipboardReadOptions& options) {
  ScopedClipboard clip(GetTargetWindow());
  if (!clip.IsOpen()) {
    return FlutterError("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
  }

  WireClipboardItem item(WireFileCopyMode::kCopy);
  bool has_any = false;

  // 1. Plain Text
  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE hdata = GetClipboardData(CF_UNICODETEXT);
    if (hdata) {
      const wchar_t* wstr = static_cast<const wchar_t*>(GlobalLock(hdata));
      if (wstr) {
        item.set_plain_text(WideToUtf8(wstr));
        has_any = true;
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
        item.set_html(ParseCfHtmlPayload(raw_html));
        has_any = true;
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
        while (sz > 0 && ptr[sz - 1] == 0) --sz;
        item.set_rtf_bytes(std::vector<uint8_t>(ptr, ptr + sz));
        has_any = true;
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
        item.set_markdown(std::string(cstr, len));
        has_any = true;
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
        item.set_uri(WideToUtf8(wstr));
        has_any = true;
        GlobalUnlock(hdata);
      }
    }
  }

  // 6. Image (Prefer PNG, then CF_BITMAP, then CF_DIB / CF_DIBV5)
  UINT cf_png = RegisterClipboardFormatW(L"PNG");
  UINT cf_mime_png = RegisterClipboardFormatW(L"image/png");
  std::vector<uint8_t> image_bytes;
  if (cf_png != 0 && IsClipboardFormatAvailable(cf_png)) {
    HANDLE hdata = GetClipboardData(cf_png);
    if (hdata) {
      const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
      size_t sz = GlobalSize(hdata);
      if (ptr && sz > 0) {
        sz = EffectivePngSize(ptr, sz);
        image_bytes.assign(ptr, ptr + sz);
      }
      GlobalUnlock(hdata);
    }
  }
  if (image_bytes.empty() && cf_mime_png != 0 &&
      IsClipboardFormatAvailable(cf_mime_png)) {
    HANDLE hdata = GetClipboardData(cf_mime_png);
    if (hdata) {
      const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
      size_t sz = GlobalSize(hdata);
      if (ptr && sz > 0) {
        sz = EffectivePngSize(ptr, sz);
        image_bytes.assign(ptr, ptr + sz);
      }
      GlobalUnlock(hdata);
    }
  }
  if (image_bytes.empty() && IsClipboardFormatAvailable(CF_BITMAP)) {
    HANDLE hbm = GetClipboardData(CF_BITMAP);
    if (hbm) {
      image_bytes = ConvertHBitmapToPng(static_cast<HBITMAP>(hbm));
    }
  }
  if (image_bytes.empty() && IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hdib = GetClipboardData(CF_DIB);
    if (hdib) {
      image_bytes = ConvertDibToPng(hdib);
    }
  }
  if (image_bytes.empty() && IsClipboardFormatAvailable(CF_DIBV5)) {
    HANDLE hdib = GetClipboardData(CF_DIBV5);
    if (hdib) {
      image_bytes = ConvertDibToPng(hdib);
    }
  }

  if (!image_bytes.empty()) {
    item.set_image_bytes(image_bytes);
    item.set_image_mime_type("image/png");
    has_any = true;
  }

  // 7. Files (CF_HDROP + Preferred DropEffect)
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hdrop = GetClipboardData(CF_HDROP);
    if (hdrop) {
      HDROP drop = static_cast<HDROP>(GlobalLock(hdrop));
      if (drop) {
        UINT file_count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        ::flutter::EncodableList files;
        for (UINT i = 0; i < file_count; ++i) {
          UINT char_len = DragQueryFileW(drop, i, nullptr, 0);
          if (char_len > 0) {
            std::wstring wpath(static_cast<size_t>(char_len) + 1, L'\0');
            DragQueryFileW(drop, i, wpath.data(), char_len + 1);
            wpath.resize(char_len);
            files.push_back(::flutter::EncodableValue(WideToUtf8(wpath)));
          }
        }
        GlobalUnlock(hdrop);
        if (!files.empty()) {
          item.set_files(files);
          has_any = true;
        }
      }
    }

    WireFileCopyMode copy_mode = WireFileCopyMode::kCopy;
    UINT cf_effect = RegisterClipboardFormatW(L"Preferred DropEffect");
    if (cf_effect != 0 && IsClipboardFormatAvailable(cf_effect)) {
      HANDLE heffect = GetClipboardData(cf_effect);
      if (heffect && GlobalSize(heffect) >= sizeof(DWORD)) {
        const DWORD* effect_ptr =
            static_cast<const DWORD*>(GlobalLock(heffect));
        if (effect_ptr) {
          if ((*effect_ptr & DROPEFFECT_MOVE) != 0) {
            copy_mode = WireFileCopyMode::kCut;
          }
          GlobalUnlock(heffect);
        }
      }
    }
    item.set_file_copy_mode(copy_mode);
  }

  // 8. Color
  UINT cf_color = RegisterClipboardFormatW(L"application/x-color");
  if (cf_color != 0 && IsClipboardFormatAvailable(cf_color)) {
    HANDLE hdata = GetClipboardData(cf_color);
    if (hdata && GlobalSize(hdata) >= sizeof(int64_t)) {
      const int64_t* cptr = static_cast<const int64_t*>(GlobalLock(hdata));
      if (cptr) {
        item.set_color_value(*cptr);
        has_any = true;
        GlobalUnlock(hdata);
      }
    }
  }

  // 9. Requested Custom Formats
  ::flutter::EncodableList custom_entries;
  for (const auto& fmt_entry : options.requested_custom_formats()) {
    if (const auto* fmt_name = std::get_if<std::string>(&fmt_entry)) {
      UINT cf_custom = RegisterClipboardFormatW(Utf8ToWide(*fmt_name).c_str());
      if (cf_custom != 0 && IsClipboardFormatAvailable(cf_custom)) {
        HANDLE hdata = GetClipboardData(cf_custom);
        if (hdata) {
          const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hdata));
          size_t sz = GlobalSize(hdata);
          if (ptr && sz > 0) {
            std::vector<uint8_t> bytes(ptr, ptr + sz);
            custom_entries.push_back(
                ::flutter::CustomEncodableValue(
                    WireCustomFormatEntry(*fmt_name, bytes)));
            has_any = true;
          }
          GlobalUnlock(hdata);
        }
      }
    }
  }
  if (!custom_entries.empty()) {
    item.set_custom_formats(custom_entries);
  }

  ::flutter::EncodableList items_out;
  if (has_any) {
    items_out.push_back(::flutter::CustomEncodableValue(item));
  }
  return items_out;
}

void XueHuaNaviteClipboardPlugin::GetMetadata(
    const WireClipboardBufferTarget& /*target*/,
    bool /*detect_patterns*/,
    std::function<void(ErrorOr<WireClipboardMetadata> reply)> result) {
  DWORD seq = GetClipboardSequenceNumber();
  ScopedClipboard clip(GetTargetWindow());

  ::flutter::EncodableList raw_formats;
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
  UINT cf_mime_png_meta = RegisterClipboardFormatW(L"image/png");
  bool has_image =
      (cf_png != 0 && IsClipboardFormatAvailable(cf_png)) ||
      (cf_mime_png_meta != 0 &&
       IsClipboardFormatAvailable(cf_mime_png_meta)) ||
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
        raw_formats.push_back(::flutter::EncodableValue(
            WideToUtf8(std::wstring(name_buf, static_cast<size_t>(len)))));
      } else {
        switch (fmt) {
          case CF_UNICODETEXT:
            raw_formats.push_back(::flutter::EncodableValue("CF_UNICODETEXT"));
            break;
          case CF_BITMAP:
            raw_formats.push_back(::flutter::EncodableValue("CF_BITMAP"));
            break;
          case CF_DIB:
            raw_formats.push_back(::flutter::EncodableValue("CF_DIB"));
            break;
          case CF_DIBV5:
            raw_formats.push_back(::flutter::EncodableValue("CF_DIBV5"));
            break;
          case CF_HDROP:
            raw_formats.push_back(::flutter::EncodableValue("CF_HDROP"));
            break;
          default:
            break;
        }
      }
    }
  }

  bool any_item = has_text || has_html || has_rtf || has_md || has_uri ||
                  has_image || has_files || has_color || !raw_formats.empty();

  WireClipboardMetadata meta(
      static_cast<int64_t>(seq),
      nullptr,
      any_item ? 1 : 0,
      has_text,
      has_html,
      has_rtf,
      has_md,
      has_uri,
      has_image,
      has_files,
      has_color,
      raw_formats,
      ::flutter::EncodableList());
  result(meta);
}

ErrorOr<int64_t> XueHuaNaviteClipboardPlugin::GetChangeCount(
    const WireClipboardBufferTarget& /*target*/) {
  DWORD seq = GetClipboardSequenceNumber();
  return static_cast<int64_t>(seq);
}

ErrorOr<bool> XueHuaNaviteClipboardPlugin::Clear(
    const WireClipboardBufferTarget& /*target*/) {
  ScopedClipboard clip(GetTargetWindow());
  if (!clip.IsOpen()) {
    return FlutterError("CLIPBOARD_BUSY", "Failed to open Windows clipboard.");
  }
  EmptyClipboard();
  return true;
}

std::optional<FlutterError> XueHuaNaviteClipboardPlugin::SetPollingInterval(
    int64_t /*interval_ms*/) {
  return std::nullopt;
}

}  // namespace xue_hua_navite_clipboard
