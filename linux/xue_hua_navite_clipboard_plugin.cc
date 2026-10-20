#include "include/xue_hua_navite_clipboard/xue_hua_navite_clipboard_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

#include <cstring>
#include <map>
#include <string>
#include <vector>

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
  FlEventChannel* event_channel;
  bool is_listening;
  gulong clipboard_signal_id;
  gulong primary_signal_id;
  int64_t general_change_count;
  int64_t primary_change_count;
};

G_DEFINE_TYPE(XueHuaNaviteClipboardPlugin, xue_hua_navite_clipboard_plugin, g_object_get_type())

static GtkClipboard* resolve_gtk_clipboard(const gchar* buffer_name) {
  if (buffer_name != nullptr && strcmp(buffer_name, "primarySelection") == 0) {
    return gtk_clipboard_get(GDK_SELECTION_PRIMARY);
  }
  return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

static void clipboard_get_func(GtkClipboard* clipboard,
                               GtkSelectionData* selection_data,
                               guint info,
                               gpointer user_data) {
  auto* payload = static_cast<StoredClipboardPayload*>(user_data);
  if (!payload) return;

  GdkAtom target = gtk_selection_data_get_target(selection_data);
  g_autofree gchar* target_name = gdk_atom_name(target);
  if (!target_name) return;

  auto it = payload->target_bytes.find(target_name);
  if (it != payload->target_bytes.end()) {
    gtk_selection_data_set(selection_data, target, 8,
                           it->second.data(),
                           static_cast<gint>(it->second.size()));
  }
}

static void clipboard_clear_func(GtkClipboard* clipboard, gpointer user_data) {
  auto* payload = static_cast<StoredClipboardPayload*>(user_data);
  delete payload;
}

static void on_gtk_owner_change(GtkClipboard* clipboard,
                                GdkEvent* event,
                                gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  if (!self->is_listening || !self->event_channel) return;

  bool is_primary = (clipboard == gtk_clipboard_get(GDK_SELECTION_PRIMARY));
  int64_t count = is_primary ? (++self->primary_change_count)
                             : (++self->general_change_count);
  int64_t now_ms = g_get_real_time() / 1000;

  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(
      map, "buffer",
      fl_value_new_string(is_primary ? "primarySelection" : "general"));
  fl_value_set_string_take(map, "changeCount", fl_value_new_int(count));
  fl_value_set_string_take(map, "timestampMs", fl_value_new_int(now_ms));

  fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
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

static FlMethodErrorResponse* event_channel_listen_cb(FlEventChannel* channel,
                                                      FlValue* args,
                                                      gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  start_native_listening(self);
  return nullptr;
}

static FlMethodErrorResponse* event_channel_cancel_cb(FlEventChannel* channel,
                                                      FlValue* args,
                                                      gpointer user_data) {
  XueHuaNaviteClipboardPlugin* self = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  stop_native_listening(self);
  return nullptr;
}

static FlMethodResponse* handle_write_items(XueHuaNaviteClipboardPlugin* self,
                                            FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    g_autoptr(FlValue) res = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  }

  FlValue* items = fl_value_lookup_string(args, "items");
  if (!items || fl_value_get_type(items) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(items) == 0) {
    g_autoptr(FlValue) res = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  }

  FlValue* first_item = fl_value_get_list_value(items, 0);
  FlValue* options = fl_value_lookup_string(args, "options");
  const gchar* buffer_name = "general";
  bool is_sensitive = false;

  if (options && fl_value_get_type(options) == FL_VALUE_TYPE_MAP) {
    FlValue* buf_val = fl_value_lookup_string(options, "buffer");
    if (buf_val && fl_value_get_type(buf_val) == FL_VALUE_TYPE_STRING) {
      buffer_name = fl_value_get_string(buf_val);
    }
    FlValue* sens_val = fl_value_lookup_string(options, "isSensitive");
    if (sens_val && fl_value_get_type(sens_val) == FL_VALUE_TYPE_BOOL) {
      is_sensitive = fl_value_get_bool(sens_val);
    }
  }

  auto* payload = new StoredClipboardPayload();
  auto add_str_target = [&](const char* target, const char* str) {
    size_t len = strlen(str);
    payload->target_bytes[target] =
        std::vector<uint8_t>(reinterpret_cast<const uint8_t*>(str),
                             reinterpret_cast<const uint8_t*>(str) + len);
  };
  auto add_bytes_target = [&](const char* target, const uint8_t* ptr, size_t len) {
    payload->target_bytes[target] = std::vector<uint8_t>(ptr, ptr + len);
  };

  FlValue* plain_val = fl_value_lookup_string(first_item, "plainText");
  if (plain_val && fl_value_get_type(plain_val) == FL_VALUE_TYPE_STRING) {
    const gchar* text = fl_value_get_string(plain_val);
    add_str_target("UTF8_STRING", text);
    add_str_target("STRING", text);
    add_str_target("text/plain;charset=utf-8", text);
    add_str_target("text/plain", text);
  }

  FlValue* html_val = fl_value_lookup_string(first_item, "html");
  if (html_val && fl_value_get_type(html_val) == FL_VALUE_TYPE_STRING) {
    add_str_target("text/html", fl_value_get_string(html_val));
  }

  FlValue* rtf_val = fl_value_lookup_string(first_item, "rtfBytes");
  if (rtf_val && fl_value_get_type(rtf_val) == FL_VALUE_TYPE_UINT8_LIST) {
    const uint8_t* bytes = fl_value_get_uint8_list(rtf_val);
    size_t len = fl_value_get_length(rtf_val);
    add_bytes_target("text/rtf", bytes, len);
    add_bytes_target("application/rtf", bytes, len);
  }

  FlValue* md_val = fl_value_lookup_string(first_item, "markdown");
  if (md_val && fl_value_get_type(md_val) == FL_VALUE_TYPE_STRING) {
    add_str_target("text/markdown", fl_value_get_string(md_val));
  }

  FlValue* uri_val = fl_value_lookup_string(first_item, "uri");
  if (uri_val && fl_value_get_type(uri_val) == FL_VALUE_TYPE_STRING) {
    add_str_target("text/uri-list", fl_value_get_string(uri_val));
  }

  FlValue* img_val = fl_value_lookup_string(first_item, "imageBytes");
  if (img_val && fl_value_get_type(img_val) == FL_VALUE_TYPE_UINT8_LIST) {
    const uint8_t* bytes = fl_value_get_uint8_list(img_val);
    size_t len = fl_value_get_length(img_val);
    add_bytes_target("image/png", bytes, len);
  }

  FlValue* files_val = fl_value_lookup_string(first_item, "files");
  if (files_val && fl_value_get_type(files_val) == FL_VALUE_TYPE_LIST &&
      fl_value_get_length(files_val) > 0) {
    const gchar* mode = "copy";
    FlValue* mode_val = fl_value_lookup_string(first_item, "fileCopyMode");
    if (mode_val && fl_value_get_type(mode_val) == FL_VALUE_TYPE_STRING) {
      mode = fl_value_get_string(mode_val);
    }

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

  FlValue* color_val = fl_value_lookup_string(first_item, "colorValue");
  if (color_val && fl_value_get_type(color_val) == FL_VALUE_TYPE_INT) {
    int64_t c = fl_value_get_int(color_val);
    add_bytes_target("application/x-color",
                     reinterpret_cast<const uint8_t*>(&c), sizeof(int64_t));
  }

  FlValue* custom_val = fl_value_lookup_string(first_item, "customFormats");
  if (custom_val && fl_value_get_type(custom_val) == FL_VALUE_TYPE_MAP) {
    size_t map_len = fl_value_get_length(custom_val);
    for (size_t i = 0; i < map_len; ++i) {
      FlValue* k = fl_value_get_map_key(custom_val, i);
      FlValue* v = fl_value_get_map_value(custom_val, i);
      if (k && v && fl_value_get_type(k) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(v) == FL_VALUE_TYPE_UINT8_LIST) {
        add_bytes_target(fl_value_get_string(k), fl_value_get_uint8_list(v),
                         fl_value_get_length(v));
      }
    }
  }

  if (is_sensitive) {
    add_str_target("x-kde-passwordManagerHint", "secret");
  }

  if (payload->target_bytes.empty()) {
    delete payload;
    g_autoptr(FlValue) res = fl_value_new_bool(FALSE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
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

  GtkClipboard* cb = resolve_gtk_clipboard(buffer_name);
  gboolean ok = gtk_clipboard_set_with_data(
      cb, entries.data(), static_cast<guint>(entries.size()),
      clipboard_get_func, clipboard_clear_func, payload);

  if (ok && !is_sensitive) {
    gtk_clipboard_set_can_store(cb, entries.data(),
                                static_cast<gint>(entries.size()));
  } else if (!ok) {
    delete payload;
  }

  g_autoptr(FlValue) res = fl_value_new_bool(ok);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
}

static FlMethodResponse* handle_read_items(XueHuaNaviteClipboardPlugin* self,
                                           FlValue* args) {
  const gchar* buffer_name = "general";
  FlValue* requested_custom = nullptr;

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* opts = fl_value_lookup_string(args, "options");
    if (opts && fl_value_get_type(opts) == FL_VALUE_TYPE_MAP) {
      FlValue* buf_val = fl_value_lookup_string(opts, "buffer");
      if (buf_val && fl_value_get_type(buf_val) == FL_VALUE_TYPE_STRING) {
        buffer_name = fl_value_get_string(buf_val);
      }
      requested_custom =
          fl_value_lookup_string(opts, "requestedCustomFormats");
    }
  }

  GtkClipboard* cb = resolve_gtk_clipboard(buffer_name);
  g_autoptr(FlValue) item = fl_value_new_map();

  g_autofree gchar* text = gtk_clipboard_wait_for_text(cb);
  if (text) {
    fl_value_set_string_take(item, "plainText", fl_value_new_string(text));
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

  std::vector<uint8_t> html_bytes;
  if (read_target_bytes("text/html", html_bytes)) {
    std::string html_str(reinterpret_cast<const char*>(html_bytes.data()),
                         html_bytes.size());
    fl_value_set_string_take(item, "html",
                             fl_value_new_string(html_str.c_str()));
  }

  std::vector<uint8_t> rtf_bytes;
  if (read_target_bytes("text/rtf", rtf_bytes) ||
      read_target_bytes("application/rtf", rtf_bytes)) {
    fl_value_set_string_take(
        item, "rtfBytes",
        fl_value_new_uint8_list(rtf_bytes.data(), rtf_bytes.size()));
  }

  std::vector<uint8_t> md_bytes;
  if (read_target_bytes("text/markdown", md_bytes)) {
    std::string md_str(reinterpret_cast<const char*>(md_bytes.data()),
                       md_bytes.size());
    fl_value_set_string_take(item, "markdown",
                             fl_value_new_string(md_str.c_str()));
  }

  std::vector<uint8_t> png_bytes;
  if (read_target_bytes("image/png", png_bytes)) {
    fl_value_set_string_take(
        item, "imageBytes",
        fl_value_new_uint8_list(png_bytes.data(), png_bytes.size()));
    fl_value_set_string_take(item, "imageMimeType",
                             fl_value_new_string("image/png"));
  } else if (gtk_clipboard_wait_is_image_available(cb)) {
    GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(cb);
    if (pixbuf) {
      gchar* buf = nullptr;
      gsize buf_size = 0;
      if (gdk_pixbuf_save_to_buffer(pixbuf, &buf, &buf_size, "png", nullptr,
                                    nullptr)) {
        fl_value_set_string_take(
            item, "imageBytes",
            fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buf),
                                    buf_size));
        fl_value_set_string_take(item, "imageMimeType",
                                 fl_value_new_string("image/png"));
        g_free(buf);
      }
      g_object_unref(pixbuf);
    }
  }

  std::vector<uint8_t> gnome_bytes;
  std::string file_copy_mode = "copy";
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
        if (line == "cut") file_copy_mode = "cut";
        first_line = false;
      } else if (!line.empty()) {
        g_autofree gchar* filename = g_filename_from_uri(line.c_str(), nullptr, nullptr);
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
          fl_value_set_string_take(item, "uri", fl_value_new_string(uris[i]));
        }
      }
      g_strfreev(uris);
    }
  }

  if (fl_value_get_length(files_list) > 0) {
    fl_value_set_string(item, "files", files_list);
    fl_value_set_string_take(item, "fileCopyMode",
                             fl_value_new_string(file_copy_mode.c_str()));
  }

  std::vector<uint8_t> color_bytes;
  if (read_target_bytes("application/x-color", color_bytes) &&
      color_bytes.size() >= sizeof(int64_t)) {
    int64_t c = 0;
    memcpy(&c, color_bytes.data(), sizeof(int64_t));
    fl_value_set_string_take(item, "colorValue", fl_value_new_int(c));
  }

  if (requested_custom &&
      fl_value_get_type(requested_custom) == FL_VALUE_TYPE_LIST) {
    g_autoptr(FlValue) custom_map = fl_value_new_map();
    size_t n = fl_value_get_length(requested_custom);
    for (size_t i = 0; i < n; ++i) {
      FlValue* fmt_val = fl_value_get_list_value(requested_custom, i);
      if (fmt_val && fl_value_get_type(fmt_val) == FL_VALUE_TYPE_STRING) {
        const gchar* fmt_name = fl_value_get_string(fmt_val);
        std::vector<uint8_t> cbytes;
        if (read_target_bytes(fmt_name, cbytes)) {
          fl_value_set_string_take(
              custom_map, fmt_name,
              fl_value_new_uint8_list(cbytes.data(), cbytes.size()));
        }
      }
    }
    if (fl_value_get_length(custom_map) > 0) {
      fl_value_set_string(item, "customFormats", custom_map);
    }
  }

  g_autoptr(FlValue) list = fl_value_new_list();
  if (fl_value_get_length(item) > 0) {
    fl_value_append(list, item);
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
}

