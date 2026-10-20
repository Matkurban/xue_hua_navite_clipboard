#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/xue_hua_navite_clipboard/xue_hua_navite_clipboard_plugin.h"
#include "xue_hua_navite_clipboard_plugin_private.h"

namespace xue_hua_navite_clipboard {
namespace test {

TEST(XueHuaNaviteClipboardPlugin, PluginTypeRegistered) {
  GType type = xue_hua_navite_clipboard_plugin_get_type();
  EXPECT_NE(type, G_TYPE_INVALID);
}

}  // namespace test
}  // namespace xue_hua_navite_clipboard
