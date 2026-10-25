#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
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

  struct DownloadOutcome {
    bool ok = false;
    flutter::EncodableMap result;
    std::string error_code;
    std::string error_msg;
  };

  struct InFlightDownload {
    std::shared_ptr<std::atomic<bool>> cancel_flag;
    std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  };

  bool ExecuteDownloadLockedOrUnlocked(
      const flutter::EncodableMap& args,
      flutter::EncodableMap* out_result,
      std::string* out_error_code,
      std::string* out_error_msg,
      const std::shared_ptr<std::atomic<bool>>& external_cancel);

  // Assumes mutex_ is held. Fresh cache hits do not occupy a download slot.
  bool TryServeFreshCacheLocked(const std::string& key,
                                const std::string& url,
                                const std::string& tag,
                                bool pinned,
                                int64_t start_ms,
                                flutter::EncodableMap* out_result);

  void ScheduleDownload(
      const flutter::EncodableMap& args,
      const std::function<void(const DownloadOutcome&)>& callback);
  void FinishInFlight(const std::string& key,
                      const std::shared_ptr<InFlightDownload>& state,
                      const DownloadOutcome& outcome);
  void EnsureDownloadWorkers(int workers);
  void DownloadWorkerLoop();
  void PostDownloadJob(std::function<void()> job);

  mutable std::mutex mutex_;
  mutable std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  int64_t max_disk_cache_bytes_ = 500LL * 1024LL * 1024LL;
  int max_entries_ = 20000;
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
  int64_t total_cached_bytes_ = 0;
  int64_t hit_count_ = 0;
  int64_t miss_count_ = 0;
  int64_t eviction_count_ = 0;
  bool index_loaded_ = false;
  std::map<std::string, std::shared_ptr<std::atomic<bool>>> active_cancels_;
  std::map<std::string, std::shared_ptr<InFlightDownload>> in_flight_;

  // Bounded pool. Idle threads may stay at the high-water mark, but only
  // max_concurrent_downloads_ jobs run at once.
  std::mutex pool_mutex_;
  std::condition_variable pool_cv_;
  std::queue<std::function<void()>> download_jobs_;
  std::vector<std::thread> download_workers_;
  bool pool_stopping_ = false;
  int active_download_slots_ = 0;
};

}  // namespace xue_hua_navite_cache_manager

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
