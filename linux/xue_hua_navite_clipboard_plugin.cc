#include "include/xue_hua_navite_clipboard/xue_hua_navite_clipboard_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>

#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "clipboard_api.g.h"
#include "xue_hua_navite_clipboard_plugin_private.h"

#define XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), xue_hua_navite_clipboard_plugin_get_type(), \
                              XueHuaNaviteClipboardPlugin))

namespace {

struct StoredClipboardPayload {
  std::map<std::string, std::vector<uint8_t>> target_bytes;
};

}  // namespace

struct _XueHuaNaviteClipboardPlugin {
  GObject parent_instance;
  ClipboardClipboardFlutterApi* flutter_api;
  bool is_listening;
  gulong clipboard_signal_id;
  gulong primary_signal_id;
  int64_t general_change_count;
  int64_t primary_change_count;
};

G_DEFINE_TYPE(XueHuaNaviteClipboardPlugin, xue_hua_navite_clipboard_plugin,
              g_object_get_type())

static GtkClipboard* resolve_gtk_clipboard(ClipboardWireClipboardBuffer buffer) {
  if (buffer ==
      XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_PRIMARY_SELECTION) {
    return gtk_clipboard_get(GDK_SELECTION_PRIMARY);
  }
  return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

static void clipboard_get_func(GtkClipboard* /*clipboard*/,
                               GtkSelectionData* selection_data,
                               guint /*info*/,
                               gpointer user_data) {
  auto* payload = static_cast<StoredClipboardPayload*>(user_data);
  if (!payload) return;

  GdkAtom target = gtk_selection_data_get_target(selection_data);
  g_autofree gchar* target_name = gdk_atom_name(target);
  if (!target_name) return;

  auto it = payload->target_bytes.find(target_name);
  if (it != payload->target_bytes.end()) {
    gtk_selection_data_set(selection_data, target, 8, it->second.data(),
                           static_cast<gint>(it->second.size()));
  }
}

static void clipboard_clear_func(GtkClipboard* /*clipboard*/,
                                 gpointer user_data) {
  auto* payload = static_cast<StoredClipboardPayload*>(user_data);
  delete payload;
}

static void on_gtk_owner_change(GtkClipboard* clipboard,
                                GdkEvent* /*event*/,
                                gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self =
      XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  if (!self->is_listening || !self->flutter_api) return;

  bool is_primary = (clipboard == gtk_clipboard_get(GDK_SELECTION_PRIMARY));
  int64_t count = is_primary ? (++self->primary_change_count)
                             : (++self->general_change_count);
  int64_t now_ms = g_get_real_time() / 1000;

  ClipboardWireClipboardBuffer wire_buffer =
      is_primary
          ? XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_PRIMARY_SELECTION
          : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;

  g_autoptr(ClipboardWireClipboardChangeEvent) change_event =
      clipboard_wire_clipboard_change_event_new(wire_buffer, count, now_ms);
  clipboard_clipboard_flutter_api_on_clipboard_changed(
      self->flutter_api, change_event, nullptr, nullptr, nullptr);
}

static void start_native_listening(XueHuaNaviteClipboardPlugin* self) {
  if (self->is_listening) return;
  self->is_listening = true;

  GtkClipboard* general_cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  self->clipboard_signal_id = g_signal_connect(
      general_cb, "owner-change", G_CALLBACK(on_gtk_owner_change), self);

  GtkClipboard* primary_cb = gtk_clipboard_get(GDK_SELECTION_PRIMARY);
  self->primary_signal_id = g_signal_connect(
      primary_cb, "owner-change", G_CALLBACK(on_gtk_owner_change), self);
}

static void stop_native_listening(XueHuaNaviteClipboardPlugin* self) {
  if (!self->is_listening) return;
  self->is_listening = false;

  if (self->clipboard_signal_id != 0) {
    GtkClipboard* general_cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    g_signal_handler_disconnect(general_cb, self->clipboard_signal_id);
    self->clipboard_signal_id = 0;
  }
  if (self->primary_signal_id != 0) {
    GtkClipboard* primary_cb = gtk_clipboard_get(GDK_SELECTION_PRIMARY);
    g_signal_handler_disconnect(primary_cb, self->primary_signal_id);
    self->primary_signal_id = 0;
  }
}

static ClipboardClipboardHostApiWriteItemsResponse* handle_write_items(
    FlValue* items,
    ClipboardWireClipboardWriteOptions* options,
    gpointer /*user_data*/) {
  if (!items || fl_value_get_type(items) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(items) == 0) {
    return clipboard_clipboard_host_api_write_items_response_new(FALSE);
  }

  FlValue* first_val = fl_value_get_list_value(items, 0);
  if (!first_val || fl_value_get_type(first_val) != FL_VALUE_TYPE_CUSTOM ||
      fl_value_get_custom_type(first_val) !=
          clipboard_wire_clipboard_item_type_id) {
    return clipboard_clipboard_host_api_write_items_response_new(FALSE);
  }
  ClipboardWireClipboardItem* first_item = CLIPBOARD_WIRE_CLIPBOARD_ITEM(
      fl_value_get_custom_value_object(first_val));
  if (!first_item) {
    return clipboard_clipboard_host_api_write_items_response_new(FALSE);
  }

  ClipboardWireClipboardBuffer buffer =
      options ? clipboard_wire_clipboard_write_options_get_buffer(options)
              : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;
  gboolean is_sensitive =
      options ? clipboard_wire_clipboard_write_options_get_is_sensitive(options)
              : FALSE;

  auto* payload = new StoredClipboardPayload();
  auto add_str_target = [&](const char* target, const char* str) {
    size_t len = strlen(str);
    payload->target_bytes[target] =
        std::vector<uint8_t>(reinterpret_cast<const uint8_t*>(str),
                             reinterpret_cast<const uint8_t*>(str) + len);
  };
  auto add_bytes_target = [&](const char* target, const uint8_t* ptr,
                              size_t len) {
    payload->target_bytes[target] = std::vector<uint8_t>(ptr, ptr + len);
  };

  if (const gchar* text =
          clipboard_wire_clipboard_item_get_plain_text(first_item)) {
    add_str_target("UTF8_STRING", text);
    add_str_target("STRING", text);
    add_str_target("text/plain;charset=utf-8", text);
    add_str_target("text/plain", text);
  }

  if (const gchar* html = clipboard_wire_clipboard_item_get_html(first_item)) {
    add_str_target("text/html", html);
  }

  size_t rtf_len = 0;
  if (const uint8_t* rtf_bytes =
          clipboard_wire_clipboard_item_get_rtf_bytes(first_item, &rtf_len)) {
    if (rtf_len > 0) {
      add_bytes_target("text/rtf", rtf_bytes, rtf_len);
      add_bytes_target("application/rtf", rtf_bytes, rtf_len);
    }
  }

  if (const gchar* md =
          clipboard_wire_clipboard_item_get_markdown(first_item)) {
    add_str_target("text/markdown", md);
  }

  if (const gchar* uri = clipboard_wire_clipboard_item_get_uri(first_item)) {
    add_str_target("text/uri-list", uri);
  }

  size_t img_len = 0;
  if (const uint8_t* img_bytes =
          clipboard_wire_clipboard_item_get_image_bytes(first_item, &img_len)) {
    if (img_len > 0) {
      add_bytes_target("image/png", img_bytes, img_len);
    }
  }

  FlValue* files_val = clipboard_wire_clipboard_item_get_files(first_item);
  if (files_val && fl_value_get_type(files_val) == FL_VALUE_TYPE_LIST &&
      fl_value_get_length(files_val) > 0) {
    const gchar* mode =
        clipboard_wire_clipboard_item_get_file_copy_mode(first_item) ==
                XUE_HUA_NAVITE_CLIPBOARD_WIRE_FILE_COPY_MODE_CUT
            ? "cut"
            : "copy";

    std::string uri_list_str;
    std::string gnome_str(mode);
    size_t n = fl_value_get_length(files_val);
    for (size_t i = 0; i < n; ++i) {
      FlValue* f = fl_value_get_list_value(files_val, i);
      if (f && fl_value_get_type(f) == FL_VALUE_TYPE_STRING) {
        std::string p = fl_value_get_string(f);
        std::string file_uri =
            (p.rfind("file://", 0) == 0) ? p : ("file://" + p);
        uri_list_str += file_uri + "\r\n";
        gnome_str += "\n" + file_uri;
      }
    }
    add_str_target("text/uri-list", uri_list_str.c_str());
    add_str_target("x-special/gnome-copied-files", gnome_str.c_str());
    add_str_target("x-special/mate-copied-files", gnome_str.c_str());
  }

  if (int64_t* color_ptr =
          clipboard_wire_clipboard_item_get_color_value(first_item)) {
    int64_t c = *color_ptr;
    add_bytes_target("application/x-color",
                     reinterpret_cast<const uint8_t*>(&c), sizeof(int64_t));
  }

  FlValue* custom_val =
      clipboard_wire_clipboard_item_get_custom_formats(first_item);
  if (custom_val && fl_value_get_type(custom_val) == FL_VALUE_TYPE_LIST) {
    size_t list_len = fl_value_get_length(custom_val);
    for (size_t i = 0; i < list_len; ++i) {
      FlValue* entry_val = fl_value_get_list_value(custom_val, i);
      if (entry_val && fl_value_get_type(entry_val) == FL_VALUE_TYPE_CUSTOM &&
          fl_value_get_custom_type(entry_val) ==
              clipboard_wire_custom_format_entry_type_id) {
        ClipboardWireCustomFormatEntry* entry =
            CLIPBOARD_WIRE_CUSTOM_FORMAT_ENTRY(
                fl_value_get_custom_value_object(entry_val));
        if (entry) {
          const gchar* fmt =
              clipboard_wire_custom_format_entry_get_format(entry);
          size_t data_len = 0;
          const uint8_t* data =
              clipboard_wire_custom_format_entry_get_data(entry, &data_len);
          if (fmt && data && data_len > 0) {
            add_bytes_target(fmt, data, data_len);
          }
        }
      }
    }
  }

  if (payload->target_bytes.empty()) {
    delete payload;
    return clipboard_clipboard_host_api_write_items_response_new(FALSE);
  }

  std::vector<GtkTargetEntry> entries;
  entries.reserve(payload->target_bytes.size());
  guint idx = 0;
  for (const auto& kv : payload->target_bytes) {
    GtkTargetEntry entry;
    entry.target = const_cast<gchar*>(kv.first.c_str());
    entry.flags = 0;
    entry.info = idx++;
    entries.push_back(entry);
  }

  GtkClipboard* cb = resolve_gtk_clipboard(buffer);
  gboolean ok = gtk_clipboard_set_with_data(
      cb, entries.data(), static_cast<guint>(entries.size()),
      clipboard_get_func, clipboard_clear_func, payload);

  if (ok && !is_sensitive) {
    gtk_clipboard_set_can_store(cb, entries.data(),
                                static_cast<gint>(entries.size()));
  } else if (!ok) {
    delete payload;
  }

  return clipboard_clipboard_host_api_write_items_response_new(ok);
}

static ClipboardClipboardHostApiReadItemsResponse* handle_read_items(
    ClipboardWireClipboardReadOptions* options,
    gpointer /*user_data*/) {
  ClipboardWireClipboardBuffer buffer =
      options ? clipboard_wire_clipboard_read_options_get_buffer(options)
              : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;
  FlValue* requested_custom =
      options ? clipboard_wire_clipboard_read_options_get_requested_custom_formats(
                    options)
              : nullptr;

  GtkClipboard* cb = resolve_gtk_clipboard(buffer);
  bool has_any = false;

  bool has_plain_text = false;
  std::string plain_text;
  g_autofree gchar* text = gtk_clipboard_wait_for_text(cb);
  if (text) {
    plain_text = std::string(text);
    has_plain_text = true;
    has_any = true;
  }

  auto read_target_bytes = [&](const char* target_str,
                               std::vector<uint8_t>& out) -> bool {
    GdkAtom atom = gdk_atom_intern(target_str, FALSE);
    GtkSelectionData* sdata = gtk_clipboard_wait_for_contents(cb, atom);
    if (!sdata) return false;
    gint len = gtk_selection_data_get_length(sdata);
    const guchar* data = gtk_selection_data_get_data(sdata);
    bool success = false;
    if (data && len > 0) {
      out.assign(data, data + len);
      success = true;
    }
    gtk_selection_data_free(sdata);
    return success;
  };

  bool has_html = false;
  std::string html_str;
  std::vector<uint8_t> html_bytes;
  if (read_target_bytes("text/html", html_bytes)) {
    html_str = std::string(reinterpret_cast<const char*>(html_bytes.data()),
                           html_bytes.size());
    has_html = true;
    has_any = true;
  }

  std::vector<uint8_t> rtf_bytes;
  bool has_rtf = read_target_bytes("text/rtf", rtf_bytes) ||
                 read_target_bytes("application/rtf", rtf_bytes);
  if (has_rtf) {
    has_any = true;
  }

  bool has_markdown = false;
  std::string markdown_str;
  std::vector<uint8_t> md_bytes;
  if (read_target_bytes("text/markdown", md_bytes)) {
    markdown_str = std::string(reinterpret_cast<const char*>(md_bytes.data()),
                               md_bytes.size());
    has_markdown = true;
    has_any = true;
  }

  std::vector<uint8_t> png_bytes;
  bool has_image = false;
  if (read_target_bytes("image/png", png_bytes)) {
    has_image = true;
    has_any = true;
  } else if (gtk_clipboard_wait_is_image_available(cb)) {
    GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(cb);
    if (pixbuf) {
      gchar* buf = nullptr;
      gsize buf_size = 0;
      if (gdk_pixbuf_save_to_buffer(pixbuf, &buf, &buf_size, "png", nullptr,
                                    nullptr)) {
        const auto* raw = reinterpret_cast<const uint8_t*>(buf);
        png_bytes.assign(raw, raw + buf_size);
        has_image = true;
        has_any = true;
        g_free(buf);
      }
      g_object_unref(pixbuf);
    }
  }

  bool has_uri = false;
  std::string uri_str;
  std::vector<uint8_t> gnome_bytes;
  ClipboardWireFileCopyMode file_copy_mode =
      XUE_HUA_NAVITE_CLIPBOARD_WIRE_FILE_COPY_MODE_COPY;
  g_autoptr(FlValue) files_list = fl_value_new_list();

  if (read_target_bytes("x-special/gnome-copied-files", gnome_bytes) ||
      read_target_bytes("x-special/mate-copied-files", gnome_bytes)) {
    std::string content(reinterpret_cast<const char*>(gnome_bytes.data()),
                        gnome_bytes.size());
    size_t pos = 0;
    bool first_line = true;
    while (pos < content.size()) {
      size_t next = content.find('\n', pos);
      if (next == std::string::npos) next = content.size();
      std::string line = content.substr(pos, next - pos);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (first_line) {
        if (line == "cut") {
          file_copy_mode = XUE_HUA_NAVITE_CLIPBOARD_WIRE_FILE_COPY_MODE_CUT;
        }
        first_line = false;
      } else if (!line.empty()) {
        g_autofree gchar* filename =
            g_filename_from_uri(line.c_str(), nullptr, nullptr);
        if (filename) {
          fl_value_append_take(files_list, fl_value_new_string(filename));
        }
      }
      pos = next + 1;
    }
  } else {
    gchar** uris = gtk_clipboard_wait_for_uris(cb);
    if (uris) {
      for (int i = 0; uris[i] != nullptr; ++i) {
        if (g_str_has_prefix(uris[i], "file://")) {
          g_autofree gchar* filename =
              g_filename_from_uri(uris[i], nullptr, nullptr);
          if (filename) {
            fl_value_append_take(files_list, fl_value_new_string(filename));
          }
        } else if (i == 0) {
          uri_str = std::string(uris[i]);
          has_uri = true;
          has_any = true;
        }
      }
      g_strfreev(uris);
    }
  }

  bool has_files = fl_value_get_length(files_list) > 0;
  if (has_files) {
    has_any = true;
  }

  bool has_color = false;
  int64_t color_val = 0;
  std::vector<uint8_t> color_bytes;
  if (read_target_bytes("application/x-color", color_bytes) &&
      color_bytes.size() >= sizeof(int64_t)) {
    memcpy(&color_val, color_bytes.data(), sizeof(int64_t));
    has_color = true;
    has_any = true;
  }

  g_autoptr(FlValue) custom_entries = fl_value_new_list();
  if (requested_custom &&
      fl_value_get_type(requested_custom) == FL_VALUE_TYPE_LIST) {
    size_t n = fl_value_get_length(requested_custom);
    for (size_t i = 0; i < n; ++i) {
      FlValue* fmt_val = fl_value_get_list_value(requested_custom, i);
      if (fmt_val && fl_value_get_type(fmt_val) == FL_VALUE_TYPE_STRING) {
        const gchar* fmt_name = fl_value_get_string(fmt_val);
        std::vector<uint8_t> cbytes;
        if (fmt_name && read_target_bytes(fmt_name, cbytes) && !cbytes.empty()) {
          g_autoptr(ClipboardWireCustomFormatEntry) entry =
              clipboard_wire_custom_format_entry_new(fmt_name, cbytes.data(),
                                                     cbytes.size());
          fl_value_append_take(
              custom_entries,
              fl_value_new_custom_object(
                  clipboard_wire_custom_format_entry_type_id, G_OBJECT(entry)));
          has_any = true;
        }
      }
    }
  }

  g_autoptr(FlValue) result_list = fl_value_new_list();
  if (has_any) {
    g_autoptr(ClipboardWireClipboardItem) item = clipboard_wire_clipboard_item_new(
        has_plain_text ? plain_text.c_str() : nullptr,
        has_html ? html_str.c_str() : nullptr,
        has_rtf ? rtf_bytes.data() : nullptr,
        has_rtf ? rtf_bytes.size() : 0,
        has_markdown ? markdown_str.c_str() : nullptr,
        has_uri ? uri_str.c_str() : nullptr,
        has_image ? png_bytes.data() : nullptr,
        has_image ? png_bytes.size() : 0,
        "image/png",
        has_files ? files_list : nullptr,
        file_copy_mode,
        has_color ? &color_val : nullptr,
        fl_value_get_length(custom_entries) > 0 ? custom_entries : nullptr);
    fl_value_append_take(
        result_list, fl_value_new_custom_object(
                         clipboard_wire_clipboard_item_type_id, G_OBJECT(item)));
  }

  return clipboard_clipboard_host_api_read_items_response_new(result_list);
}

static void handle_get_metadata(
    ClipboardWireClipboardBufferTarget* target,
    gboolean /*detect_patterns*/,
    ClipboardClipboardHostApiResponseHandle* response_handle,
    gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self =
      XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  ClipboardWireClipboardBuffer buffer =
      target ? clipboard_wire_clipboard_buffer_target_get_buffer(target)
             : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;

  GtkClipboard* cb = resolve_gtk_clipboard(buffer);
  bool is_primary =
      (buffer ==
       XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_PRIMARY_SELECTION);
  int64_t change_count =
      is_primary ? self->primary_change_count : self->general_change_count;

  g_autoptr(FlValue) raw_formats = fl_value_new_list();
  g_autoptr(FlValue) detected_patterns = fl_value_new_list();

  bool has_text = gtk_clipboard_wait_is_text_available(cb) != FALSE;
  bool has_image = gtk_clipboard_wait_is_image_available(cb) != FALSE;
  bool has_uris = gtk_clipboard_wait_is_uris_available(cb) != FALSE;
  bool has_html = false;
  bool has_rtf = false;
  bool has_md = false;
  bool has_files = has_uris;
  bool has_color = false;

  GdkAtom* targets = nullptr;
  gint n_targets = 0;
  if (gtk_clipboard_wait_for_targets(cb, &targets, &n_targets) && targets) {
    for (gint i = 0; i < n_targets; ++i) {
      g_autofree gchar* name = gdk_atom_name(targets[i]);
      if (name) {
        fl_value_append_take(raw_formats, fl_value_new_string(name));
        if (strcmp(name, "text/html") == 0) has_html = true;
        if (strcmp(name, "text/rtf") == 0 ||
            strcmp(name, "application/rtf") == 0) {
          has_rtf = true;
        }
        if (strcmp(name, "text/markdown") == 0) has_md = true;
        if (strcmp(name, "x-special/gnome-copied-files") == 0) has_files = true;
        if (strcmp(name, "application/x-color") == 0) has_color = true;
      }
    }
    g_free(targets);
  }

  g_autoptr(ClipboardWireClipboardMetadata) meta =
      clipboard_wire_clipboard_metadata_new(
          change_count,
          nullptr,
          fl_value_get_length(raw_formats) > 0 ? 1 : 0,
          has_text,
          has_html,
          has_rtf,
          has_md,
          has_uris,
          has_image,
          has_files,
          has_color,
          raw_formats,
          detected_patterns);

  clipboard_clipboard_host_api_respond_get_metadata(response_handle, meta);
}

static ClipboardClipboardHostApiGetChangeCountResponse* handle_get_change_count(
    ClipboardWireClipboardBufferTarget* target,
    gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self =
      XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  ClipboardWireClipboardBuffer buffer =
      target ? clipboard_wire_clipboard_buffer_target_get_buffer(target)
             : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;
  int64_t count =
      (buffer ==
       XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_PRIMARY_SELECTION)
          ? self->primary_change_count
          : self->general_change_count;
  return clipboard_clipboard_host_api_get_change_count_response_new(count);
}

static ClipboardClipboardHostApiClearResponse* handle_clear(
    ClipboardWireClipboardBufferTarget* target,
    gpointer /*user_data*/) {
  ClipboardWireClipboardBuffer buffer =
      target ? clipboard_wire_clipboard_buffer_target_get_buffer(target)
             : XUE_HUA_NAVITE_CLIPBOARD_WIRE_CLIPBOARD_BUFFER_GENERAL;
  GtkClipboard* cb = resolve_gtk_clipboard(buffer);
  gtk_clipboard_clear(cb);
  return clipboard_clipboard_host_api_clear_response_new(TRUE);
}

static ClipboardClipboardHostApiSetPollingIntervalResponse*
handle_set_polling_interval(int64_t /*interval_ms*/, gpointer /*user_data*/) {
  return clipboard_clipboard_host_api_set_polling_interval_response_new();
}

static ClipboardClipboardHostApiStartClipboardListeningResponse*
handle_start_clipboard_listening(gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self =
      XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  start_native_listening(self);
  return clipboard_clipboard_host_api_start_clipboard_listening_response_new();
}

static ClipboardClipboardHostApiStopClipboardListeningResponse*
handle_stop_clipboard_listening(gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self =
      XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  stop_native_listening(self);
  return clipboard_clipboard_host_api_stop_clipboard_listening_response_new();
}

static const ClipboardClipboardHostApiVTable kHostApiVTable = {
    .write_items = handle_write_items,
    .read_items = handle_read_items,
    .get_metadata = handle_get_metadata,
    .get_change_count = handle_get_change_count,
    .clear = handle_clear,
    .set_polling_interval = handle_set_polling_interval,
    .start_clipboard_listening = handle_start_clipboard_listening,
    .stop_clipboard_listening = handle_stop_clipboard_listening,
};

static void xue_hua_navite_clipboard_plugin_dispose(GObject* object) {
  XueHuaNaviteClipboardPlugin* self = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(object);
  stop_native_listening(self);
  g_clear_object(&self->flutter_api);
  G_OBJECT_CLASS(xue_hua_navite_clipboard_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_navite_clipboard_plugin_class_init(
    XueHuaNaviteClipboardPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_navite_clipboard_plugin_dispose;
}

static void xue_hua_navite_clipboard_plugin_init(
    XueHuaNaviteClipboardPlugin* self) {
  self->flutter_api = nullptr;
  self->is_listening = false;
  self->clipboard_signal_id = 0;
  self->primary_signal_id = 0;
  self->general_change_count = 0;
  self->primary_change_count = 0;
}

void xue_hua_navite_clipboard_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  XueHuaNaviteClipboardPlugin* plugin = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(
      g_object_new(xue_hua_navite_clipboard_plugin_get_type(), nullptr));

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  plugin->flutter_api =
      clipboard_clipboard_flutter_api_new(messenger, nullptr);

  clipboard_clipboard_host_api_set_method_handlers(
      messenger, nullptr, &kHostApiVTable, g_object_ref(plugin),
      g_object_unref);

  g_object_unref(plugin);
}