static FlMethodResponse* handle_get_metadata(XueHuaNaviteClipboardPlugin* self,
                                             FlValue* args) {
  const gchar* buffer_name = "general";
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* buf_val = fl_value_lookup_string(args, "buffer");
    if (buf_val && fl_value_get_type(buf_val) == FL_VALUE_TYPE_STRING) {
      buffer_name = fl_value_get_string(buf_val);
    }
  }

  GtkClipboard* cb = resolve_gtk_clipboard(buffer_name);
  bool is_primary = (strcmp(buffer_name, "primarySelection") == 0);
  int64_t change_count =
      is_primary ? self->primary_change_count : self->general_change_count;

  g_autoptr(FlValue) raw_formats = fl_value_new_list();
  bool has_text = gtk_clipboard_wait_is_text_available(cb);
  bool has_image = gtk_clipboard_wait_is_image_available(cb);
  bool has_uris = gtk_clipboard_wait_is_uris_available(cb);
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
            strcmp(name, "application/rtf") == 0)
          has_rtf = true;
        if (strcmp(name, "text/markdown") == 0) has_md = true;
        if (strcmp(name, "x-special/gnome-copied-files") == 0) has_files = true;
        if (strcmp(name, "application/x-color") == 0) has_color = true;
      }
    }
    g_free(targets);
  }

  g_autoptr(FlValue) meta = fl_value_new_map();
  fl_value_set_string_take(meta, "changeCount", fl_value_new_int(change_count));
  fl_value_set_string_take(
      meta, "itemCount",
      fl_value_new_int(fl_value_get_length(raw_formats) > 0 ? 1 : 0));
  fl_value_set_string_take(meta, "hasPlainText", fl_value_new_bool(has_text));
  fl_value_set_string_take(meta, "hasHtml", fl_value_new_bool(has_html));
  fl_value_set_string_take(meta, "hasRtf", fl_value_new_bool(has_rtf));
  fl_value_set_string_take(meta, "hasMarkdown", fl_value_new_bool(has_md));
  fl_value_set_string_take(meta, "hasUri", fl_value_new_bool(has_uris));
  fl_value_set_string_take(meta, "hasImage", fl_value_new_bool(has_image));
  fl_value_set_string_take(meta, "hasFiles", fl_value_new_bool(has_files));
  fl_value_set_string_take(meta, "hasColor", fl_value_new_bool(has_color));
  fl_value_set_string(meta, "rawPlatformFormats", raw_formats);
  fl_value_set_string_take(meta, "detectedPatterns", fl_value_new_list());

  return FL_METHOD_RESPONSE(fl_method_success_response_new(meta));
}

