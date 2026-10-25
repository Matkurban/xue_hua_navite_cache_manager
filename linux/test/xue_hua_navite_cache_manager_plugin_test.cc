#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin.h"
#include "xue_hua_navite_cache_manager_plugin_private.h"

namespace xue_hua_navite_cache_manager {
namespace test {

TEST(XueHuaNaviteCacheManagerPlugin, GetCapabilitiesReturnsLinux) {
  g_autoptr(FlMethodResponse) response = get_capabilities_response();
  ASSERT_NE(response, nullptr);
  ASSERT_TRUE(FL_IS_METHOD_SUCCESS_RESPONSE(response));
  FlValue* result = fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response));
  ASSERT_EQ(fl_value_get_type(result), FL_VALUE_TYPE_MAP);
  FlValue* platform_name = fl_value_lookup_string(result, "platformName");
  ASSERT_NE(platform_name, nullptr);
  EXPECT_STREQ(fl_value_get_string(platform_name), "linux");
}

}  // namespace test
}  // namespace xue_hua_navite_cache_manager
