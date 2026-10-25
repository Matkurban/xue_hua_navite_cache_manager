#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <glib.h>
#include <gtk/gtk.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "xue_hua_navite_cache_manager_plugin_private.h"

#define XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST(                   \
      (obj), xue_hua_navite_cache_manager_plugin_get_type(), \
      XueHuaNaviteCacheManagerPlugin))

namespace {

int64_t CurrentTimeMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

struct LinuxCacheRecord {
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

  FlValue* ToFlValue() const {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "key", fl_value_new_string(key.c_str()));
    fl_value_set_string_take(map, "url", fl_value_new_string(url.c_str()));
    fl_value_set_string_take(map, "filePath",
                             fl_value_new_string(file_path.c_str()));
    fl_value_set_string_take(map, "sizeBytes", fl_value_new_int(size_bytes));
    fl_value_set_string_take(map, "createdAtMs",
                             fl_value_new_int(created_at_ms));
    fl_value_set_string_take(map, "lastAccessedAtMs",
                             fl_value_new_int(last_accessed_at_ms));
    fl_value_set_string_take(map, "expiresAtMs",
                             fl_value_new_int(expires_at_ms));
    fl_value_set_string_take(map, "hitCount", fl_value_new_int(hit_count));
    fl_value_set_string_take(
        map, "tag",
        tag.empty() ? fl_value_new_null() : fl_value_new_string(tag.c_str()));
    fl_value_set_string_take(map, "mimeType",
                             mime_type.empty()
                                 ? fl_value_new_null()
                                 : fl_value_new_string(mime_type.c_str()));
    fl_value_set_string_take(map, "eTag",
                             etag.empty() ? fl_value_new_null()
                                          : fl_value_new_string(etag.c_str()));
    fl_value_set_string_take(
        map, "lastModified",
        last_modified.empty() ? fl_value_new_null()
                              : fl_value_new_string(last_modified.c_str()));
    fl_value_set_string_take(map, "checksum",
                             checksum.empty()
                                 ? fl_value_new_null()
                                 : fl_value_new_string(checksum.c_str()));
    fl_value_set_string_take(
        map, "checksumAlgorithm",
        fl_value_new_string(checksum_algorithm.c_str()));
    fl_value_set_string_take(map, "pinned", fl_value_new_bool(pinned));
    return map;
  }
};

std::string ComputeGLibHash(const uint8_t* data,
                            size_t length,
                            const std::string& algorithm) {
  GChecksumType type = (algorithm == "md5" || algorithm == "MD5")
                           ? G_CHECKSUM_MD5
                           : G_CHECKSUM_SHA256;
  gchar* hex = g_compute_checksum_for_data(type, data, length);
  if (!hex) return "";
  std::string out(hex);
  g_free(hex);
  return out;
}

std::string GetFlString(FlValue* map,
                        const char* key,
                        const std::string& fallback = "") {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(v);
  }
  return fallback;
}

int64_t GetFlInt(FlValue* map, const char* key, int64_t fallback = 0) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return fl_value_get_int(v);
  }
  return fallback;
}

bool GetFlBool(FlValue* map, const char* key, bool fallback = false) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(v);
  }
  return fallback;
}

bool HasFlKey(FlValue* map, const char* key) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return false;
  FlValue* v = fl_value_lookup_string(map, key);
  return v != nullptr && fl_value_get_type(v) != FL_VALUE_TYPE_NULL;
}

std::string InferExtension(const std::string& url,
                           const std::string& mime_type,
                           const std::string& explicit_ext) {
  if (!explicit_ext.empty()) {
    std::string clean = explicit_ext;
    if (!clean.empty() && clean[0] == '.') clean = clean.substr(1);
    return clean;
  }
  auto q_pos = url.find('?');
  std::string path = (q_pos == std::string::npos) ? url : url.substr(0, q_pos);
  auto slash_pos = path.find_last_of('/');
  std::string filename =
      (slash_pos == std::string::npos) ? path : path.substr(slash_pos + 1);
  auto dot_pos = filename.find_last_of('.');
  if (dot_pos != std::string::npos && dot_pos + 1 < filename.size()) {
    std::string ext = filename.substr(dot_pos + 1);
    if (ext.size() <= 8) return ext;
  }
  if (mime_type.find("image/png") != std::string::npos) return "png";
  if (mime_type.find("image/jpeg") != std::string::npos) return "jpg";
  if (mime_type.find("image/webp") != std::string::npos) return "webp";
  if (mime_type.find("image/gif") != std::string::npos) return "gif";
  if (mime_type.find("application/pdf") != std::string::npos) return "pdf";
  if (mime_type.find("application/json") != std::string::npos) return "json";
  if (mime_type.find("audio/mpeg") != std::string::npos) return "mp3";
  if (mime_type.find("video/mp4") != std::string::npos) return "mp4";
  return "bin";
}

}  // namespace

struct _XueHuaNaviteCacheManagerPlugin {
  GObject parent_instance;
  FlEventChannel* event_channel;
  bool is_listening;
};

G_DEFINE_TYPE(XueHuaNaviteCacheManagerPlugin,
              xue_hua_navite_cache_manager_plugin,
              g_object_get_type())

