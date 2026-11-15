#include <gtest/gtest.h>
#include <windows.h>

#include <string>

#include "xue_hua_navite_cache_manager_plugin.h"

namespace xue_hua_navite_cache_manager {
namespace test {

TEST(XueHuaNaviteCacheManagerPlugin, GetCapabilitiesReturnsWindows) {
  XueHuaNaviteCacheManagerPlugin plugin;
  ErrorOr<WireCachePlatformCapabilities> result = plugin.GetCapabilities();
  ASSERT_FALSE(result.has_error());
  EXPECT_EQ(result.value().platform_name(), "windows");
  EXPECT_TRUE(result.value().supports_file_system_paths());
  EXPECT_TRUE(result.value().supports_conditional_http_revalidation());
  EXPECT_TRUE(result.value().supports_native_crypto_hash());
  EXPECT_FALSE(result.value().supports_low_disk_space_notifications());
}

TEST(XueHuaNaviteCacheManagerPlugin, CancelDownloadUnknownKeyReturnsFalse) {
  XueHuaNaviteCacheManagerPlugin plugin;
  ErrorOr<bool> result = plugin.CancelDownload("nonexistent-download-key");
  ASSERT_FALSE(result.has_error());
  EXPECT_FALSE(result.value());
}

}  // namespace test
}  // namespace xue_hua_navite_cache_manager