static void xue_hua_navite_clipboard_plugin_handle_method_call(
    XueHuaNaviteClipboardPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "writeItems") == 0) {
    response = handle_write_items(self, args);
  } else if (strcmp(method, "readItems") == 0) {
    response = handle_read_items(self, args);
  } else if (strcmp(method, "getMetadata") == 0) {
    response = handle_get_metadata(self, args);
  } else if (strcmp(method, "getChangeCount") == 0) {
    const gchar* buffer_name = "general";
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* buf_val = fl_value_lookup_string(args, "buffer");
      if (buf_val && fl_value_get_type(buf_val) == FL_VALUE_TYPE_STRING) {
        buffer_name = fl_value_get_string(buf_val);
      }
    }
    int64_t count = (strcmp(buffer_name, "primarySelection") == 0)
                        ? self->primary_change_count
                        : self->general_change_count;
    g_autoptr(FlValue) res = fl_value_new_int(count);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "clear") == 0) {
    const gchar* buffer_name = "general";
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* buf_val = fl_value_lookup_string(args, "buffer");
      if (buf_val && fl_value_get_type(buf_val) == FL_VALUE_TYPE_STRING) {
        buffer_name = fl_value_get_string(buf_val);
      }
    }
    GtkClipboard* cb = resolve_gtk_clipboard(buffer_name);
    gtk_clipboard_clear(cb);
    g_autoptr(FlValue) res = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "setPollingInterval") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void xue_hua_navite_clipboard_plugin_dispose(GObject* object) {
  XueHuaNaviteClipboardPlugin* self = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(object);
  stop_native_listening(self);
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(xue_hua_navite_clipboard_plugin_parent_class)->dispose(object);
}

static void xue_hua_navite_clipboard_plugin_class_init(XueHuaNaviteClipboardPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_navite_clipboard_plugin_dispose;
}

static void xue_hua_navite_clipboard_plugin_init(XueHuaNaviteClipboardPlugin* self) {
  self->event_channel = nullptr;
  self->is_listening = false;
  self->clipboard_signal_id = 0;
  self->primary_signal_id = 0;
  self->general_change_count = 0;
  self->primary_change_count = 0;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  XueHuaNaviteClipboardPlugin* plugin = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(user_data);
  xue_hua_navite_clipboard_plugin_handle_method_call(plugin, method_call);
}

void xue_hua_navite_clipboard_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  XueHuaNaviteClipboardPlugin* plugin = XUE_HUA_NAVITE_CLIPBOARD_PLUGIN(
      g_object_new(xue_hua_navite_clipboard_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "xue_hua_navite_clipboard",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  plugin->event_channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "xue_hua_navite_clipboard/events",
                           FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel,
                                       event_channel_listen_cb,
                                       event_channel_cancel_cb,
                                       g_object_ref(plugin),
                                       g_object_unref);

  g_object_unref(plugin);
}