namespace {

std::mutex g_mutex;
int64_t g_max_disk_cache_bytes = 500LL * 1024LL * 1024LL;
int g_max_entries = 20000;
int64_t g_default_ttl_seconds = 7LL * 24LL * 3600LL;
std::string g_eviction_policy = "lru";
std::string g_cache_subdirectory = "xue_hua_network_cache";
int g_connect_timeout_ms = 15000;
int g_read_timeout_ms = 30000;
int g_max_concurrent_downloads = 4;
bool g_respect_http_cache_headers = true;
bool g_auto_trim_on_write = true;

std::map<std::string, LinuxCacheRecord> g_entries;
int64_t g_hit_count = 0;
int64_t g_miss_count = 0;
int64_t g_eviction_count = 0;
bool g_index_loaded = false;

std::string GetCacheRootDir() {
  const gchar* base = g_get_user_cache_dir();
  std::string dir = std::string(base ? base : "/tmp") + "/" + g_cache_subdirectory;
  g_mkdir_with_parents(dir.c_str(), 0755);
  return dir;
}

std::string GetIndexFilePath() {
  return GetCacheRootDir() + "/cache_index_v1.tsv";
}

void EnsureIndexLoadedLocked() {
  if (g_index_loaded) return;
  g_index_loaded = true;
  g_entries.clear();

  std::ifstream in(GetIndexFilePath());
  if (!in.is_open()) return;

  std::string line;
  if (std::getline(in, line)) {
    std::istringstream ss(line);
    ss >> g_hit_count >> g_miss_count >> g_eviction_count;
  }
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::vector<std::string> parts;
    std::stringstream ss(line);
    std::string item;
    while (std::getline(ss, item, '\t')) {
      parts.push_back(item);
    }
    if (parts.size() >= 15) {
      LinuxCacheRecord rec;
      rec.key = parts[0];
      rec.url = parts[1];
      rec.file_path = parts[2];
      rec.size_bytes = std::stoll(parts[3]);
      rec.created_at_ms = std::stoll(parts[4]);
      rec.last_accessed_at_ms = std::stoll(parts[5]);
      rec.expires_at_ms = std::stoll(parts[6]);
      rec.hit_count = std::stoll(parts[7]);
      rec.tag = parts[8];
      rec.mime_type = parts[9];
      rec.etag = parts[10];
      rec.last_modified = parts[11];
      rec.checksum = parts[12];
      rec.checksum_algorithm = parts[13];
      rec.pinned = (parts[14] == "1");
      if (!rec.key.empty() &&
          g_file_test(rec.file_path.c_str(), G_FILE_TEST_EXISTS)) {
        g_entries[rec.key] = rec;
      }
    }
  }
}

void PersistIndexLocked() {
  std::ofstream out(GetIndexFilePath(), std::ios::trunc);
  if (!out.is_open()) return;
  out << g_hit_count << " " << g_miss_count << " " << g_eviction_count << "\n";
  for (const auto& kv : g_entries) {
    const auto& r = kv.second;
    out << r.key << "\t" << r.url << "\t" << r.file_path << "\t" << r.size_bytes
        << "\t" << r.created_at_ms << "\t" << r.last_accessed_at_ms << "\t"
        << r.expires_at_ms << "\t" << r.hit_count << "\t" << r.tag << "\t"
        << r.mime_type << "\t" << r.etag << "\t" << r.last_modified << "\t"
        << r.checksum << "\t" << r.checksum_algorithm << "\t"
        << (r.pinned ? "1" : "0") << "\n";
  }
}

std::string ResolveKeyLocked(const std::string& key_or_url,
                             const std::string& custom_key = "") {
  if (!custom_key.empty()) return custom_key;
  if (g_entries.find(key_or_url) != g_entries.end()) {
    return key_or_url;
  }
  return ComputeGLibHash(reinterpret_cast<const uint8_t*>(key_or_url.data()),
                         key_or_url.size(), "sha256");
}

int RemoveExpiredLocked() {
  int64_t now = CurrentTimeMs();
  std::vector<std::string> expired;
  for (const auto& kv : g_entries) {
    if (!kv.second.pinned && kv.second.IsExpired(now)) {
      expired.push_back(kv.first);
    }
  }
  for (const auto& k : expired) {
    std::remove(g_entries[k].file_path.c_str());
    g_entries.erase(k);
  }
  g_eviction_count += static_cast<int64_t>(expired.size());
  return static_cast<int>(expired.size());
}

int EnforceQuotaLocked(int64_t target_max_bytes,
                       const std::string& protected_key) {
  int evicted = RemoveExpiredLocked();
  if (g_eviction_policy == "ttlOnly") return evicted;

  int64_t total_bytes = 0;
  for (const auto& kv : g_entries) {
    total_bytes += kv.second.size_bytes;
  }
  if (total_bytes <= target_max_bytes &&
      static_cast<int>(g_entries.size()) <= g_max_entries) {
    return evicted;
  }

  std::vector<LinuxCacheRecord> candidates;
  for (const auto& kv : g_entries) {
    if (!kv.second.pinned && kv.first != protected_key) {
      candidates.push_back(kv.second);
    }
  }
  std::sort(candidates.begin(), candidates.end(),
            [](const LinuxCacheRecord& a, const LinuxCacheRecord& b) {
              if (g_eviction_policy == "lfu") {
                if (a.hit_count != b.hit_count) return a.hit_count < b.hit_count;
                return a.last_accessed_at_ms < b.last_accessed_at_ms;
              }
              if (g_eviction_policy == "fifo") {
                return a.created_at_ms < b.created_at_ms;
              }
              return a.last_accessed_at_ms < b.last_accessed_at_ms;
            });

  for (const auto& cand : candidates) {
    if (total_bytes <= target_max_bytes &&
        static_cast<int>(g_entries.size()) <= g_max_entries) {
      break;
    }
    std::remove(cand.file_path.c_str());
    total_bytes -= cand.size_bytes;
    g_entries.erase(cand.key);
    evicted++;
    g_eviction_count++;
  }
  return evicted;
}

void EmitProgress(XueHuaNaviteCacheManagerPlugin* self,
                  const std::string& key,
                  const std::string& url,
                  const std::string& state,
                  int64_t bytes_received,
                  int64_t total_bytes,
                  const std::string& file_path = "",
                  const std::string& error_msg = "") {
  if (!self || !self->is_listening || !self->event_channel) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "key", fl_value_new_string(key.c_str()));
  fl_value_set_string_take(map, "url", fl_value_new_string(url.c_str()));
  fl_value_set_string_take(map, "state", fl_value_new_string(state.c_str()));
  fl_value_set_string_take(map, "bytesReceived",
                           fl_value_new_int(bytes_received));
  fl_value_set_string_take(map, "totalBytes", fl_value_new_int(total_bytes));
  fl_value_set_string_take(map, "filePath",
                           file_path.empty()
                               ? fl_value_new_null()
                               : fl_value_new_string(file_path.c_str()));
  fl_value_set_string_take(map, "errorMessage",
                           error_msg.empty()
                               ? fl_value_new_null()
                               : fl_value_new_string(error_msg.c_str()));
  fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
}

