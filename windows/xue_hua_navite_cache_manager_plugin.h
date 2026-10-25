#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace xue_hua_navite_cache_manager {

struct CacheRecord {
  std::string key;
  std::string url;
  std::string file_path;
  int64_t size_bytes = 0;
  int64_t created_at_ms = 0;
  int64_t last_accessed_at_ms = 0;
  int64_t expires_at_ms = 0;
  int64_t hit_count = 0;
  std::string tag;
  std::string mime_type;
  std::string etag;
  std::string last_modified;
  std::string checksum;
  std::string checksum_algorithm = "none";
  bool pinned = false;

  bool IsExpired(int64_t now_ms) const {
    return expires_at_ms > 0 && now_ms > expires_at_ms;
  }

  flutter::EncodableMap ToEncodableMap() const;
};

class XueHuaNaviteCacheManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  XueHuaNaviteCacheManagerPlugin();

  virtual ~XueHuaNaviteCacheManagerPlugin();

  // Disallow copy and assign.
  XueHuaNaviteCacheManagerPlugin(const XueHuaNaviteCacheManagerPlugin&) = delete;
  XueHuaNaviteCacheManagerPlugin& operator=(const XueHuaNaviteCacheManagerPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetEventSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);

 private:
  std::string GetCacheRootDir() const;
  std::string GetIndexFilePath() const;
  void EnsureIndexLoaded();
  void PersistIndexLocked();
  std::string ResolveKey(const std::string& key_or_url, const std::string& custom_key = "");
  int RemoveExpiredLocked();
  int EnforceQuotaLocked(int64_t target_max_bytes, const std::string& protected_key);
  void EmitProgress(const std::string& key,
                    const std::string& url,
                    const std::string& state,
                    int64_t bytes_received,
                    int64_t total_bytes,
                    const std::string& file_path = "",
                    const std::string& error_message = "");

  bool ExecuteDownloadLockedOrUnlocked(const flutter::EncodableMap& args,
                                       flutter::EncodableMap* out_result,
                                       std::string* out_error_code,
                                       std::string* out_error_msg);

  mutable std::mutex mutex_;
  mutable std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  int64_t max_disk_cache_bytes_ = 500LL * 1024LL * 1024LL;
  int max_entries_ = 2000;
  int64_t default_ttl_seconds_ = 7LL * 24LL * 3600LL;
  std::string eviction_policy_ = "lru";
  std::string cache_subdirectory_ = "xue_hua_network_cache";
  int max_concurrent_downloads_ = 4;
  int connect_timeout_ms_ = 15000;
  int read_timeout_ms_ = 30000;
  std::map<std::string, std::string> default_headers_;
  bool respect_http_cache_headers_ = true;
  bool auto_trim_on_write_ = true;

  std::map<std::string, CacheRecord> entries_;
  int64_t hit_count_ = 0;
  int64_t miss_count_ = 0;
  int64_t eviction_count_ = 0;
  bool index_loaded_ = false;
  std::map<std::string, std::shared_ptr<std::atomic<bool>>> active_cancels_;
};

}  // namespace xue_hua_navite_cache_manager

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
