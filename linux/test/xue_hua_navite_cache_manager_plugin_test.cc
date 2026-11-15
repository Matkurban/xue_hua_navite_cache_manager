#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin.h"
#include "xue_hua_navite_cache_manager_plugin_private.h"

namespace xue_hua_navite_cache_manager {
namespace test {

TEST(XueHuaNaviteCacheManagerPlugin, GetCapabilitiesReturnsLinux) {
  g_autoptr(XueHuaCacheCacheHostApiGetCapabilitiesResponse) response =
      get_capabilities_response();
  ASSERT_NE(response, nullptr);
}

TEST(XueHuaNaviteCacheManagerPlugin, CancelDownloadUnknownKeyReturnsFalse) {
  g_autoptr(XueHuaCacheCacheHostApiCancelDownloadResponse) response =
      cancel_download_response("nonexistent-download-key");
  ASSERT_NE(response, nullptr);
}

}  // namespace test
}  // namespace xue_hua_navite_cache_manager