bool DownloadViaCurlOrGio(const std::string& url,
                          const std::string& dest_tmp_path,
                          int timeout_sec,
                          const std::string& extra_headers,
                          std::string* out_err) {
  gchar* quoted_url = g_shell_quote(url.c_str());
  gchar* quoted_dest = g_shell_quote(dest_tmp_path.c_str());
  g_autofree gchar* cmd = g_strdup_printf(
      "curl -sS -L --fail --max-time %d%s -o %s %s",
      timeout_sec > 0 ? timeout_sec : 30, extra_headers.c_str(), quoted_dest,
      quoted_url);
  g_free(quoted_url);
  g_free(quoted_dest);

  gint exit_status = 0;
  g_autofree gchar* std_err = nullptr;
  GError* error = nullptr;
  gboolean spawned = g_spawn_command_line_sync(cmd, nullptr, &std_err,
                                               &exit_status, &error);
  if (spawned && exit_status == 0 &&
      g_file_test(dest_tmp_path.c_str(), G_FILE_TEST_EXISTS)) {
    return true;
  }
  if (error) {
    *out_err = error->message;
    g_error_free(error);
  } else if (std_err) {
    *out_err = std_err;
  } else {
    *out_err = "Network download failed";
  }
  return false;
}

struct DownloadRequest {
  std::string url;
  std::string custom_key;
  std::string tag;
  std::string file_ext;
  bool has_ttl = false;
  int64_t ttl_sec = 0;
  bool force_refresh = false;
  bool fallback_on_error = true;
  bool pinned = false;
  std::string checksum_alg = "none";
  std::string expected_checksum;
};

struct DownloadOutcome {
  bool ok = false;
  std::string error_code;
  std::string error_message;
  LinuxCacheRecord entry;
  std::string source;
  bool has_http_status = false;
  int http_status = 0;
  int64_t elapsed_ms = 0;
};

struct InFlightDownload {
  std::shared_ptr<std::atomic<bool>> cancel_flag =
      std::make_shared<std::atomic<bool>>(false);
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
};

std::map<std::string, std::shared_ptr<InFlightDownload>> g_in_flight;

class DownloadPool {
 public:
  DownloadPool() = default;
  DownloadPool(const DownloadPool&) = delete;
  DownloadPool& operator=(const DownloadPool&) = delete;

  ~DownloadPool() {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stopping_ = true;
    }
    cv_.notify_all();
    for (auto& worker : workers_) {
      if (worker.joinable()) worker.join();
    }
  }

  void SetLimit(int limit) {
    if (limit < 1) limit = 1;
    std::lock_guard<std::mutex> lock(mu_);
    limit_ = limit;
    EnsureWorkersLocked();
    cv_.notify_all();
  }

  bool Post(std::function<void()> job) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (stopping_) return false;
      EnsureWorkersLocked();
      jobs_.push(std::move(job));
    }
    cv_.notify_one();
    return true;
  }

 private:
  void EnsureWorkersLocked() {
    while (static_cast<int>(workers_.size()) < limit_) {
      workers_.emplace_back([this]() { Loop(); });
    }
  }

  void Loop() {
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [this]() {
          return (stopping_ && jobs_.empty()) ||
                 (!jobs_.empty() && active_ < limit_);
        });
        if (jobs_.empty()) return;
        job = std::move(jobs_.front());
        jobs_.pop();
        active_ += 1;
      }
      try {
        job();
      } catch (...) {
      }
      {
        std::lock_guard<std::mutex> lock(mu_);
        active_ -= 1;
      }
      cv_.notify_all();
    }
  }

  std::mutex mu_;
  std::condition_variable cv_;
  std::queue<std::function<void()>> jobs_;
  std::vector<std::thread> workers_;
  int limit_ = 4;
  int active_ = 0;
  bool stopping_ = false;
};

DownloadPool& GetDownloadPool() {
  static DownloadPool pool;
  return pool;
}

struct ProgressPayload {
  XueHuaNaviteCacheManagerPlugin* self = nullptr;
  std::string key;
  std::string url;
  std::string state;
  std::string file_path;
  std::string error;
  int64_t bytes = 0;
  int64_t total = 0;
};

static gboolean ProgressOnMain(gpointer data) {
  std::unique_ptr<ProgressPayload> payload(static_cast<ProgressPayload*>(data));
  EmitProgress(payload->self, payload->key, payload->url, payload->state,
               payload->bytes, payload->total, payload->file_path,
               payload->error);
  g_object_unref(payload->self);
  return G_SOURCE_REMOVE;
}

void PostProgress(XueHuaNaviteCacheManagerPlugin* self,
                  const std::string& key,
                  const std::string& url,
                  const std::string& state,
                  int64_t bytes,
                  int64_t total,
                  const std::string& file_path = "",
                  const std::string& error = "") {
  if (!self) return;
  auto* payload = new ProgressPayload();
  payload->self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(g_object_ref(self));
  payload->key = key;
  payload->url = url;
  payload->state = state;
  payload->bytes = bytes;
  payload->total = total;
  payload->file_path = file_path;
  payload->error = error;
  g_idle_add(ProgressOnMain, payload);
}

DownloadOutcome MakeFailure(const std::string& code, const std::string& message) {
  DownloadOutcome out;
  out.ok = false;
  out.error_code = code;
  out.error_message = message;
  return out;
}

DownloadOutcome MakeSuccess(const LinuxCacheRecord& entry,
                            const std::string& source,
                            bool has_http_status,
                            int http_status,
                            int64_t elapsed_ms) {
  DownloadOutcome out;
  out.ok = true;
  out.entry = entry;
  out.source = source;
  out.has_http_status = has_http_status;
  out.http_status = http_status;
  out.elapsed_ms = elapsed_ms;
  return out;
}

