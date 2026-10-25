#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "xue_hua_navite_cache_manager_plugin.h"

namespace xue_hua_navite_cache_manager {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(XueHuaNaviteCacheManagerPlugin, GetCapabilitiesReturnsWindows) {
  XueHuaNaviteCacheManagerPlugin plugin;
  EncodableMap result_map;
  plugin.HandleMethodCall(
      MethodCall("getCapabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_map](const EncodableValue* result) {
            result_map = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  auto it = result_map.find(EncodableValue("platformName"));
  ASSERT_NE(it, result_map.end());
  EXPECT_EQ(std::get<std::string>(it->second), "windows");
}

}  // namespace test
}  // namespace xue_hua_navite_cache_manager
