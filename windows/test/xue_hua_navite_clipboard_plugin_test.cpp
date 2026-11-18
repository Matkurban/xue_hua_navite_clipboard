#include <gtest/gtest.h>
#include <windows.h>

#include "xue_hua_navite_clipboard_plugin.h"

namespace xue_hua_navite_clipboard {
namespace test {

TEST(XueHuaNaviteClipboardPlugin, GetChangeCount) {
  XueHuaNaviteClipboardPlugin plugin;
  ErrorOr<int64_t> result = plugin.GetChangeCount(
      WireClipboardBufferTarget(WireClipboardBuffer::kGeneral));

  EXPECT_FALSE(result.has_error());
  if (!result.has_error()) {
    EXPECT_GE(result.value(), 0);
  }
}

}  // namespace test
}  // namespace xue_hua_navite_clipboard