DownloadRequest ParseDownloadRequest(FlValue* args) {
  DownloadRequest request;
  request.url = GetFlString(args, "url");
  request.custom_key = GetFlString(args, "customKey");
  request.tag = GetFlString(args, "tag");
  request.file_ext = GetFlString(args, "fileExtension");
  request.has_ttl = HasFlKey(args, "ttlSeconds");
  request.ttl_sec = GetFlInt(args, "ttlSeconds", g_default_ttl_seconds);
  request.force_refresh = GetFlBool(args, "forceRefresh", false);
  request.fallback_on_error = GetFlBool(args, "fallbackToCacheOnError", true);
  request.pinned = GetFlBool(args, "pinned", false);
  request.checksum_alg = GetFlString(args, "checksumAlgorithm", "none");
  request.expected_checksum = GetFlString(args, "expectedChecksum");
  return request;
}

FlMethodResponse* OutcomeToResponse(const DownloadOutcome& outcome) {
  if (!outcome.ok) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        outcome.error_code.c_str(), outcome.error_message.c_str(), nullptr));
  }
  g_autoptr(FlValue) res = fl_value_new_map();
  fl_value_set_string_take(res, "entry", outcome.entry.ToFlValue());
  fl_value_set_string_take(res, "source",
                           fl_value_new_string(outcome.source.c_str()));
  if (outcome.has_http_status) {
    fl_value_set_string_take(res, "httpStatusCode",
                             fl_value_new_int(outcome.http_status));
  } else {
    fl_value_set_string_take(res, "httpStatusCode", fl_value_new_null());
  }
  fl_value_set_string_take(res, "elapsedMs", fl_value_new_int(outcome.elapsed_ms));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
}

struct AsyncDownloadReply {
  FlMethodCall* method_call = nullptr;
  DownloadOutcome outcome;
};

static gboolean DeliverDownloadReply(gpointer data) {
  std::unique_ptr<AsyncDownloadReply> reply(static_cast<AsyncDownloadReply*>(data));
  g_autoptr(FlMethodResponse) response = OutcomeToResponse(reply->outcome);
  fl_method_call_respond(reply->method_call, response, nullptr);
  g_object_unref(reply->method_call);
  return G_SOURCE_REMOVE;
}

struct AsyncPrefetchReply {
  FlMethodCall* method_call = nullptr;
  std::vector<DownloadOutcome> outcomes;
};

static gboolean DeliverPrefetchReply(gpointer data) {
  std::unique_ptr<AsyncPrefetchReply> reply(static_cast<AsyncPrefetchReply*>(data));
  g_autoptr(FlValue) list = fl_value_new_list();
  for (const auto& outcome : reply->outcomes) {
    if (!outcome.ok) continue;
    fl_value_append_take(list, outcome.entry.ToFlValue());
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  fl_method_call_respond(reply->method_call, response, nullptr);
  g_object_unref(reply->method_call);
  return G_SOURCE_REMOVE;
}

DownloadOutcome ExecuteDownload(
    XueHuaNaviteCacheManagerPlugin* self,
    const DownloadRequest& request,
    const std::string& key,
    const std::shared_ptr<std::atomic<bool>>& cancel_flag) {
  const int64_t start_ms = CurrentTimeMs();
  LinuxCacheRecord existing;
  bool has_existing = false;

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    auto it = g_entries.find(key);
    if (it != g_entries.end() &&
        g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS)) {
      existing = it->second;
      has_existing = true;
      if (!request.force_refresh && !it->second.IsExpired(start_ms)) {
        it->second.last_accessed_at_ms = start_ms;
        it->second.hit_count++;
        if (!request.tag.empty()) it->second.tag = request.tag;
        if (request.pinned) it->second.pinned = true;
        g_hit_count++;
        PersistIndexLocked();
        existing = it->second;
        // Emit after releasing the lock, via the main loop.
        has_existing = true;
        PostProgress(self, key, request.url, "cacheHit", existing.size_bytes,
                     existing.size_bytes, existing.file_path);
        return MakeSuccess(existing, "cacheHit", false, 0,
                           CurrentTimeMs() - start_ms);
      }
    }
    g_miss_count++;
  }

  if (cancel_flag && cancel_flag->load()) {
    PostProgress(self, key, request.url, "canceled", 0, -1, "",
                 "Download canceled");
    return MakeFailure("CANCELED", "Download canceled");
  }

  PostProgress(self, key, request.url, "started", 0, -1);
  std::string tmp_path = GetCacheRootDir() + "/" + key + ".tmp";
  std::string dl_err;
  int timeout_sec = (g_connect_timeout_ms + g_read_timeout_ms) / 1000;

  std::string extra_headers;
  if (g_respect_http_cache_headers && has_existing) {
    if (!existing.etag.empty()) {
      std::string hdr = "If-None-Match: " + existing.etag;
      gchar* quoted = g_shell_quote(hdr.c_str());
      extra_headers += " -H ";
      extra_headers += quoted;
      g_free(quoted);
    }
    if (!existing.last_modified.empty()) {
      std::string hdr = "If-Modified-Since: " + existing.last_modified;
      gchar* quoted = g_shell_quote(hdr.c_str());
      extra_headers += " -H ";
      extra_headers += quoted;
      g_free(quoted);
    }
  }

  if (!DownloadViaCurlOrGio(request.url, tmp_path, timeout_sec, extra_headers,
                            &dl_err)) {
    std::remove(tmp_path.c_str());
    if (cancel_flag && cancel_flag->load()) {
      PostProgress(self, key, request.url, "canceled", 0, -1, "",
                   "Download canceled");
      return MakeFailure("CANCELED", "Download canceled");
    }
    if (request.fallback_on_error && has_existing) {
      return MakeSuccess(existing, "staleCacheFallback", false, 0,
                         CurrentTimeMs() - start_ms);
    }
    PostProgress(self, key, request.url, "failed", 0, -1, "", dl_err);
    return MakeFailure("DOWNLOAD_FAILED", dl_err);
  }

  if (cancel_flag && cancel_flag->load()) {
    std::remove(tmp_path.c_str());
    PostProgress(self, key, request.url, "canceled", 0, -1, "",
                 "Download canceled");
    return MakeFailure("CANCELED", "Download canceled");
  }

  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(tmp_path.c_str(), &contents, &length, nullptr)) {
    std::remove(tmp_path.c_str());
    return MakeFailure("READ_ERROR", "Failed to read downloaded file");
  }

  std::string computed_hash;
  if (request.checksum_alg != "none") {
    computed_hash = ComputeGLibHash(reinterpret_cast<const uint8_t*>(contents),
                                    length, request.checksum_alg);
    if (!request.expected_checksum.empty() &&
        computed_hash != request.expected_checksum) {
      g_free(contents);
      std::remove(tmp_path.c_str());
      PostProgress(self, key, request.url, "failed", 0, -1, "",
                   "Checksum mismatch");
      return MakeFailure("CHECKSUM_MISMATCH", "Checksum verification failed");
    }
  }
  g_free(contents);

  std::string ext = InferExtension(request.url, "", request.file_ext);
  std::string final_path = GetCacheRootDir() + "/" + key + "." + ext;
  std::rename(tmp_path.c_str(), final_path.c_str());

  int64_t now = CurrentTimeMs();
  LinuxCacheRecord rec;
  rec.key = key;
  rec.url = request.url;
  rec.file_path = final_path;
  rec.size_bytes = static_cast<int64_t>(length);
  rec.created_at_ms = now;
  rec.last_accessed_at_ms = now;
  rec.expires_at_ms =
      now + (request.has_ttl ? request.ttl_sec : g_default_ttl_seconds) * 1000LL;
  rec.hit_count = 1;
  rec.tag = request.tag;
  rec.mime_type = "application/octet-stream";
  rec.checksum = computed_hash;
  rec.checksum_algorithm = request.checksum_alg;
  rec.pinned = request.pinned;

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_entries[key] = rec;
    if (g_auto_trim_on_write) {
      EnforceQuotaLocked(g_max_disk_cache_bytes, key);
    }
    PersistIndexLocked();
  }

  PostProgress(self, key, request.url, "completed", rec.size_bytes,
               rec.size_bytes, rec.file_path);
  return MakeSuccess(rec, "networkDownload", true, 200, CurrentTimeMs() - start_ms);
}

