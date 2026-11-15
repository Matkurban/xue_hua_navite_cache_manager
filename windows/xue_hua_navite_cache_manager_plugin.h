#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <thread>
#include <vector>

#include "messages.g.h"

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

  WireCacheEntry ToWireEntry() const;
};

class XueHuaNaviteCacheManagerPlugin : public flutter::Plugin,
                                       public CacheHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  // |registrar| may be null in unit tests. When non-null, platform-thread
  // delivery prefers PluginRegistrarWindows::PostPlatformThreadTask on SDKs
  // that provide it, or falls back to the message-only window dispatcher.
  explicit XueHuaNaviteCacheManagerPlugin(
      flutter::PluginRegistrarWindows* registrar = nullptr);

  ~XueHuaNaviteCacheManagerPlugin() override;

  // Disallow copy and assign.
  XueHuaNaviteCacheManagerPlugin(const XueHuaNaviteCacheManagerPlugin&) =
      delete;
  XueHuaNaviteCacheManagerPlugin& operator=(
      const XueHuaNaviteCacheManagerPlugin&) = delete;

  // CacheHostApi overrides:
  void Configure(
      const WireCacheManagerConfig& config,
      std::function<void(std::optional<FlutterError> reply)> result) override;
  void DownloadFile(
      const WireCacheRequest& request,
      std::function<void(ErrorOr<WireCacheFetchResult> reply)> result) override;
  void PrefetchAll(
      const ::flutter::EncodableList& requests,
      std::function<void(ErrorOr<::flutter::EncodableList> reply)> result)
      override;
  ErrorOr<bool> CancelDownload(const std::string& key_or_url) override;
  void GetFileFromCache(
      const std::string& key_or_url,
      bool ignore_expired,
      std::function<void(ErrorOr<std::optional<WireCacheEntry>> reply)> result)
      override;
  void ReadCacheBytes(
      const std::string& key_or_url,
      bool ignore_expired,
      std::function<void(ErrorOr<std::optional<std::vector<uint8_t>>> reply)>
          result) override;
  void ContainsKey(const std::string& key_or_url,
                   bool ignore_expired,
                   std::function<void(ErrorOr<bool> reply)> result) override;
  void PutBytes(const std::string& key,
                const std::vector<uint8_t>& bytes,
                const std::string* url,
                const std::string* file_extension,
                const std::string* mime_type,
                const std::string* tag,
                const int64_t* ttl_seconds,
                bool pinned,
                std::function<void(ErrorOr<WireCacheEntry> reply)> result)
      override;
  void PutFile(const std::string& key,
               const std::string& source_file_path,
               const std::string* url,
               const std::string* file_extension,
               const std::string* mime_type,
               const std::string* tag,
               const int64_t* ttl_seconds,
               bool pinned,
               std::function<void(ErrorOr<WireCacheEntry> reply)> result)
      override;
  void SetPinned(const std::string& key_or_url,
                 bool pinned,
                 std::function<void(ErrorOr<bool> reply)> result) override;
  void RemoveFile(const std::string& key_or_url,
                  std::function<void(ErrorOr<bool> reply)> result) override;
  void RemoveByTag(
      const std::string& tag,
      std::function<void(ErrorOr<int64_t> reply)> result) override;
  void RemoveExpired(
      std::function<void(ErrorOr<int64_t> reply)> result) override;
  void TrimToSize(
      int64_t max_bytes,
      std::function<void(ErrorOr<int64_t> reply)> result) override;
  void ClearAll(bool include_pinned,
                std::function<void(ErrorOr<int64_t> reply)> result) override;
  void ListEntries(
      const std::string* tag,
      bool include_expired,
      std::function<void(ErrorOr<::flutter::EncodableList> reply)> result)
      override;
  void GetStats(
      std::function<void(ErrorOr<WireCacheStats> reply)> result) override;
  ErrorOr<WireCachePlatformCapabilities> GetCapabilities() override;

 private:
  std::string ResolveCacheRootPath(const std::string& subdirectory) const;
  std::string GetCacheRootDir(bool create_if_missing = true) const;
  std::string GetIndexFilePath(const std::string& subdirectory = "") const;
  void EnsureIndexLoaded();
  void PersistIndexLocked();
  std::string ResolveKey(const std::string& key_or_url,
                         const std::string& custom_key = "");
  std::string ResolveKeyLocked(const std::string& key_or_url,
                               const std::string& custom_key = "") const;
  int RemoveExpiredLocked();
  int EnforceQuotaLocked(int64_t target_max_bytes,
                         int max_entries,
                         const std::string& eviction_policy,
                         const std::string& protected_key);
  void EmitProgress(const std::string& key,
                    const std::string& url,
                    WireCacheTransferState state,
                    int64_t bytes_received,
                    int64_t total_bytes,
                    const std::string& file_path = "",
                    const std::string& error_message = "");

  struct DownloadOutcome {
    bool ok = false;
    std::optional<WireCacheFetchResult> result;
    std::string error_code;
    std::string error_msg;
  };

  struct InFlightDownload {
    std::shared_ptr<std::atomic<bool>> cancel_flag;
    std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  };

  DownloadOutcome ExecuteDownload(
      const WireCacheRequest& request,
      const std::shared_ptr<std::atomic<bool>>& external_cancel);

  // Assumes index_mutex_ is held. Fresh cache hits do not occupy a download slot.
  bool TryServeFreshCacheLocked(const std::string& key,
                                const std::string& tag,
                                bool pinned,
                                int64_t start_ms,
                                WireCacheFetchResult* out_result);

  void ScheduleDownload(
      const WireCacheRequest& request,
      const std::function<void(const DownloadOutcome&)>& callback);
  void FinishInFlight(const std::string& key,
                      const std::shared_ptr<InFlightDownload>& state,
                      const DownloadOutcome& outcome);

  void EnsureIoWorkers(int workers);
  void IoWorkerLoop();
  void PostIoJob(std::function<void()> job);

  void EnsureDownloadWorkers(int workers);
  void DownloadWorkerLoop();
  void PostDownloadJob(std::function<void()> job);

  // Queues |task| on the Flutter platform thread. Never invokes |task| inline:
  // callers such as EmitProgress may run while holding internal locks or on
  // worker threads.
  void PostToPlatformThread(std::function<void()> task);
  void StartPlatformDispatcher();
  void StopPlatformDispatcher();

  void ScheduleIndexFlush();
  void IndexFlushLoop();
  void FlushIndexSnapshot(const std::string& override_subdir = "");

  struct EventDispatchState;
  std::shared_ptr<EventDispatchState> CopyEventState() const;

  mutable std::mutex config_mutex_;
  mutable std::mutex index_mutex_;
  mutable std::mutex flight_mutex_;

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  mutable std::mutex event_state_mu_;
  std::shared_ptr<EventDispatchState> event_state_;
  // HWND of a message-only window created on the platform thread. Stored as
  // void* so this header does not include windows.h.
  void* platform_hwnd_ = nullptr;

  std::atomic<bool> index_dirty_{false};
  std::mutex persist_mutex_;
  std::condition_variable persist_cv_;
  std::thread persist_thread_;
  bool persist_stopping_ = false;
  bool persist_scheduled_ = false;
  std::chrono::steady_clock::time_point persist_deadline_{};

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

  // Bounded disk/index IO worker pool (separate from download workers).
  std::mutex io_pool_mutex_;
  std::condition_variable io_pool_cv_;
  std::queue<std::function<void()>> io_jobs_;
  std::vector<std::thread> io_workers_;
  bool io_pool_stopping_ = false;

  // Bounded download pool. Idle threads may stay at the high-water mark, but
  // only max_concurrent_downloads_ jobs run at once.
  std::mutex pool_mutex_;
  std::condition_variable pool_cv_;
  std::queue<std::function<void()>> download_jobs_;
  std::vector<std::thread> download_workers_;
  bool pool_stopping_ = false;
  int active_download_slots_ = 0;
};

}  // namespace xue_hua_navite_cache_manager

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
