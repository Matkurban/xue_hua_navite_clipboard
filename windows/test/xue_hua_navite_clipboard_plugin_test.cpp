#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <variant>

#include "xue_hua_navite_clipboard_plugin.h"

namespace xue_hua_navite_clipboard {
namespace test {

namespace {

using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(XueHuaNaviteClipboardPlugin, GetChangeCount) {
  XueHuaNaviteClipboardPlugin plugin;
  int64_t result_count = -1;
  plugin.HandleMethodCall(
      MethodCall("getChangeCount", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_count](const EncodableValue* result) {
            result_count = result->LongValue();
          },
          nullptr, nullptr));

  EXPECT_GE(result_count, 0);
}

}  // namespace test
}  // namespace xue_hua_navite_clipboard