void FinishInFlight(const std::string& key,
                    const std::shared_ptr<InFlightDownload>& state,
                    const DownloadOutcome& outcome) {
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_in_flight.find(key);
    if (it != g_in_flight.end() && it->second == state) {
      waiters.swap(it->second->waiters);
      g_in_flight.erase(it);
    } else if (state) {
      waiters.swap(state->waiters);
    }
  }
  for (const auto& waiter : waiters) {
    waiter(outcome);
  }
}

void ScheduleDownload(XueHuaNaviteCacheManagerPlugin* self,
                      const DownloadRequest& request,
                      std::function<void(const DownloadOutcome&)> callback) {
  if (request.url.empty()) {
    callback(MakeFailure("INVALID_URL", "URL is required"));
    return;
  }

  std::string key;
  DownloadOutcome early;
  bool has_early = false;
  std::shared_ptr<InFlightDownload> state;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    key = ResolveKeyLocked(request.url, request.custom_key);
    if (!request.force_refresh) {
      auto it = g_entries.find(key);
      const int64_t now = CurrentTimeMs();
      if (it != g_entries.end() &&
          g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS) &&
          !it->second.IsExpired(now)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        if (!request.tag.empty()) it->second.tag = request.tag;
        if (request.pinned) it->second.pinned = true;
        g_hit_count++;
        PersistIndexLocked();
        early = MakeSuccess(it->second, "cacheHit", false, 0, 0);
        has_early = true;
      }
    }
    if (!has_early) {
      auto existing = g_in_flight.find(key);
      if (existing != g_in_flight.end()) {
        existing->second->waiters.push_back(std::move(callback));
        return;
      }
      state = std::make_shared<InFlightDownload>();
      state->waiters.push_back(std::move(callback));
      g_in_flight[key] = state;
    }
  }

  if (has_early) {
    EmitProgress(self, key, request.url, "cacheHit", early.entry.size_bytes,
                 early.entry.size_bytes, early.entry.file_path);
    callback(early);
    return;
  }

  XueHuaNaviteCacheManagerPlugin* plugin =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(g_object_ref(self));
  const bool queued = GetDownloadPool().Post([plugin, request, key, state]() {
    DownloadOutcome outcome;
    try {
      if (state->cancel_flag->load()) {
        outcome = MakeFailure("CANCELED", "Download canceled");
        PostProgress(plugin, key, request.url, "canceled", 0, -1, "",
                     "Download canceled");
      } else {
        outcome = ExecuteDownload(plugin, request, key, state->cancel_flag);
      }
    } catch (const std::exception& ex) {
      outcome = MakeFailure("DOWNLOAD_FAILED", ex.what());
    } catch (...) {
      outcome = MakeFailure("DOWNLOAD_FAILED", "Download failed");
    }
    FinishInFlight(key, state, outcome);
    g_object_unref(plugin);
  });
  if (!queued) {
    FinishInFlight(key, state, MakeFailure("DOWNLOAD_FAILED", "Download pool is stopping"));
    g_object_unref(plugin);
  }
}

void ScheduleDownloadReply(XueHuaNaviteCacheManagerPlugin* self,
                           FlMethodCall* method_call,
                           const DownloadRequest& request) {
  g_object_ref(method_call);
  ScheduleDownload(self, request, [method_call](const DownloadOutcome& outcome) {
    auto* reply = new AsyncDownloadReply();
    reply->method_call = method_call;
    reply->outcome = outcome;
    g_idle_add(DeliverDownloadReply, reply);
  });
}

void SchedulePrefetchReply(XueHuaNaviteCacheManagerPlugin* self,
                           FlMethodCall* method_call,
                           const std::vector<DownloadRequest>& requests) {
  g_object_ref(method_call);
  if (requests.empty()) {
    auto* reply = new AsyncPrefetchReply();
    reply->method_call = method_call;
    g_idle_add(DeliverPrefetchReply, reply);
    return;
  }
  struct PrefetchState {
    std::mutex mu;
    int remaining = 0;
    std::vector<DownloadOutcome> slots;
    bool posted = false;
  };
  auto prefetch_state = std::make_shared<PrefetchState>();
  prefetch_state->remaining = static_cast<int>(requests.size());
  prefetch_state->slots.resize(requests.size());
  for (size_t index = 0; index < requests.size(); ++index) {
    ScheduleDownload(
        self, requests[index],
        [method_call, prefetch_state, index](const DownloadOutcome& outcome) {
          bool done = false;
          std::vector<DownloadOutcome> slots;
          {
            std::lock_guard<std::mutex> lock(prefetch_state->mu);
            prefetch_state->slots[index] = outcome;
            prefetch_state->remaining -= 1;
            if (prefetch_state->remaining == 0 && !prefetch_state->posted) {
              prefetch_state->posted = true;
              done = true;
              slots = prefetch_state->slots;
            }
          }
          if (done) {
            auto* reply = new AsyncPrefetchReply();
            reply->method_call = method_call;
            reply->outcomes = std::move(slots);
            g_idle_add(DeliverPrefetchReply, reply);
          }
        });
  }
}

}  // namespace

FlMethodResponse* get_capabilities_response() {
  g_autoptr(FlValue) caps = fl_value_new_map();
  fl_value_set_string_take(caps, "platformName", fl_value_new_string("linux"));
  fl_value_set_string_take(caps, "supportsFileSystemPaths",
                           fl_value_new_bool(true));
  fl_value_set_string_take(caps, "supportsConditionalHttpRevalidation",
                           fl_value_new_bool(true));
  fl_value_set_string_take(caps, "supportsNativeCryptoHash",
                           fl_value_new_bool(true));
  fl_value_set_string_take(caps, "supportsLowDiskSpaceNotifications",
                           fl_value_new_bool(false));
  fl_value_set_string_take(
      caps, "storageMechanism",
      fl_value_new_string("XDG_CACHE_HOME (g_get_user_cache_dir) + GChecksum"));
  fl_value_set_string_take(caps, "defaultCacheRootPath",
                           fl_value_new_string(GetCacheRootDir().c_str()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(caps));
}

static void xue_hua_navite_cache_manager_plugin_handle_method_call(
    XueHuaNaviteCacheManagerPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "configure") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    g_max_disk_cache_bytes =
        GetFlInt(args, "maxDiskCacheBytes", g_max_disk_cache_bytes);
    g_max_entries =
        static_cast<int>(GetFlInt(args, "maxEntries", g_max_entries));
    g_default_ttl_seconds =
        GetFlInt(args, "defaultTtlSeconds", g_default_ttl_seconds);
    g_eviction_policy = GetFlString(args, "evictionPolicy", g_eviction_policy);
    std::string subdir =
        GetFlString(args, "cacheSubdirectory", g_cache_subdirectory);
    if (!subdir.empty()) g_cache_subdirectory = subdir;
    g_auto_trim_on_write =
        GetFlBool(args, "autoTrimOnWrite", g_auto_trim_on_write);
    g_respect_http_cache_headers = GetFlBool(
        args, "respectHttpCacheHeaders", g_respect_http_cache_headers);
    g_connect_timeout_ms = static_cast<int>(
        GetFlInt(args, "connectTimeoutMs", g_connect_timeout_ms));
    g_read_timeout_ms = static_cast<int>(
        GetFlInt(args, "readTimeoutMs", g_read_timeout_ms));
    if (HasFlKey(args, "maxConcurrentDownloads")) {
      int conc = static_cast<int>(
          GetFlInt(args, "maxConcurrentDownloads", g_max_concurrent_downloads));
      if (conc < 1) conc = 1;
      g_max_concurrent_downloads = conc;
      GetDownloadPool().SetLimit(conc);
    }
    if (g_auto_trim_on_write) {
      EnforceQuotaLocked(g_max_disk_cache_bytes, "");
      PersistIndexLocked();
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "downloadFile") == 0) {
    DownloadRequest request = ParseDownloadRequest(args);
    ScheduleDownloadReply(self, method_call, request);
    return;
  } else if (strcmp(method, "prefetchAll") == 0) {
    std::vector<DownloadRequest> requests;
    FlValue* reqs = fl_value_lookup_string(args, "requests");
    if (reqs && fl_value_get_type(reqs) == FL_VALUE_TYPE_LIST) {
      size_t len = fl_value_get_length(reqs);
      requests.reserve(len);
      for (size_t i = 0; i < len; ++i) {
        requests.push_back(ParseDownloadRequest(fl_value_get_list_value(reqs, i)));
      }
    }
    SchedulePrefetchReply(self, method_call, requests);
    return;
  } else if (strcmp(method, "cancelDownload") == 0) {
    std::string key_or_url = GetFlString(args, "keyOrUrl");
    bool canceled = false;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      EnsureIndexLoadedLocked();
      std::string key = ResolveKeyLocked(key_or_url);
      auto it = g_in_flight.find(key);
      if (it == g_in_flight.end()) it = g_in_flight.find(key_or_url);
      if (it != g_in_flight.end()) {
        it->second->cancel_flag->store(true);
        canceled = true;
      }
    }
    g_autoptr(FlValue) res = fl_value_new_bool(canceled);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "getFileFromCache") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    std::string key = ResolveKeyLocked(GetFlString(args, "keyOrUrl"));
    bool ignore_expired = GetFlBool(args, "ignoreExpired", true);
    auto it = g_entries.find(key);
    int64_t now = CurrentTimeMs();
    if (it == g_entries.end() ||
        !g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS) ||
        (ignore_expired && it->second.IsExpired(now))) {
      g_miss_count++;
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      it->second.last_accessed_at_ms = now;
      it->second.hit_count++;
      g_hit_count++;
      PersistIndexLocked();
      g_autoptr(FlValue) map = it->second.ToFlValue();
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(map));
    }
  } else if (strcmp(method, "readCacheBytes") == 0) {
    std::string file_path;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      EnsureIndexLoadedLocked();
      std::string key = ResolveKeyLocked(GetFlString(args, "keyOrUrl"));
      bool ignore_expired = GetFlBool(args, "ignoreExpired", true);
      auto it = g_entries.find(key);
      int64_t now = CurrentTimeMs();
      if (it != g_entries.end() &&
          (!ignore_expired || !it->second.IsExpired(now)) &&
          g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        g_hit_count++;
        PersistIndexLocked();
        file_path = it->second.file_path;
      } else {
        g_miss_count++;
      }
    }
    if (file_path.empty()) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      gchar* contents = nullptr;
      gsize length = 0;
      if (g_file_get_contents(file_path.c_str(), &contents, &length, nullptr)) {
        g_autoptr(FlValue) bytes = fl_value_new_uint8_list(
            reinterpret_cast<const uint8_t*>(contents), length);
        g_free(contents);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(bytes));
      } else {
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      }
    }
  } else if (strcmp(method, "containsKey") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    std::string key = ResolveKeyLocked(GetFlString(args, "keyOrUrl"));
    bool ignore_expired = GetFlBool(args, "ignoreExpired", true);
    auto it = g_entries.find(key);
    bool exists =
        it != g_entries.end() &&
        g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS) &&
        (!ignore_expired || !it->second.IsExpired(CurrentTimeMs()));
    g_autoptr(FlValue) val = fl_value_new_bool(exists);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  } else if (strcmp(method, "putBytes") == 0) {
    std::string key = GetFlString(args, "key");
    FlValue* bytes_val = fl_value_lookup_string(args, "bytes");
    if (key.empty() || !bytes_val ||
        fl_value_get_type(bytes_val) != FL_VALUE_TYPE_UINT8_LIST) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "INVALID_ARGS", "key and bytes are required", nullptr));
    } else {
      const uint8_t* raw = fl_value_get_uint8_list(bytes_val);
      size_t len = fl_value_get_length(bytes_val);
      std::string url = GetFlString(args, "url", "local://" + key);
      std::string file_ext = GetFlString(args, "fileExtension");
      std::string mime_type =
          GetFlString(args, "mimeType", "application/octet-stream");
      std::string tag = GetFlString(args, "tag");
      int64_t ttl_sec = GetFlInt(args, "ttlSeconds", g_default_ttl_seconds);
      bool pinned = GetFlBool(args, "pinned", false);

      std::string ext = InferExtension(url, mime_type, file_ext);
      std::string dest_path = GetCacheRootDir() + "/" + key + "." + ext;
      g_file_set_contents(dest_path.c_str(),
                          reinterpret_cast<const gchar*>(raw), len, nullptr);

      int64_t now = CurrentTimeMs();
      LinuxCacheRecord rec;
      rec.key = key;
      rec.url = url;
      rec.file_path = dest_path;
      rec.size_bytes = static_cast<int64_t>(len);
      rec.created_at_ms = now;
      rec.last_accessed_at_ms = now;
      rec.expires_at_ms = now + ttl_sec * 1000LL;
      rec.hit_count = 1;
      rec.tag = tag;
      rec.mime_type = mime_type;
      rec.checksum = ComputeGLibHash(raw, len, "sha256");
      rec.checksum_algorithm = "sha256";
      rec.pinned = pinned;

      {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureIndexLoadedLocked();
        g_entries[key] = rec;
        if (g_auto_trim_on_write) {
          EnforceQuotaLocked(g_max_disk_cache_bytes, key);
        }
        PersistIndexLocked();
      }
      g_autoptr(FlValue) out_map = rec.ToFlValue();
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(out_map));
    }
  } else if (strcmp(method, "putFile") == 0) {
    std::string key = GetFlString(args, "key");
    std::string source_path = GetFlString(args, "sourceFilePath");
    gchar* contents = nullptr;
    gsize len = 0;
    if (key.empty() || source_path.empty() ||
        !g_file_get_contents(source_path.c_str(), &contents, &len, nullptr)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "INVALID_SOURCE", "Source file does not exist", nullptr));
    } else {
      std::string url = GetFlString(args, "url", "file://" + source_path);
      std::string file_ext = GetFlString(args, "fileExtension");
      std::string mime_type =
          GetFlString(args, "mimeType", "application/octet-stream");
      std::string tag = GetFlString(args, "tag");
      int64_t ttl_sec = GetFlInt(args, "ttlSeconds", g_default_ttl_seconds);
      bool pinned = GetFlBool(args, "pinned", false);

      std::string ext = InferExtension(url, mime_type, file_ext);
      std::string dest_path = GetCacheRootDir() + "/" + key + "." + ext;
      g_file_set_contents(dest_path.c_str(), contents, len, nullptr);

      int64_t now = CurrentTimeMs();
      LinuxCacheRecord rec;
      rec.key = key;
      rec.url = url;
      rec.file_path = dest_path;
      rec.size_bytes = static_cast<int64_t>(len);
      rec.created_at_ms = now;
      rec.last_accessed_at_ms = now;
      rec.expires_at_ms = now + ttl_sec * 1000LL;
      rec.hit_count = 1;
      rec.tag = tag;
      rec.mime_type = mime_type;
      rec.checksum = ComputeGLibHash(reinterpret_cast<const uint8_t*>(contents),
                                     len, "sha256");
      rec.checksum_algorithm = "sha256";
      rec.pinned = pinned;
      g_free(contents);

      {
        std::lock_guard<std::mutex> lock(g_mutex);
        EnsureIndexLoadedLocked();
        g_entries[key] = rec;
        if (g_auto_trim_on_write) {
          EnforceQuotaLocked(g_max_disk_cache_bytes, key);
        }
        PersistIndexLocked();
      }
      g_autoptr(FlValue) out_map = rec.ToFlValue();
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(out_map));
    }
  } else if (strcmp(method, "setPinned") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    std::string key = ResolveKeyLocked(GetFlString(args, "keyOrUrl"));
    bool pinned = GetFlBool(args, "pinned", false);
    auto it = g_entries.find(key);
    if (it == g_entries.end()) {
      g_autoptr(FlValue) res = fl_value_new_bool(false);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
    } else {
      it->second.pinned = pinned;
      PersistIndexLocked();
      g_autoptr(FlValue) res = fl_value_new_bool(true);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
    }
  } else if (strcmp(method, "removeFile") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    std::string key = ResolveKeyLocked(GetFlString(args, "keyOrUrl"));
    auto it = g_entries.find(key);
    if (it == g_entries.end()) {
      g_autoptr(FlValue) res = fl_value_new_bool(false);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
    } else {
      std::remove(it->second.file_path.c_str());
      g_entries.erase(it);
      PersistIndexLocked();
      g_autoptr(FlValue) res = fl_value_new_bool(true);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
    }
  } else if (strcmp(method, "removeByTag") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    std::string tag = GetFlString(args, "tag");
    std::vector<std::string> keys;
    for (const auto& kv : g_entries) {
      if (kv.second.tag == tag) keys.push_back(kv.first);
    }
    for (const auto& k : keys) {
      std::remove(g_entries[k].file_path.c_str());
      g_entries.erase(k);
    }
    if (!keys.empty()) PersistIndexLocked();
    g_autoptr(FlValue) res = fl_value_new_int(static_cast<int64_t>(keys.size()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "removeExpired") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    int removed = RemoveExpiredLocked();
    if (removed > 0) PersistIndexLocked();
    g_autoptr(FlValue) res = fl_value_new_int(removed);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "trimToSize") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    int64_t max_bytes = GetFlInt(args, "maxBytes", g_max_disk_cache_bytes);
    int evicted = EnforceQuotaLocked(max_bytes, "");
    if (evicted > 0) PersistIndexLocked();
    g_autoptr(FlValue) res = fl_value_new_int(evicted);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "clearAll") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    bool include_pinned = GetFlBool(args, "includePinned", true);
    std::vector<std::string> keys;
    for (const auto& kv : g_entries) {
      if (include_pinned || !kv.second.pinned) keys.push_back(kv.first);
    }
    for (const auto& k : keys) {
      std::remove(g_entries[k].file_path.c_str());
      g_entries.erase(k);
    }
    PersistIndexLocked();
    g_autoptr(FlValue) res = fl_value_new_int(static_cast<int64_t>(keys.size()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
  } else if (strcmp(method, "listEntries") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    bool has_tag = HasFlKey(args, "tag");
    std::string tag = GetFlString(args, "tag");
    bool include_expired = GetFlBool(args, "includeExpired", true);
    int64_t now = CurrentTimeMs();

    std::vector<LinuxCacheRecord> filtered;
    for (const auto& kv : g_entries) {
      if ((!has_tag || kv.second.tag == tag) &&
          (include_expired || !kv.second.IsExpired(now))) {
        filtered.push_back(kv.second);
      }
    }
    std::sort(filtered.begin(), filtered.end(),
              [](const LinuxCacheRecord& a, const LinuxCacheRecord& b) {
                return a.last_accessed_at_ms > b.last_accessed_at_ms;
              });
    g_autoptr(FlValue) list = fl_value_new_list();
    for (const auto& r : filtered) {
      fl_value_append_take(list, r.ToFlValue());
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "getStats") == 0) {
    std::lock_guard<std::mutex> lock(g_mutex);
    EnsureIndexLoadedLocked();
    int64_t now = CurrentTimeMs();
    int64_t total_bytes = 0;
    int expired_count = 0;
    int pinned_count = 0;
    std::map<std::string, int64_t> tag_sums;

    for (const auto& kv : g_entries) {
      total_bytes += kv.second.size_bytes;
      if (kv.second.IsExpired(now)) expired_count++;
      if (kv.second.pinned) pinned_count++;
      std::string t = kv.second.tag.empty() ? "untagged" : kv.second.tag;
      tag_sums[t] += kv.second.size_bytes;
    }

    FlValue* bytes_by_tag = fl_value_new_map();
    for (const auto& tkv : tag_sums) {
      fl_value_set_string_take(bytes_by_tag, tkv.first.c_str(),
                               fl_value_new_int(tkv.second));
    }

    g_autoptr(FlValue) stats = fl_value_new_map();
    fl_value_set_string_take(stats, "totalEntries",
                             fl_value_new_int(g_entries.size()));
    fl_value_set_string_take(stats, "totalBytes",
                             fl_value_new_int(total_bytes));
    fl_value_set_string_take(stats, "expiredEntries",
                             fl_value_new_int(expired_count));
    fl_value_set_string_take(stats, "pinnedEntries",
                             fl_value_new_int(pinned_count));
    fl_value_set_string_take(stats, "maxDiskCacheBytes",
                             fl_value_new_int(g_max_disk_cache_bytes));
    fl_value_set_string_take(stats, "cacheDirectoryPath",
                             fl_value_new_string(GetCacheRootDir().c_str()));
    fl_value_set_string_take(stats, "hitCount", fl_value_new_int(g_hit_count));
    fl_value_set_string_take(stats, "missCount",
                             fl_value_new_int(g_miss_count));
    fl_value_set_string_take(stats, "evictionCount",
                             fl_value_new_int(g_eviction_count));
    fl_value_set_string_take(stats, "bytesByTag", bytes_by_tag);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(stats));
  } else if (strcmp(method, "getCapabilities") == 0) {
    response = get_capabilities_response();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static FlMethodErrorResponse* event_channel_listen_cb(FlEventChannel* channel,
                                                      FlValue* args,
                                                      gpointer user_data) {
  XueHuaNaviteCacheManagerPlugin* plugin =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  plugin->is_listening = true;
  return nullptr;
}

static FlMethodErrorResponse* event_channel_cancel_cb(FlEventChannel* channel,
                                                      FlValue* args,
                                                      gpointer user_data) {
  XueHuaNaviteCacheManagerPlugin* plugin =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  plugin->is_listening = false;
  return nullptr;
}

static void xue_hua_navite_cache_manager_plugin_dispose(GObject* object) {
  XueHuaNaviteCacheManagerPlugin* self =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(object);
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(xue_hua_navite_cache_manager_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_navite_cache_manager_plugin_class_init(
    XueHuaNaviteCacheManagerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_navite_cache_manager_plugin_dispose;
}

static void xue_hua_navite_cache_manager_plugin_init(
    XueHuaNaviteCacheManagerPlugin* self) {
  self->event_channel = nullptr;
  self->is_listening = false;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  XueHuaNaviteCacheManagerPlugin* plugin =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  xue_hua_navite_cache_manager_plugin_handle_method_call(plugin, method_call);
}

void xue_hua_navite_cache_manager_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  XueHuaNaviteCacheManagerPlugin* plugin = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(
      g_object_new(xue_hua_navite_cache_manager_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "xue_hua_navite_cache_manager",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "xue_hua_navite_cache_manager/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->event_channel, event_channel_listen_cb, event_channel_cancel_cb,
      g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
