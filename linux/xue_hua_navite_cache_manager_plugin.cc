#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <glib.h>
#include <gtk/gtk.h>

#include <algorithm>
#include <atomic>
#include <cctype>
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
#include <optional>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "messages.g.h"
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

std::string AsciiLower(const std::string& in) {
  std::string out = in;
  for (char& c : out) {
    c = static_cast<char>(g_ascii_tolower(static_cast<gchar>(c)));
  }
  return out;
}

std::string TrimAscii(const std::string& in) {
  size_t begin = 0;
  while (begin < in.size() &&
         (in[begin] == ' ' || in[begin] == '\t' || in[begin] == '\r' ||
          in[begin] == '\n')) {
    begin++;
  }
  size_t end = in.size();
  while (end > begin &&
         (in[end - 1] == ' ' || in[end - 1] == '\t' || in[end - 1] == '\r' ||
          in[end - 1] == '\n')) {
    end--;
  }
  return in.substr(begin, end - begin);
}

std::string SanitizeTsvField(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (char ch : value) {
    if (ch == '\t' || ch == '\r' || ch == '\n') {
      out.push_back(' ');
    } else {
      out.push_back(ch);
    }
  }
  return out;
}

std::string SanitizeHeaderValue(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (char ch : value) {
    if (ch != '\r' && ch != '\n' && ch != '\0') {
      out.push_back(ch);
    }
  }
  return out;
}

std::string SanitizeHeaderName(const std::string& name) {
  std::string out;
  out.reserve(name.size());
  for (char ch : name) {
    if (ch == ':' || ch == '\r' || ch == '\n' || ch == '\0' ||
        std::isspace(static_cast<unsigned char>(ch))) {
      continue;
    }
    out.push_back(ch);
  }
  return out;
}

std::string ChecksumAlgToString(XueHuaCacheWireCacheChecksumAlgorithm alg) {
  switch (alg) {
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_MD5:
      return "md5";
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_SHA256:
      return "sha256";
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_NONE:
    default:
      return "none";
  }
}

XueHuaCacheWireCacheChecksumAlgorithm WireChecksumFromString(
    const std::string& raw) {
  const std::string lower = AsciiLower(raw);
  if (lower == "md5") {
    return XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_MD5;
  }
  if (lower == "sha256") {
    return XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_SHA256;
  }
  return XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_NONE;
}

std::string EvictionPolicyToString(
    XueHuaCacheWireCacheEvictionPolicy policy) {
  switch (policy) {
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_EVICTION_POLICY_LFU:
      return "lfu";
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_EVICTION_POLICY_FIFO:
      return "fifo";
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_EVICTION_POLICY_TTL_ONLY:
      return "ttlOnly";
    case XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_EVICTION_POLICY_LRU:
    default:
      return "lru";
  }
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

  XueHuaCacheWireCacheEntry* ToWireEntry() const {
    return xue_hua_cache_wire_cache_entry_new(
        key.c_str(), url.c_str(), file_path.c_str(), size_bytes, created_at_ms,
        last_accessed_at_ms, expires_at_ms, hit_count,
        tag.empty() ? nullptr : tag.c_str(),
        mime_type.empty() ? nullptr : mime_type.c_str(),
        etag.empty() ? nullptr : etag.c_str(),
        last_modified.empty() ? nullptr : last_modified.c_str(),
        checksum.empty() ? nullptr : checksum.c_str(),
        WireChecksumFromString(checksum_algorithm), pinned ? TRUE : FALSE);
  }
};

std::string ComputeGLibHash(const uint8_t* data,
                            size_t length,
                            const std::string& algorithm) {
  GChecksumType type = (AsciiLower(algorithm) == "md5") ? G_CHECKSUM_MD5
                                                        : G_CHECKSUM_SHA256;
  const uint8_t empty_byte = 0;
  const uint8_t* ptr = (length > 0 && data != nullptr) ? data : &empty_byte;
  gchar* hex = g_compute_checksum_for_data(type, ptr, length);
  if (!hex) return "";
  std::string out(hex);
  g_free(hex);
  return out;
}

std::string InferExtension(const std::string& url,
                           const std::string& mime_type,
                           const std::string& explicit_ext) {
  std::string clean_ext = TrimAscii(explicit_ext);
  while (!clean_ext.empty() && clean_ext.front() == '.') {
    clean_ext.erase(clean_ext.begin());
  }
  if (!clean_ext.empty()) {
    return AsciiLower(clean_ext);
  }
  auto q_pos = url.find_first_of("?#");
  std::string path = (q_pos == std::string::npos) ? url : url.substr(0, q_pos);
  auto slash_pos = path.find_last_of('/');
  std::string filename =
      (slash_pos == std::string::npos) ? path : path.substr(slash_pos + 1);
  auto dot_pos = filename.find_last_of('.');
  if (dot_pos != std::string::npos && dot_pos + 1 < filename.size()) {
    std::string ext = filename.substr(dot_pos + 1);
    bool alnum = !ext.empty() && ext.size() <= 8;
    for (char c : ext) {
      if (!std::isalnum(static_cast<unsigned char>(c))) {
        alnum = false;
        break;
      }
    }
    if (alnum) return AsciiLower(ext);
  }
  std::string clean_mime = mime_type;
  auto semi = clean_mime.find(';');
  if (semi != std::string::npos) {
    clean_mime = clean_mime.substr(0, semi);
  }
  clean_mime = AsciiLower(TrimAscii(clean_mime));
  if (clean_mime == "image/png") return "png";
  if (clean_mime == "image/jpeg" || clean_mime == "image/jpg") return "jpg";
  if (clean_mime == "image/webp") return "webp";
  if (clean_mime == "image/gif") return "gif";
  if (clean_mime == "image/svg+xml") return "svg";
  if (clean_mime == "application/pdf") return "pdf";
  if (clean_mime == "application/json") return "json";
  if (clean_mime == "audio/mpeg" || clean_mime == "audio/mp3") return "mp3";
  if (clean_mime == "video/mp4") return "mp4";
  if (clean_mime == "text/plain") return "txt";
  return "bin";
}

std::optional<int64_t> ParseMaxAgeSeconds(const std::string& cache_control) {
  if (cache_control.empty()) return std::nullopt;
  const std::string lower = AsciiLower(cache_control);
  const size_t pos = lower.find("max-age=");
  if (pos == std::string::npos) return std::nullopt;
  size_t idx = pos + 8;
  if (idx >= lower.size() ||
      !std::isdigit(static_cast<unsigned char>(lower[idx]))) {
    return std::nullopt;
  }
  int64_t val = 0;
  while (idx < lower.size() &&
         std::isdigit(static_cast<unsigned char>(lower[idx]))) {
    val = val * 10 + (lower[idx] - '0');
    idx++;
  }
  return val;
}

std::map<std::string, std::string> ExtractFlStringMap(FlValue* map) {
  std::map<std::string, std::string> out;
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return out;
  const size_t len = fl_value_get_length(map);
  for (size_t i = 0; i < len; ++i) {
    FlValue* k = fl_value_get_map_key(map, i);
    FlValue* v = fl_value_get_map_value(map, i);
    if (k && v && fl_value_get_type(k) == FL_VALUE_TYPE_STRING &&
        fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
      out[fl_value_get_string(k)] = fl_value_get_string(v);
    }
  }
  return out;
}

struct DownloadRequest {
  std::string url;
  std::string custom_key;
  std::string tag;
  std::string file_ext;
  std::map<std::string, std::string> headers;
  bool has_ttl = false;
  int64_t ttl_sec = 0;
  bool force_refresh = false;
  bool fallback_on_error = true;
  bool pinned = false;
  XueHuaCacheWireCacheChecksumAlgorithm checksum_alg =
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_NONE;
  std::string expected_checksum;
};

DownloadRequest ParseDownloadRequest(XueHuaCacheWireCacheRequest* wire) {
  DownloadRequest request;
  if (!wire) return request;
  const gchar* raw_url = xue_hua_cache_wire_cache_request_get_url(wire);
  request.url = TrimAscii(raw_url ? raw_url : "");
  const gchar* raw_custom = xue_hua_cache_wire_cache_request_get_custom_key(wire);
  if (raw_custom) request.custom_key = raw_custom;
  const gchar* raw_tag = xue_hua_cache_wire_cache_request_get_tag(wire);
  if (raw_tag) request.tag = raw_tag;
  const gchar* raw_ext =
      xue_hua_cache_wire_cache_request_get_file_extension(wire);
  if (raw_ext) request.file_ext = raw_ext;
  request.headers =
      ExtractFlStringMap(xue_hua_cache_wire_cache_request_get_headers(wire));
  int64_t* ttl_ptr = xue_hua_cache_wire_cache_request_get_ttl_seconds(wire);
  if (ttl_ptr != nullptr) {
    request.has_ttl = true;
    request.ttl_sec = *ttl_ptr;
  }
  request.force_refresh =
      xue_hua_cache_wire_cache_request_get_force_refresh(wire) != FALSE;
  request.fallback_on_error =
      xue_hua_cache_wire_cache_request_get_fallback_to_cache_on_error(wire) !=
      FALSE;
  request.pinned = xue_hua_cache_wire_cache_request_get_pinned(wire) != FALSE;
  request.checksum_alg =
      xue_hua_cache_wire_cache_request_get_checksum_algorithm(wire);
  const gchar* raw_checksum =
      xue_hua_cache_wire_cache_request_get_expected_checksum(wire);
  if (raw_checksum) {
    request.expected_checksum = AsciiLower(TrimAscii(raw_checksum));
  }
  return request;
}

}  // namespace

struct _XueHuaNaviteCacheManagerPlugin {
  GObject parent_instance;
  FlBinaryMessenger* messenger;
  XueHuaCacheCacheProgressFlutterApi* flutter_api;
  std::atomic<bool> disposed;
};

G_DEFINE_TYPE(XueHuaNaviteCacheManagerPlugin,
              xue_hua_navite_cache_manager_plugin,
              g_object_get_type())

namespace {

std::mutex g_config_mutex;
int64_t g_max_disk_cache_bytes = 500LL * 1024LL * 1024LL;
int g_max_entries = 20000;
int64_t g_default_ttl_seconds = 7LL * 24LL * 3600LL;
std::string g_eviction_policy = "lru";
std::string g_cache_subdirectory = "xue_hua_network_cache";
int g_connect_timeout_ms = 15000;
int g_read_timeout_ms = 30000;
std::map<std::string, std::string> g_default_headers;
bool g_respect_http_cache_headers = true;
bool g_auto_trim_on_write = true;

std::mutex g_index_mutex;
std::map<std::string, LinuxCacheRecord> g_entries;
int64_t g_total_cached_bytes = 0;
int64_t g_hit_count = 0;
int64_t g_miss_count = 0;
int64_t g_eviction_count = 0;
bool g_index_loaded = false;

std::string ResolveCacheRootPath(const std::string& subdirectory) {
  const gchar* base = g_get_user_cache_dir();
  return std::string(base ? base : "/tmp") + "/" + subdirectory;
}

std::string GetCacheRootDir(bool create_if_missing = true) {
  std::string subdir;
  {
    std::lock_guard<std::mutex> lock(g_config_mutex);
    subdir = g_cache_subdirectory;
  }
  std::string dir = ResolveCacheRootPath(subdir);
  if (create_if_missing) {
    g_mkdir_with_parents(dir.c_str(), 0755);
  }
  return dir;
}

std::string GetIndexFilePath(const std::string& subdirectory = "") {
  std::string root = subdirectory.empty()
                         ? GetCacheRootDir(false)
                         : ResolveCacheRootPath(subdirectory);
  return root + "/cache_index_v1.tsv";
}

void EnsureIndexLoaded() {
  {
    std::lock_guard<std::mutex> lock(g_index_mutex);
    if (g_index_loaded) return;
  }

  const std::string index_path = GetIndexFilePath();
  std::map<std::string, LinuxCacheRecord> loaded_entries;
  int64_t loaded_bytes = 0;
  int64_t loaded_hit = 0;
  int64_t loaded_miss = 0;
  int64_t loaded_eviction = 0;

  std::ifstream in(index_path);
  if (in.is_open()) {
    std::string line;
    if (std::getline(in, line)) {
      std::istringstream ss(line);
      ss >> loaded_hit >> loaded_miss >> loaded_eviction;
    }
    while (std::getline(in, line)) {
      if (line.empty()) continue;
      std::vector<std::string> parts;
      std::stringstream ss(line);
      std::string item;
      while (std::getline(ss, item, '\t')) {
        parts.push_back(item);
      }
      if (!line.empty() && line.back() == '\t') {
        parts.emplace_back();
      }
      if (parts.size() >= 15) {
        try {
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
            loaded_entries[rec.key] = rec;
            loaded_bytes += rec.size_bytes;
          }
        } catch (...) {
        }
      }
    }
  }

  std::lock_guard<std::mutex> lock(g_index_mutex);
  if (g_index_loaded) return;
  g_index_loaded = true;
  g_entries = std::move(loaded_entries);
  g_total_cached_bytes = loaded_bytes;
  g_hit_count = loaded_hit;
  g_miss_count = loaded_miss;
  g_eviction_count = loaded_eviction;
}

std::atomic<bool> g_index_dirty{false};

class PersistCoordinator {
 public:
  PersistCoordinator() {
    thread_ = std::thread([this]() { Loop(); });
  }
  PersistCoordinator(const PersistCoordinator&) = delete;
  PersistCoordinator& operator=(const PersistCoordinator&) = delete;

  ~PersistCoordinator() {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stopping_ = true;
      scheduled_ = true;
      deadline_ = std::chrono::steady_clock::now();
    }
    cv_.notify_all();
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  void Schedule() {
    g_index_dirty.store(true, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(mu_);
      deadline_ =
          std::chrono::steady_clock::now() + std::chrono::milliseconds(600);
      scheduled_ = true;
    }
    cv_.notify_one();
  }

  void FlushNow(const std::string& override_subdir = "") {
    if (!g_index_dirty.load(std::memory_order_acquire)) {
      return;
    }
    std::string target_subdir = override_subdir;
    if (target_subdir.empty()) {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      target_subdir = g_cache_subdirectory;
    }
    const std::string root_dir = ResolveCacheRootPath(target_subdir);
    const std::string index_path = root_dir + "/cache_index_v1.tsv";

    int64_t snap_hit = 0;
    int64_t snap_miss = 0;
    int64_t snap_eviction = 0;
    std::vector<LinuxCacheRecord> snap_entries;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      if (!g_index_dirty.exchange(false, std::memory_order_acq_rel)) {
        return;
      }
      snap_hit = g_hit_count;
      snap_miss = g_miss_count;
      snap_eviction = g_eviction_count;
      snap_entries.reserve(g_entries.size());
      for (const auto& kv : g_entries) {
        snap_entries.push_back(kv.second);
      }
    }

    g_mkdir_with_parents(root_dir.c_str(), 0755);
    const std::string tmp_path = index_path + ".tmp";
    bool wrote = false;
    {
      std::ofstream out(tmp_path, std::ios::trunc);
      if (out.is_open()) {
        out << snap_hit << " " << snap_miss << " " << snap_eviction << "\n";
        for (const auto& r : snap_entries) {
          out << SanitizeTsvField(r.key) << "\t"
              << SanitizeTsvField(r.url) << "\t"
              << SanitizeTsvField(r.file_path) << "\t" << r.size_bytes << "\t"
              << r.created_at_ms << "\t" << r.last_accessed_at_ms << "\t"
              << r.expires_at_ms << "\t" << r.hit_count << "\t"
              << SanitizeTsvField(r.tag) << "\t"
              << SanitizeTsvField(r.mime_type) << "\t"
              << SanitizeTsvField(r.etag) << "\t"
              << SanitizeTsvField(r.last_modified) << "\t"
              << SanitizeTsvField(r.checksum) << "\t"
              << SanitizeTsvField(r.checksum_algorithm) << "\t"
              << (r.pinned ? "1" : "0") << "\n";
        }
        wrote = static_cast<bool>(out);
      }
    }
    if (!wrote || std::rename(tmp_path.c_str(), index_path.c_str()) != 0) {
      std::remove(tmp_path.c_str());
      g_index_dirty.store(true, std::memory_order_release);
    }
  }

 private:
  void Loop() {
    std::unique_lock<std::mutex> lock(mu_);
    while (!stopping_) {
      if (!scheduled_) {
        cv_.wait(lock, [this]() { return stopping_ || scheduled_; });
        continue;
      }
      const auto target = deadline_;
      cv_.wait_until(lock, target, [this, target]() {
        return stopping_ || deadline_ != target;
      });
      if (stopping_) break;
      if (std::chrono::steady_clock::now() < deadline_) continue;
      scheduled_ = false;
      lock.unlock();
      FlushNow();
      lock.lock();
    }
    lock.unlock();
    FlushNow();
  }

  std::mutex mu_;
  std::condition_variable cv_;
  std::thread thread_;
  bool stopping_ = false;
  bool scheduled_ = false;
  std::chrono::steady_clock::time_point deadline_{};
};

PersistCoordinator& GetPersistCoordinator() {
  static PersistCoordinator coordinator;
  return coordinator;
}

void PersistIndexLocked() {
  GetPersistCoordinator().Schedule();
}

std::string ResolveKey(const std::string& key_or_url,
                       const std::string& custom_key = "") {
  const std::string trimmed = TrimAscii(custom_key);
  if (!trimmed.empty()) return trimmed;
  {
    std::lock_guard<std::mutex> lock(g_index_mutex);
    if (g_entries.find(key_or_url) != g_entries.end()) {
      return key_or_url;
    }
  }
  return ComputeGLibHash(reinterpret_cast<const uint8_t*>(key_or_url.data()),
                         key_or_url.size(), "sha256");
}

int RemoveExpiredLocked() {
  const int64_t now = CurrentTimeMs();
  std::vector<std::string> expired;
  for (const auto& kv : g_entries) {
    if (!kv.second.pinned && kv.second.IsExpired(now)) {
      expired.push_back(kv.first);
    }
  }
  for (const auto& k : expired) {
    auto it = g_entries.find(k);
    if (it != g_entries.end()) {
      std::remove(it->second.file_path.c_str());
      g_total_cached_bytes =
          std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
      g_entries.erase(it);
    }
  }
  g_eviction_count += static_cast<int64_t>(expired.size());
  return static_cast<int>(expired.size());
}

int EnforceQuotaLocked(int64_t target_max_bytes,
                       int max_entries,
                       const std::string& eviction_policy,
                       const std::string& protected_key) {
  int evicted = RemoveExpiredLocked();
  if (eviction_policy == "ttlOnly") return evicted;

  if (g_total_cached_bytes <= target_max_bytes &&
      static_cast<int>(g_entries.size()) <= max_entries) {
    return evicted;
  }

  std::vector<LinuxCacheRecord> candidates;
  candidates.reserve(g_entries.size());
  for (const auto& kv : g_entries) {
    if (!kv.second.pinned && kv.first != protected_key) {
      candidates.push_back(kv.second);
    }
  }
  std::sort(candidates.begin(), candidates.end(),
            [&eviction_policy](const LinuxCacheRecord& a,
                               const LinuxCacheRecord& b) {
              if (eviction_policy == "lfu") {
                if (a.hit_count != b.hit_count) return a.hit_count < b.hit_count;
                return a.last_accessed_at_ms < b.last_accessed_at_ms;
              }
              if (eviction_policy == "fifo") {
                return a.created_at_ms < b.created_at_ms;
              }
              return a.last_accessed_at_ms < b.last_accessed_at_ms;
            });

  for (const auto& cand : candidates) {
    if (g_total_cached_bytes <= target_max_bytes &&
        static_cast<int>(g_entries.size()) <= max_entries) {
      break;
    }
    auto it = g_entries.find(cand.key);
    if (it != g_entries.end()) {
      std::remove(it->second.file_path.c_str());
      g_total_cached_bytes =
          std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
      g_entries.erase(it);
      evicted++;
      g_eviction_count++;
    }
  }
  return evicted;
}

struct CurlHttpResult {
  bool ok = false;
  int status = 0;
  std::string etag;
  std::string last_modified;
  std::string content_type;
  std::string cache_control;
  std::string error;
};

void ParseLastHeaderBlock(const std::string& raw, CurlHttpResult* result) {
  std::map<std::string, std::string> headers;
  std::istringstream in(raw);
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.compare(0, 5, "HTTP/") == 0) {
      headers.clear();
      continue;
    }
    const auto colon = line.find(':');
    if (colon == std::string::npos) continue;
    const std::string name = AsciiLower(TrimAscii(line.substr(0, colon)));
    headers[name] = TrimAscii(line.substr(colon + 1));
  }
  const auto etag = headers.find("etag");
  if (etag != headers.end()) result->etag = etag->second;
  const auto modified = headers.find("last-modified");
  if (modified != headers.end()) result->last_modified = modified->second;
  const auto cache_ctrl = headers.find("cache-control");
  if (cache_ctrl != headers.end()) result->cache_control = cache_ctrl->second;
  const auto type = headers.find("content-type");
  if (type != headers.end()) {
    const auto semi = type->second.find(';');
    result->content_type = TrimAscii(semi == std::string::npos
                                         ? type->second
                                         : type->second.substr(0, semi));
  }
}

int ParseHttpStatus(const std::string& stdout_text) {
  int status = 0;
  std::istringstream in(stdout_text);
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    line = TrimAscii(line);
    if (!line.empty()) status = std::atoi(line.c_str());
  }
  return status;
}

CurlHttpResult DownloadViaCurl(const std::string& url,
                               const std::string& dest_tmp_path,
                               int connect_timeout_sec,
                               int max_time_sec,
                               const std::string& extra_headers) {
  CurlHttpResult result;
  const std::string header_path = dest_tmp_path + ".hdr";
  gchar* quoted_url = g_shell_quote(url.c_str());
  gchar* quoted_dest = g_shell_quote(dest_tmp_path.c_str());
  gchar* quoted_hdr = g_shell_quote(header_path.c_str());
  gchar* quoted_write_out = g_shell_quote("%{http_code}");
  g_autofree gchar* cmd = g_strdup_printf(
      "curl -sS -L --connect-timeout %d --max-time %d -D %s -o %s -w %s%s %s",
      connect_timeout_sec > 0 ? connect_timeout_sec : 15,
      max_time_sec > 0 ? max_time_sec : 30, quoted_hdr, quoted_dest,
      quoted_write_out, extra_headers.c_str(), quoted_url);
  g_free(quoted_url);
  g_free(quoted_dest);
  g_free(quoted_hdr);
  g_free(quoted_write_out);

  gint exit_status = 0;
  g_autofree gchar* std_out = nullptr;
  g_autofree gchar* std_err = nullptr;
  GError* error = nullptr;
  const gboolean spawned = g_spawn_command_line_sync(
      cmd, &std_out, &std_err, &exit_status, &error);
  if (g_file_test(header_path.c_str(), G_FILE_TEST_EXISTS)) {
    gchar* header_text = nullptr;
    gsize header_len = 0;
    if (g_file_get_contents(header_path.c_str(), &header_text, &header_len,
                            nullptr) &&
        header_text) {
      ParseLastHeaderBlock(std::string(header_text, header_len), &result);
      g_free(header_text);
    }
    std::remove(header_path.c_str());
  }

  result.status = ParseHttpStatus(std_out ? std_out : "");
  const bool status_ok =
      result.status == 304 || (result.status >= 200 && result.status <= 299);
  const bool body_ready =
      result.status == 304 ||
      g_file_test(dest_tmp_path.c_str(), G_FILE_TEST_EXISTS);
  if (spawned && error == nullptr && exit_status == 0 && status_ok &&
      body_ready) {
    result.ok = true;
    return result;
  }

  if (error) {
    result.error = error->message;
    g_error_free(error);
  } else if (std_err && std_err[0] != '\0') {
    result.error = std_err;
  } else if (result.status != 0) {
    result.error = "HTTP status " + std::to_string(result.status);
  } else {
    result.error = "Network download failed";
  }
  return result;
}

struct DownloadOutcome {
  bool ok = false;
  std::string error_code;
  std::string error_message;
  LinuxCacheRecord entry;
  XueHuaCacheWireCacheResultSource source =
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_NETWORK_DOWNLOAD;
  bool has_http_status = false;
  int64_t http_status = 0;
  int64_t elapsed_ms = 0;
};

struct InFlightDownload {
  std::shared_ptr<std::atomic<bool>> cancel_flag =
      std::make_shared<std::atomic<bool>>(false);
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
};

std::mutex g_flight_mutex;
std::map<std::string, std::shared_ptr<InFlightDownload>> g_in_flight;

class WorkerPool {
 public:
  explicit WorkerPool(int limit) : limit_(std::max(1, limit)) {}
  WorkerPool(const WorkerPool&) = delete;
  WorkerPool& operator=(const WorkerPool&) = delete;

  ~WorkerPool() {
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
          return stopping_ || (!jobs_.empty() && active_ < limit_);
        });
        if (stopping_ || jobs_.empty()) return;
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

WorkerPool& GetDownloadPool() {
  static WorkerPool pool(4);
  return pool;
}

WorkerPool& GetIoPool() {
  static WorkerPool pool(4);
  return pool;
}

struct ProgressPayload {
  XueHuaNaviteCacheManagerPlugin* self = nullptr;
  std::string key;
  std::string url;
  XueHuaCacheWireCacheTransferState state =
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_STARTED;
  std::string file_path;
  std::string error;
  int64_t bytes = 0;
  int64_t total = 0;
};

static gboolean ProgressOnMain(gpointer data) {
  std::unique_ptr<ProgressPayload> payload(static_cast<ProgressPayload*>(data));
  XueHuaNaviteCacheManagerPlugin* self = payload->self;
  if (self && !self->disposed.load(std::memory_order_acquire) &&
      self->flutter_api) {
    g_autoptr(XueHuaCacheWireCacheProgressEvent) event =
        xue_hua_cache_wire_cache_progress_event_new(
            payload->key.c_str(), payload->url.c_str(), payload->state,
            payload->bytes, payload->total,
            payload->file_path.empty() ? nullptr : payload->file_path.c_str(),
            payload->error.empty() ? nullptr : payload->error.c_str());
    xue_hua_cache_cache_progress_flutter_api_on_progress(
        self->flutter_api, event, nullptr, nullptr, nullptr);
  }
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

void PostProgress(XueHuaNaviteCacheManagerPlugin* self,
                  const std::string& key,
                  const std::string& url,
                  XueHuaCacheWireCacheTransferState state,
                  int64_t bytes,
                  int64_t total,
                  const std::string& file_path = "",
                  const std::string& error = "") {
  if (!self || self->disposed.load(std::memory_order_acquire)) return;
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
                            XueHuaCacheWireCacheResultSource source,
                            bool has_http_status,
                            int64_t http_status,
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

XueHuaCacheWireCacheFetchResult* OutcomeToWireResult(
    const DownloadOutcome& outcome) {
  g_autoptr(XueHuaCacheWireCacheEntry) wire_entry = outcome.entry.ToWireEntry();
  int64_t status_val = outcome.http_status;
  return xue_hua_cache_wire_cache_fetch_result_new(
      wire_entry, outcome.source,
      outcome.has_http_status ? &status_val : nullptr, outcome.elapsed_ms);
}

struct MainCallbackTask {
  XueHuaNaviteCacheManagerPlugin* self = nullptr;
  XueHuaCacheCacheHostApiResponseHandle* handle = nullptr;
  std::function<void()> callback;
};

static gboolean RunMainCallback(gpointer data) {
  std::unique_ptr<MainCallbackTask> task(static_cast<MainCallbackTask*>(data));
  if (task->self && !task->self->disposed.load(std::memory_order_acquire) &&
      task->callback) {
    task->callback();
  }
  if (task->handle) {
    g_object_unref(task->handle);
  }
  if (task->self) {
    g_object_unref(task->self);
  }
  return G_SOURCE_REMOVE;
}

void PostMainResponse(XueHuaNaviteCacheManagerPlugin* self,
                      XueHuaCacheCacheHostApiResponseHandle* handle,
                      std::function<void()> fn) {
  if (!self || self->disposed.load(std::memory_order_acquire)) return;
  auto* task = new MainCallbackTask();
  task->self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(g_object_ref(self));
  task->handle =
      handle ? XUE_HUA_CACHE_CACHE_HOST_API_RESPONSE_HANDLE(g_object_ref(handle))
             : nullptr;
  task->callback = std::move(fn);
  g_idle_add(RunMainCallback, task);
}

DownloadOutcome ExecuteDownload(
    XueHuaNaviteCacheManagerPlugin* self,
    const DownloadRequest& request,
    const std::string& key,
    const std::shared_ptr<std::atomic<bool>>& cancel_flag) {
  const int64_t start_ms = CurrentTimeMs();
  LinuxCacheRecord existing;
  bool has_existing = false;

  int64_t cfg_max_bytes = 500LL * 1024LL * 1024LL;
  int cfg_max_entries = 20000;
  int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
  std::string cfg_policy = "lru";
  int cfg_connect_timeout_ms = 15000;
  int cfg_read_timeout_ms = 30000;
  std::map<std::string, std::string> cfg_default_headers;
  bool cfg_respect_http = true;
  bool cfg_auto_trim = true;
  {
    std::lock_guard<std::mutex> lock(g_config_mutex);
    cfg_max_bytes = g_max_disk_cache_bytes;
    cfg_max_entries = g_max_entries;
    cfg_default_ttl = g_default_ttl_seconds;
    cfg_policy = g_eviction_policy;
    cfg_connect_timeout_ms = g_connect_timeout_ms;
    cfg_read_timeout_ms = g_read_timeout_ms;
    cfg_default_headers = g_default_headers;
    cfg_respect_http = g_respect_http_cache_headers;
    cfg_auto_trim = g_auto_trim_on_write;
  }

  std::optional<DownloadOutcome> fresh_hit;
  {
    std::lock_guard<std::mutex> lock(g_index_mutex);
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
        fresh_hit = MakeSuccess(
            it->second,
            XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_CACHE_HIT,
            false, 0, CurrentTimeMs() - start_ms);
      }
    }
    if (!fresh_hit.has_value()) {
      g_miss_count++;
    }
  }
  if (fresh_hit.has_value()) {
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CACHE_HIT,
        fresh_hit->entry.size_bytes, fresh_hit->entry.size_bytes,
        fresh_hit->entry.file_path);
    return *fresh_hit;
  }

  if (cancel_flag && cancel_flag->load()) {
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CANCELED, 0, -1,
        "", "Download canceled");
    return MakeFailure("CANCELED", "Download canceled");
  }

  PostProgress(
      self, key, request.url,
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_STARTED, 0, -1);

  const std::string root_dir = GetCacheRootDir(true);
  const std::string tmp_path = root_dir + "/" + key + ".tmp";
  const int connect_sec = std::max(1, (cfg_connect_timeout_ms + 999) / 1000);
  const int total_sec =
      std::max(1, (cfg_connect_timeout_ms + cfg_read_timeout_ms + 999) / 1000);

  std::map<std::string, std::pair<std::string, std::string>> merged_headers;
  for (const auto& kv : cfg_default_headers) {
    const std::string clean_name = SanitizeHeaderName(kv.first);
    if (!clean_name.empty()) {
      merged_headers[AsciiLower(clean_name)] =
          std::make_pair(clean_name, SanitizeHeaderValue(kv.second));
    }
  }
  for (const auto& kv : request.headers) {
    const std::string clean_name = SanitizeHeaderName(kv.first);
    if (!clean_name.empty()) {
      merged_headers[AsciiLower(clean_name)] =
          std::make_pair(clean_name, SanitizeHeaderValue(kv.second));
    }
  }
  if (cfg_respect_http && has_existing) {
    if (!existing.etag.empty()) {
      merged_headers["if-none-match"] =
          std::make_pair("If-None-Match", SanitizeHeaderValue(existing.etag));
    }
    if (!existing.last_modified.empty()) {
      merged_headers["if-modified-since"] = std::make_pair(
          "If-Modified-Since", SanitizeHeaderValue(existing.last_modified));
    }
  }

  std::string extra_headers;
  for (const auto& kv : merged_headers) {
    const std::string hdr = kv.second.first + ": " + kv.second.second;
    gchar* quoted = g_shell_quote(hdr.c_str());
    extra_headers += " -H ";
    extra_headers += quoted;
    g_free(quoted);
  }

  const CurlHttpResult downloaded = DownloadViaCurl(
      request.url, tmp_path, connect_sec, total_sec, extra_headers);
  if (!downloaded.ok) {
    std::remove(tmp_path.c_str());
    if (cancel_flag && cancel_flag->load()) {
      PostProgress(
          self, key, request.url,
          XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CANCELED, 0,
          -1, "", "Download canceled");
      return MakeFailure("CANCELED", "Download canceled");
    }
    if (request.fallback_on_error && has_existing) {
      return MakeSuccess(
          existing,
          XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_STALE_CACHE_FALLBACK,
          downloaded.status != 0, downloaded.status,
          CurrentTimeMs() - start_ms);
    }
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_FAILED, 0, -1,
        "", downloaded.error);
    return MakeFailure(downloaded.status >= 400 ? "HTTP_ERROR" : "DOWNLOAD_FAILED",
                       downloaded.error);
  }

  if (cancel_flag && cancel_flag->load()) {
    std::remove(tmp_path.c_str());
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CANCELED, 0, -1,
        "", "Download canceled");
    return MakeFailure("CANCELED", "Download canceled");
  }

  if (downloaded.status == 304 && has_existing) {
    std::remove(tmp_path.c_str());
    const int64_t now = CurrentTimeMs();
    const auto header_ttl = cfg_respect_http
                                ? ParseMaxAgeSeconds(downloaded.cache_control)
                                : std::nullopt;
    const int64_t ttl_sec =
        request.has_ttl ? request.ttl_sec
                        : (header_ttl ? *header_ttl : cfg_default_ttl);
    LinuxCacheRecord refreshed = existing;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      if (it != g_entries.end()) refreshed = it->second;
      refreshed.last_accessed_at_ms = now;
      refreshed.expires_at_ms = now + ttl_sec * 1000LL;
      refreshed.hit_count += 1;
      if (!downloaded.etag.empty()) refreshed.etag = downloaded.etag;
      if (!downloaded.last_modified.empty()) {
        refreshed.last_modified = downloaded.last_modified;
      }
      if (!request.tag.empty()) refreshed.tag = request.tag;
      if (request.pinned) refreshed.pinned = true;
      g_hit_count++;
      g_entries[key] = refreshed;
      PersistIndexLocked();
    }
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CACHE_HIT,
        refreshed.size_bytes, refreshed.size_bytes, refreshed.file_path);
    return MakeSuccess(
        refreshed,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_REVALIDATED, true,
        304, CurrentTimeMs() - start_ms);
  }

  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(tmp_path.c_str(), &contents, &length, nullptr)) {
    std::remove(tmp_path.c_str());
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_FAILED, 0, -1,
        "", "Failed to read downloaded file");
    return MakeFailure("READ_ERROR", "Failed to read downloaded file");
  }

  PostProgress(
      self, key, request.url,
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_IN_PROGRESS,
      static_cast<int64_t>(length), static_cast<int64_t>(length));

  const std::string checksum_alg_str =
      ChecksumAlgToString(request.checksum_alg);
  std::string computed_hash;
  if (request.checksum_alg !=
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_CHECKSUM_ALGORITHM_NONE) {
    computed_hash = ComputeGLibHash(
        reinterpret_cast<const uint8_t*>(contents), length, checksum_alg_str);
    if (!request.expected_checksum.empty() &&
        AsciiLower(computed_hash) != request.expected_checksum) {
      g_free(contents);
      std::remove(tmp_path.c_str());
      PostProgress(
          self, key, request.url,
          XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_FAILED, 0, -1,
          "", "Checksum mismatch");
      return MakeFailure("CHECKSUM_MISMATCH", "Checksum verification failed");
    }
  }
  g_free(contents);

  const std::string ext =
      InferExtension(request.url, downloaded.content_type, request.file_ext);
  const std::string final_path = root_dir + "/" + key + "." + ext;
  if (std::rename(tmp_path.c_str(), final_path.c_str()) != 0) {
    std::remove(tmp_path.c_str());
    PostProgress(
        self, key, request.url,
        XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_FAILED, 0, -1,
        "", "Failed moving downloaded file into cache");
    return MakeFailure("DISK_WRITE_ERROR",
                       "Failed moving downloaded file into cache");
  }

  const int64_t now = CurrentTimeMs();
  const auto header_ttl = cfg_respect_http
                              ? ParseMaxAgeSeconds(downloaded.cache_control)
                              : std::nullopt;
  const int64_t ttl_sec =
      request.has_ttl ? request.ttl_sec
                      : (header_ttl ? *header_ttl : cfg_default_ttl);

  LinuxCacheRecord rec;
  rec.key = key;
  rec.url = request.url;
  rec.file_path = final_path;
  rec.size_bytes = static_cast<int64_t>(length);
  rec.created_at_ms = now;
  rec.last_accessed_at_ms = now;
  rec.expires_at_ms = now + ttl_sec * 1000LL;
  rec.hit_count = 1;
  rec.tag = request.tag;
  rec.mime_type = downloaded.content_type.empty() ? "application/octet-stream"
                                                  : downloaded.content_type;
  rec.etag = downloaded.etag;
  rec.last_modified = downloaded.last_modified;
  rec.checksum = computed_hash;
  rec.checksum_algorithm = checksum_alg_str;
  rec.pinned = request.pinned;

  {
    std::lock_guard<std::mutex> lock(g_index_mutex);
    auto prev = g_entries.find(key);
    if (prev != g_entries.end()) {
      g_total_cached_bytes =
          std::max<int64_t>(0, g_total_cached_bytes - prev->second.size_bytes);
      if (prev->second.file_path != rec.file_path) {
        std::remove(prev->second.file_path.c_str());
      }
    }
    g_entries[key] = rec;
    g_total_cached_bytes += rec.size_bytes;
    if (cfg_auto_trim) {
      EnforceQuotaLocked(cfg_max_bytes, cfg_max_entries, cfg_policy, key);
    }
    PersistIndexLocked();
  }

  PostProgress(
      self, key, request.url,
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_COMPLETED,
      rec.size_bytes, rec.size_bytes, rec.file_path);
  return MakeSuccess(
      rec,
      XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_NETWORK_DOWNLOAD,
      true, downloaded.status == 0 ? 200 : downloaded.status,
      CurrentTimeMs() - start_ms);
}

void FinishInFlight(const std::string& key,
                    const std::shared_ptr<InFlightDownload>& state,
                    const DownloadOutcome& outcome) {
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  {
    std::lock_guard<std::mutex> lock(g_flight_mutex);
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

  const std::string key = ResolveKey(request.url, request.custom_key);
  if (!request.force_refresh) {
    DownloadOutcome early;
    bool has_early = false;
    const int64_t now = CurrentTimeMs();
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      if (it != g_entries.end() &&
          g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS) &&
          !it->second.IsExpired(now)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        if (!request.tag.empty()) it->second.tag = request.tag;
        if (request.pinned) it->second.pinned = true;
        g_hit_count++;
        PersistIndexLocked();
        early = MakeSuccess(
            it->second,
            XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_RESULT_SOURCE_CACHE_HIT,
            false, 0, 0);
        has_early = true;
      }
    }
    if (has_early) {
      PostProgress(
          self, key, request.url,
          XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CACHE_HIT,
          early.entry.size_bytes, early.entry.size_bytes,
          early.entry.file_path);
      callback(early);
      return;
    }
  }

  std::shared_ptr<InFlightDownload> state;
  {
    std::lock_guard<std::mutex> lock(g_flight_mutex);
    auto existing = g_in_flight.find(key);
    if (existing != g_in_flight.end()) {
      existing->second->waiters.push_back(std::move(callback));
      return;
    }
    state = std::make_shared<InFlightDownload>();
    state->waiters.push_back(std::move(callback));
    g_in_flight[key] = state;
  }

  XueHuaNaviteCacheManagerPlugin* plugin =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(g_object_ref(self));
  const bool queued = GetDownloadPool().Post([plugin, request, key, state]() {
    DownloadOutcome outcome;
    try {
      if (state->cancel_flag->load()) {
        outcome = MakeFailure("CANCELED", "Download canceled");
        PostProgress(
            plugin, key, request.url,
            XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CANCELED, 0,
            -1, "", "Download canceled");
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
    FinishInFlight(key, state,
                   MakeFailure("DOWNLOAD_FAILED", "Download pool is stopping"));
    g_object_unref(plugin);
  }
}

// MARK: - Pigeon CacheHostApi VTable Handlers

void HandleConfigure(XueHuaCacheWireCacheManagerConfig* config,
                     XueHuaCacheCacheHostApiResponseHandle* response_handle,
                     gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  if (!config) {
    xue_hua_cache_cache_host_api_respond_error_configure(
        response_handle, "INVALID_ARGS", "config is required", nullptr);
    return;
  }

  const int64_t next_max_bytes = std::max<int64_t>(
      1, xue_hua_cache_wire_cache_manager_config_get_max_disk_cache_bytes(config));
  const int next_max_entries = std::max(
      1, static_cast<int>(
             xue_hua_cache_wire_cache_manager_config_get_max_entries(config)));
  const int64_t next_default_ttl = std::max<int64_t>(
      0, xue_hua_cache_wire_cache_manager_config_get_default_ttl_seconds(config));
  const std::string next_policy = EvictionPolicyToString(
      xue_hua_cache_wire_cache_manager_config_get_eviction_policy(config));
  const gchar* raw_subdir =
      xue_hua_cache_wire_cache_manager_config_get_cache_subdirectory(config);
  const std::string trimmed_subdir = TrimAscii(raw_subdir ? raw_subdir : "");
  const int next_conc = std::max(
      1,
      static_cast<int>(
          xue_hua_cache_wire_cache_manager_config_get_max_concurrent_downloads(
              config)));
  const int next_connect_ms = std::max(
      1,
      static_cast<int>(
          xue_hua_cache_wire_cache_manager_config_get_connect_timeout_ms(
              config)));
  const int next_read_ms = std::max(
      1, static_cast<int>(
             xue_hua_cache_wire_cache_manager_config_get_read_timeout_ms(
                 config)));
  const std::map<std::string, std::string> next_headers = ExtractFlStringMap(
      xue_hua_cache_wire_cache_manager_config_get_default_headers(config));
  const bool next_respect_http =
      xue_hua_cache_wire_cache_manager_config_get_respect_http_cache_headers(
          config) != FALSE;
  const bool next_auto_trim =
      xue_hua_cache_wire_cache_manager_config_get_auto_trim_on_write(config) !=
      FALSE;

  g_object_ref(self);
  g_object_ref(response_handle);
  const bool queued = GetIoPool().Post([self, response_handle, next_max_bytes,
                                        next_max_entries, next_default_ttl,
                                        next_policy, trimmed_subdir, next_conc,
                                        next_connect_ms, next_read_ms,
                                        next_headers, next_respect_http,
                                        next_auto_trim]() {
    std::string prev_subdir;
    std::string next_subdir;
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      prev_subdir = g_cache_subdirectory;
      g_max_disk_cache_bytes = next_max_bytes;
      g_max_entries = next_max_entries;
      g_default_ttl_seconds = next_default_ttl;
      g_eviction_policy = next_policy;
      next_subdir = trimmed_subdir.empty() ? prev_subdir : trimmed_subdir;
      g_connect_timeout_ms = next_connect_ms;
      g_read_timeout_ms = next_read_ms;
      g_default_headers = next_headers;
      g_respect_http_cache_headers = next_respect_http;
      g_auto_trim_on_write = next_auto_trim;
    }

    GetDownloadPool().SetLimit(next_conc);

    if (prev_subdir != next_subdir) {
      GetPersistCoordinator().FlushNow(prev_subdir);
      {
        std::lock_guard<std::mutex> lock(g_index_mutex);
        g_index_dirty.store(false, std::memory_order_release);
        g_index_loaded = false;
        g_entries.clear();
        g_total_cached_bytes = 0;
        g_hit_count = 0;
        g_miss_count = 0;
        g_eviction_count = 0;
      }
      {
        std::lock_guard<std::mutex> lock(g_config_mutex);
        g_cache_subdirectory = next_subdir;
      }
    }

    EnsureIndexLoaded();
    if (next_auto_trim) {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      const int evicted = EnforceQuotaLocked(next_max_bytes, next_max_entries,
                                             next_policy, "");
      if (evicted > 0) PersistIndexLocked();
    }

    PostMainResponse(self, response_handle, [response_handle]() {
      xue_hua_cache_cache_host_api_respond_configure(response_handle);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleDownloadFile(XueHuaCacheWireCacheRequest* request,
                        XueHuaCacheCacheHostApiResponseHandle* response_handle,
                        gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  DownloadRequest parsed = ParseDownloadRequest(request);
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, parsed]() {
    EnsureIndexLoaded();
    ScheduleDownload(self, parsed, [self, response_handle](
                                       const DownloadOutcome& outcome) {
      PostMainResponse(self, response_handle, [response_handle, outcome]() {
        if (outcome.ok) {
          g_autoptr(XueHuaCacheWireCacheFetchResult) res =
              OutcomeToWireResult(outcome);
          xue_hua_cache_cache_host_api_respond_download_file(response_handle,
                                                             res);
        } else {
          xue_hua_cache_cache_host_api_respond_error_download_file(
              response_handle, outcome.error_code.c_str(),
              outcome.error_message.c_str(), nullptr);
        }
      });
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandlePrefetchAll(FlValue* requests,
                       XueHuaCacheCacheHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  std::vector<DownloadRequest> parsed;
  if (requests && fl_value_get_type(requests) == FL_VALUE_TYPE_LIST) {
    const size_t len = fl_value_get_length(requests);
    parsed.reserve(len);
    for (size_t i = 0; i < len; ++i) {
      FlValue* item = fl_value_get_list_value(requests, i);
      if (item && fl_value_get_type(item) == FL_VALUE_TYPE_CUSTOM &&
          fl_value_get_custom_type(item) ==
              xue_hua_cache_wire_cache_request_type_id) {
        auto* wire_req = XUE_HUA_CACHE_WIRE_CACHE_REQUEST(
            fl_value_get_custom_value_object(item));
        parsed.push_back(ParseDownloadRequest(wire_req));
      }
    }
  }

  if (parsed.empty()) {
    g_autoptr(FlValue) empty = fl_value_new_list();
    xue_hua_cache_cache_host_api_respond_prefetch_all(response_handle, empty);
    return;
  }

  g_object_ref(self);
  g_object_ref(response_handle);
  const bool queued = GetIoPool().Post([self, response_handle,
                                        parsed = std::move(parsed)]() {
    EnsureIndexLoaded();
    struct PrefetchState {
      std::mutex mu;
      size_t remaining = 0;
      std::vector<DownloadOutcome> slots;
      bool posted = false;
    };
    auto prefetch_state = std::make_shared<PrefetchState>();
    prefetch_state->remaining = parsed.size();
    prefetch_state->slots.resize(parsed.size());

    for (size_t index = 0; index < parsed.size(); ++index) {
      ScheduleDownload(
          self, parsed[index],
          [self, response_handle, prefetch_state,
           index](const DownloadOutcome& outcome) {
            bool done = false;
            std::vector<DownloadOutcome> slots;
            {
              std::lock_guard<std::mutex> lock(prefetch_state->mu);
              prefetch_state->slots[index] = outcome;
              prefetch_state->remaining -= 1;
              if (prefetch_state->remaining == 0 && !prefetch_state->posted) {
                prefetch_state->posted = true;
                done = true;
                slots = std::move(prefetch_state->slots);
              }
            }
            if (done) {
              PostMainResponse(
                  self, response_handle,
                  [response_handle, slots = std::move(slots)]() {
                    g_autoptr(FlValue) list = fl_value_new_list();
                    for (const auto& item : slots) {
                      if (!item.ok) continue;
                      g_autoptr(XueHuaCacheWireCacheEntry) wire =
                          item.entry.ToWireEntry();
                      fl_value_append_take(
                          list, fl_value_new_custom_object(
                                    xue_hua_cache_wire_cache_entry_type_id,
                                    G_OBJECT(wire)));
                    }
                    xue_hua_cache_cache_host_api_respond_prefetch_all(
                        response_handle, list);
                  });
            }
          });
    }
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

XueHuaCacheCacheHostApiCancelDownloadResponse* HandleCancelDownload(
    const gchar* key_or_url,
    gpointer /*user_data*/) {
  return cancel_download_response(key_or_url);
}

void HandleGetFileFromCache(
    const gchar* key_or_url,
    gboolean ignore_expired,
    XueHuaCacheCacheHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target = key_or_url ? key_or_url : "";
  const bool check_expired = ignore_expired != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target,
                                        check_expired]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(target);
    std::optional<LinuxCacheRecord> found;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      const int64_t now = CurrentTimeMs();
      if (it == g_entries.end()) {
        g_miss_count++;
      } else if (!g_file_test(it->second.file_path.c_str(),
                              G_FILE_TEST_EXISTS)) {
        g_total_cached_bytes =
            std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
        g_entries.erase(it);
        g_miss_count++;
        PersistIndexLocked();
      } else if (check_expired && it->second.IsExpired(now)) {
        g_miss_count++;
      } else {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        g_hit_count++;
        PersistIndexLocked();
        found = it->second;
      }
    }
    if (found.has_value()) {
      PostProgress(
          self, found->key, found->url,
          XUE_HUA_NAVITE_CACHE_MANAGER_WIRE_CACHE_TRANSFER_STATE_CACHE_HIT,
          found->size_bytes, found->size_bytes, found->file_path);
    }
    PostMainResponse(self, response_handle, [response_handle, found]() {
      if (found.has_value()) {
        g_autoptr(XueHuaCacheWireCacheEntry) wire = found->ToWireEntry();
        xue_hua_cache_cache_host_api_respond_get_file_from_cache(
            response_handle, wire);
      } else {
        xue_hua_cache_cache_host_api_respond_get_file_from_cache(
            response_handle, nullptr);
      }
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleReadCacheBytes(
    const gchar* key_or_url,
    gboolean ignore_expired,
    XueHuaCacheCacheHostApiResponseHandle* response_handle,
    gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target = key_or_url ? key_or_url : "";
  const bool check_expired = ignore_expired != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target,
                                        check_expired]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(target);
    std::string file_path;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      const int64_t now = CurrentTimeMs();
      if (it == g_entries.end()) {
        g_miss_count++;
      } else if (!g_file_test(it->second.file_path.c_str(),
                              G_FILE_TEST_EXISTS)) {
        g_total_cached_bytes =
            std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
        g_entries.erase(it);
        g_miss_count++;
        PersistIndexLocked();
      } else if (!check_expired || !it->second.IsExpired(now)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        g_hit_count++;
        PersistIndexLocked();
        file_path = it->second.file_path;
      } else {
        g_miss_count++;
      }
    }

    std::optional<std::vector<uint8_t>> bytes_out;
    if (!file_path.empty()) {
      gchar* contents = nullptr;
      gsize length = 0;
      if (g_file_get_contents(file_path.c_str(), &contents, &length, nullptr)) {
        bytes_out = std::vector<uint8_t>(
            reinterpret_cast<const uint8_t*>(contents),
            reinterpret_cast<const uint8_t*>(contents) + length);
        g_free(contents);
      }
    }

    PostMainResponse(
        self, response_handle,
        [response_handle, bytes_out = std::move(bytes_out)]() {
          if (bytes_out.has_value()) {
            const uint8_t empty_byte = 0;
            const uint8_t* ptr =
                bytes_out->empty() ? &empty_byte : bytes_out->data();
            xue_hua_cache_cache_host_api_respond_read_cache_bytes(
                response_handle, ptr, bytes_out->size());
          } else {
            xue_hua_cache_cache_host_api_respond_read_cache_bytes(
                response_handle, nullptr, 0);
          }
        });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleContainsKey(const gchar* key_or_url,
                       gboolean ignore_expired,
                       XueHuaCacheCacheHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target = key_or_url ? key_or_url : "";
  const bool check_expired = ignore_expired != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target,
                                        check_expired]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(target);
    bool exists = false;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      exists =
          it != g_entries.end() &&
          g_file_test(it->second.file_path.c_str(), G_FILE_TEST_EXISTS) &&
          (!check_expired || !it->second.IsExpired(CurrentTimeMs()));
    }
    PostMainResponse(self, response_handle, [response_handle, exists]() {
      xue_hua_cache_cache_host_api_respond_contains_key(
          response_handle, exists ? TRUE : FALSE);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandlePutBytes(const gchar* key,
                    const uint8_t* bytes,
                    size_t bytes_length,
                    const gchar* url,
                    const gchar* file_extension,
                    const gchar* mime_type,
                    const gchar* tag,
                    int64_t* ttl_seconds,
                    gboolean pinned,
                    XueHuaCacheCacheHostApiResponseHandle* response_handle,
                    gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string clean_key = TrimAscii(key ? key : "");
  if (clean_key.empty()) {
    xue_hua_cache_cache_host_api_respond_error_put_bytes(
        response_handle, "INVALID_ARGS", "key and bytes are required", nullptr);
    return;
  }

  std::vector<uint8_t> bytes_copy;
  if (bytes_length > 0 && bytes != nullptr) {
    bytes_copy.assign(bytes, bytes + bytes_length);
  }
  const std::string url_str = url ? url : ("local://" + clean_key);
  const std::string ext_str = file_extension ? file_extension : "";
  const std::string mime_str =
      (mime_type && mime_type[0] != '\0') ? mime_type
                                          : "application/octet-stream";
  const std::string tag_str = tag ? tag : "";
  const std::optional<int64_t> ttl_opt =
      ttl_seconds ? std::optional<int64_t>(*ttl_seconds) : std::nullopt;
  const bool is_pinned = pinned != FALSE;

  g_object_ref(self);
  g_object_ref(response_handle);
  const bool queued = GetIoPool().Post([self, response_handle, clean_key,
                                        bytes_copy = std::move(bytes_copy),
                                        url_str, ext_str, mime_str, tag_str,
                                        ttl_opt, is_pinned]() {
    EnsureIndexLoaded();

    int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
    int64_t cfg_max_bytes = 500LL * 1024LL * 1024LL;
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    bool cfg_auto_trim = true;
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      cfg_default_ttl = g_default_ttl_seconds;
      cfg_max_bytes = g_max_disk_cache_bytes;
      cfg_max_entries = g_max_entries;
      cfg_policy = g_eviction_policy;
      cfg_auto_trim = g_auto_trim_on_write;
    }

    const std::string ext = InferExtension(url_str, mime_str, ext_str);
    const std::string dest_path =
        GetCacheRootDir(true) + "/" + clean_key + "." + ext;
    const std::string tmp_path = dest_path + ".tmp";
    const gchar* write_ptr =
        bytes_copy.empty() ? "" : reinterpret_cast<const gchar*>(bytes_copy.data());
    GError* write_err = nullptr;
    if (!g_file_set_contents(tmp_path.c_str(), write_ptr, bytes_copy.size(),
                             &write_err) ||
        std::rename(tmp_path.c_str(), dest_path.c_str()) != 0) {
      std::string err_msg =
          write_err ? write_err->message : "Failed writing cache file";
      if (write_err) g_error_free(write_err);
      std::remove(tmp_path.c_str());
      PostMainResponse(self, response_handle, [response_handle, err_msg]() {
        xue_hua_cache_cache_host_api_respond_error_put_bytes(
            response_handle, "PUT_BYTES_FAILED", err_msg.c_str(), nullptr);
      });
      g_object_unref(response_handle);
      g_object_unref(self);
      return;
    }

    const int64_t now = CurrentTimeMs();
    const int64_t ttl_sec = ttl_opt ? *ttl_opt : cfg_default_ttl;
    LinuxCacheRecord rec;
    rec.key = clean_key;
    rec.url = url_str;
    rec.file_path = dest_path;
    rec.size_bytes = static_cast<int64_t>(bytes_copy.size());
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag_str;
    rec.mime_type = mime_str;
    rec.checksum =
        ComputeGLibHash(bytes_copy.data(), bytes_copy.size(), "sha256");
    rec.checksum_algorithm = "sha256";
    rec.pinned = is_pinned;

    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto prev = g_entries.find(clean_key);
      if (prev != g_entries.end()) {
        g_total_cached_bytes =
            std::max<int64_t>(0, g_total_cached_bytes - prev->second.size_bytes);
        if (prev->second.file_path != rec.file_path) {
          std::remove(prev->second.file_path.c_str());
        }
      }
      g_entries[clean_key] = rec;
      g_total_cached_bytes += rec.size_bytes;
      if (cfg_auto_trim) {
        EnforceQuotaLocked(cfg_max_bytes, cfg_max_entries, cfg_policy,
                           clean_key);
      }
      PersistIndexLocked();
    }

    PostMainResponse(self, response_handle, [response_handle, rec]() {
      g_autoptr(XueHuaCacheWireCacheEntry) wire = rec.ToWireEntry();
      xue_hua_cache_cache_host_api_respond_put_bytes(response_handle, wire);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandlePutFile(const gchar* key,
                   const gchar* source_file_path,
                   const gchar* url,
                   const gchar* file_extension,
                   const gchar* mime_type,
                   const gchar* tag,
                   int64_t* ttl_seconds,
                   gboolean pinned,
                   XueHuaCacheCacheHostApiResponseHandle* response_handle,
                   gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string clean_key = TrimAscii(key ? key : "");
  const std::string clean_source =
      TrimAscii(source_file_path ? source_file_path : "");
  if (clean_key.empty() || clean_source.empty()) {
    xue_hua_cache_cache_host_api_respond_error_put_file(
        response_handle, "INVALID_SOURCE", "Source file does not exist",
        nullptr);
    return;
  }

  const std::string url_str = url ? url : ("file://" + clean_source);
  std::string ext_str = file_extension ? file_extension : "";
  if (ext_str.empty()) {
    auto slash = clean_source.find_last_of('/');
    std::string fname =
        (slash == std::string::npos) ? clean_source : clean_source.substr(slash + 1);
    auto dot = fname.find_last_of('.');
    if (dot != std::string::npos && dot + 1 < fname.size()) {
      ext_str = fname.substr(dot + 1);
    }
  }
  const std::string mime_str =
      (mime_type && mime_type[0] != '\0') ? mime_type
                                          : "application/octet-stream";
  const std::string tag_str = tag ? tag : "";
  const std::optional<int64_t> ttl_opt =
      ttl_seconds ? std::optional<int64_t>(*ttl_seconds) : std::nullopt;
  const bool is_pinned = pinned != FALSE;

  g_object_ref(self);
  g_object_ref(response_handle);
  const bool queued = GetIoPool().Post([self, response_handle, clean_key,
                                        clean_source, url_str, ext_str,
                                        mime_str, tag_str, ttl_opt,
                                        is_pinned]() {
    EnsureIndexLoaded();

    gchar* contents = nullptr;
    gsize len = 0;
    if (!g_file_get_contents(clean_source.c_str(), &contents, &len, nullptr)) {
      PostMainResponse(self, response_handle, [response_handle]() {
        xue_hua_cache_cache_host_api_respond_error_put_file(
            response_handle, "INVALID_SOURCE", "Source file does not exist",
            nullptr);
      });
      g_object_unref(response_handle);
      g_object_unref(self);
      return;
    }

    int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
    int64_t cfg_max_bytes = 500LL * 1024LL * 1024LL;
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    bool cfg_auto_trim = true;
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      cfg_default_ttl = g_default_ttl_seconds;
      cfg_max_bytes = g_max_disk_cache_bytes;
      cfg_max_entries = g_max_entries;
      cfg_policy = g_eviction_policy;
      cfg_auto_trim = g_auto_trim_on_write;
    }

    const std::string ext = InferExtension(url_str, mime_str, ext_str);
    const std::string dest_path =
        GetCacheRootDir(true) + "/" + clean_key + "." + ext;
    const std::string tmp_path = dest_path + ".tmp";
    GError* write_err = nullptr;
    if (!g_file_set_contents(tmp_path.c_str(), contents, len, &write_err) ||
        std::rename(tmp_path.c_str(), dest_path.c_str()) != 0) {
      std::string err_msg =
          write_err ? write_err->message : "Failed writing cache file";
      if (write_err) g_error_free(write_err);
      g_free(contents);
      std::remove(tmp_path.c_str());
      PostMainResponse(self, response_handle, [response_handle, err_msg]() {
        xue_hua_cache_cache_host_api_respond_error_put_file(
            response_handle, "PUT_FILE_FAILED", err_msg.c_str(), nullptr);
      });
      g_object_unref(response_handle);
      g_object_unref(self);
      return;
    }

    const std::string checksum = ComputeGLibHash(
        reinterpret_cast<const uint8_t*>(contents), len, "sha256");
    g_free(contents);

    const int64_t now = CurrentTimeMs();
    const int64_t ttl_sec = ttl_opt ? *ttl_opt : cfg_default_ttl;
    LinuxCacheRecord rec;
    rec.key = clean_key;
    rec.url = url_str;
    rec.file_path = dest_path;
    rec.size_bytes = static_cast<int64_t>(len);
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag_str;
    rec.mime_type = mime_str;
    rec.checksum = checksum;
    rec.checksum_algorithm = "sha256";
    rec.pinned = is_pinned;

    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto prev = g_entries.find(clean_key);
      if (prev != g_entries.end()) {
        g_total_cached_bytes =
            std::max<int64_t>(0, g_total_cached_bytes - prev->second.size_bytes);
        if (prev->second.file_path != rec.file_path) {
          std::remove(prev->second.file_path.c_str());
        }
      }
      g_entries[clean_key] = rec;
      g_total_cached_bytes += rec.size_bytes;
      if (cfg_auto_trim) {
        EnforceQuotaLocked(cfg_max_bytes, cfg_max_entries, cfg_policy,
                           clean_key);
      }
      PersistIndexLocked();
    }

    PostMainResponse(self, response_handle, [response_handle, rec]() {
      g_autoptr(XueHuaCacheWireCacheEntry) wire = rec.ToWireEntry();
      xue_hua_cache_cache_host_api_respond_put_file(response_handle, wire);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleSetPinned(const gchar* key_or_url,
                     gboolean pinned,
                     XueHuaCacheCacheHostApiResponseHandle* response_handle,
                     gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target = key_or_url ? key_or_url : "";
  const bool next_pinned = pinned != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target,
                                        next_pinned]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(target);
    bool updated = false;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      if (it != g_entries.end()) {
        it->second.pinned = next_pinned;
        PersistIndexLocked();
        updated = true;
      }
    }
    PostMainResponse(self, response_handle, [response_handle, updated]() {
      xue_hua_cache_cache_host_api_respond_set_pinned(
          response_handle, updated ? TRUE : FALSE);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleRemoveFile(const gchar* key_or_url,
                      XueHuaCacheCacheHostApiResponseHandle* response_handle,
                      gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target = key_or_url ? key_or_url : "";
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(target);
    std::string path_to_delete;
    bool removed = false;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      auto it = g_entries.find(key);
      if (it != g_entries.end()) {
        path_to_delete = it->second.file_path;
        g_total_cached_bytes =
            std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
        g_entries.erase(it);
        PersistIndexLocked();
        removed = true;
      }
    }
    if (!path_to_delete.empty()) {
      std::remove(path_to_delete.c_str());
    }
    PostMainResponse(self, response_handle, [response_handle, removed]() {
      xue_hua_cache_cache_host_api_respond_remove_file(
          response_handle, removed ? TRUE : FALSE);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleRemoveByTag(const gchar* tag,
                       XueHuaCacheCacheHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::string target_tag = tag ? tag : "";
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, target_tag]() {
    EnsureIndexLoaded();
    std::vector<std::string> paths;
    int64_t count = 0;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      std::vector<std::string> keys;
      for (const auto& kv : g_entries) {
        if (kv.second.tag == target_tag) keys.push_back(kv.first);
      }
      paths.reserve(keys.size());
      for (const auto& k : keys) {
        auto it = g_entries.find(k);
        if (it != g_entries.end()) {
          paths.push_back(it->second.file_path);
          g_total_cached_bytes =
              std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
          g_entries.erase(it);
        }
      }
      count = static_cast<int64_t>(keys.size());
      if (count > 0) PersistIndexLocked();
    }
    for (const auto& path : paths) {
      std::remove(path.c_str());
    }
    PostMainResponse(self, response_handle, [response_handle, count]() {
      xue_hua_cache_cache_host_api_respond_remove_by_tag(response_handle,
                                                         count);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleRemoveExpired(XueHuaCacheCacheHostApiResponseHandle* response_handle,
                         gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle]() {
    EnsureIndexLoaded();
    int64_t removed = 0;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      removed = static_cast<int64_t>(RemoveExpiredLocked());
      if (removed > 0) PersistIndexLocked();
    }
    PostMainResponse(self, response_handle, [response_handle, removed]() {
      xue_hua_cache_cache_host_api_respond_remove_expired(response_handle,
                                                          removed);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleTrimToSize(int64_t max_bytes,
                      XueHuaCacheCacheHostApiResponseHandle* response_handle,
                      gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, max_bytes]() {
    EnsureIndexLoaded();
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      cfg_max_entries = g_max_entries;
      cfg_policy = g_eviction_policy;
    }
    int64_t evicted = 0;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      evicted = static_cast<int64_t>(
          EnforceQuotaLocked(max_bytes, cfg_max_entries, cfg_policy, ""));
      if (evicted > 0) PersistIndexLocked();
    }
    PostMainResponse(self, response_handle, [response_handle, evicted]() {
      xue_hua_cache_cache_host_api_respond_trim_to_size(response_handle,
                                                        evicted);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleClearAll(gboolean include_pinned,
                    XueHuaCacheCacheHostApiResponseHandle* response_handle,
                    gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const bool clear_pinned = include_pinned != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, clear_pinned]() {
    EnsureIndexLoaded();
    std::vector<std::string> paths;
    int64_t count = 0;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      std::vector<std::string> keys;
      for (const auto& kv : g_entries) {
        if (clear_pinned || !kv.second.pinned) keys.push_back(kv.first);
      }
      paths.reserve(keys.size());
      for (const auto& k : keys) {
        auto it = g_entries.find(k);
        if (it != g_entries.end()) {
          paths.push_back(it->second.file_path);
          g_total_cached_bytes =
              std::max<int64_t>(0, g_total_cached_bytes - it->second.size_bytes);
          g_entries.erase(it);
        }
      }
      count = static_cast<int64_t>(keys.size());
      PersistIndexLocked();
    }
    for (const auto& path : paths) {
      std::remove(path.c_str());
    }
    PostMainResponse(self, response_handle, [response_handle, count]() {
      xue_hua_cache_cache_host_api_respond_clear_all(response_handle, count);
    });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleListEntries(const gchar* tag,
                       gboolean include_expired,
                       XueHuaCacheCacheHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  const std::optional<std::string> tag_opt =
      tag ? std::optional<std::string>(tag) : std::nullopt;
  const bool keep_expired = include_expired != FALSE;
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle, tag_opt,
                                        keep_expired]() {
    EnsureIndexLoaded();
    const int64_t now = CurrentTimeMs();
    std::vector<LinuxCacheRecord> filtered;
    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      for (const auto& kv : g_entries) {
        if ((!tag_opt.has_value() || kv.second.tag == *tag_opt) &&
            (keep_expired || !kv.second.IsExpired(now))) {
          filtered.push_back(kv.second);
        }
      }
    }
    std::sort(filtered.begin(), filtered.end(),
              [](const LinuxCacheRecord& a, const LinuxCacheRecord& b) {
                return a.last_accessed_at_ms > b.last_accessed_at_ms;
              });

    PostMainResponse(
        self, response_handle,
        [response_handle, filtered = std::move(filtered)]() {
          g_autoptr(FlValue) list = fl_value_new_list();
          for (const auto& r : filtered) {
            g_autoptr(XueHuaCacheWireCacheEntry) wire = r.ToWireEntry();
            fl_value_append_take(
                list, fl_value_new_custom_object(
                          xue_hua_cache_wire_cache_entry_type_id,
                          G_OBJECT(wire)));
          }
          xue_hua_cache_cache_host_api_respond_list_entries(response_handle,
                                                            list);
        });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

void HandleGetStats(XueHuaCacheCacheHostApiResponseHandle* response_handle,
                    gpointer user_data) {
  auto* self = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(user_data);
  g_object_ref(self);
  g_object_ref(response_handle);

  const bool queued = GetIoPool().Post([self, response_handle]() {
    EnsureIndexLoaded();
    int64_t cfg_max_bytes = 500LL * 1024LL * 1024LL;
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      cfg_max_bytes = g_max_disk_cache_bytes;
    }
    const std::string cache_dir = GetCacheRootDir(true);
    const int64_t now = CurrentTimeMs();

    int64_t total_entries = 0;
    int64_t total_bytes = 0;
    int64_t expired_count = 0;
    int64_t pinned_count = 0;
    int64_t hits = 0;
    int64_t misses = 0;
    int64_t evictions = 0;
    std::map<std::string, int64_t> tag_sums;

    {
      std::lock_guard<std::mutex> lock(g_index_mutex);
      for (const auto& kv : g_entries) {
        total_bytes += kv.second.size_bytes;
        if (kv.second.IsExpired(now)) expired_count++;
        if (kv.second.pinned) pinned_count++;
        const std::string t =
            kv.second.tag.empty() ? "untagged" : kv.second.tag;
        tag_sums[t] += kv.second.size_bytes;
      }
      g_total_cached_bytes = total_bytes;
      total_entries = static_cast<int64_t>(g_entries.size());
      hits = g_hit_count;
      misses = g_miss_count;
      evictions = g_eviction_count;
    }

    PostMainResponse(
        self, response_handle,
        [response_handle, total_entries, total_bytes, expired_count,
         pinned_count, cfg_max_bytes, cache_dir, hits, misses, evictions,
         tag_sums = std::move(tag_sums)]() {
          g_autoptr(FlValue) bytes_by_tag = fl_value_new_map();
          for (const auto& tkv : tag_sums) {
            fl_value_set_string_take(bytes_by_tag, tkv.first.c_str(),
                                     fl_value_new_int(tkv.second));
          }
          g_autoptr(XueHuaCacheWireCacheStats) stats =
              xue_hua_cache_wire_cache_stats_new(
                  total_entries, total_bytes, expired_count, pinned_count,
                  cfg_max_bytes, cache_dir.c_str(), hits, misses, evictions,
                  bytes_by_tag);
          xue_hua_cache_cache_host_api_respond_get_stats(response_handle,
                                                         stats);
        });
    g_object_unref(response_handle);
    g_object_unref(self);
  });
  if (!queued) {
    g_object_unref(response_handle);
    g_object_unref(self);
  }
}

XueHuaCacheCacheHostApiGetCapabilitiesResponse* HandleGetCapabilities(
    gpointer /*user_data*/) {
  return get_capabilities_response();
}

const XueHuaCacheCacheHostApiVTable kCacheHostApiVTable = {
    HandleConfigure,        HandleDownloadFile,    HandlePrefetchAll,
    HandleCancelDownload,   HandleGetFileFromCache, HandleReadCacheBytes,
    HandleContainsKey,      HandlePutBytes,        HandlePutFile,
    HandleSetPinned,        HandleRemoveFile,      HandleRemoveByTag,
    HandleRemoveExpired,    HandleTrimToSize,      HandleClearAll,
    HandleListEntries,      HandleGetStats,        HandleGetCapabilities,
};

}  // namespace

XueHuaCacheCacheHostApiGetCapabilitiesResponse* get_capabilities_response() {
  const std::string default_root = GetCacheRootDir(false);
  g_autoptr(XueHuaCacheWireCachePlatformCapabilities) caps =
      xue_hua_cache_wire_cache_platform_capabilities_new(
          "linux", TRUE, TRUE, TRUE, FALSE,
          "XDG_CACHE_HOME (g_get_user_cache_dir) + GChecksum",
          default_root.c_str());
  return xue_hua_cache_cache_host_api_get_capabilities_response_new(caps);
}

XueHuaCacheCacheHostApiCancelDownloadResponse* cancel_download_response(
    const gchar* key_or_url) {
  const std::string target = key_or_url ? key_or_url : "";
  const std::string sha_key = ComputeGLibHash(
      reinterpret_cast<const uint8_t*>(target.data()), target.size(), "sha256");
  bool canceled = false;
  {
    std::lock_guard<std::mutex> lock(g_flight_mutex);
    auto it = g_in_flight.find(target);
    if (it == g_in_flight.end()) {
      it = g_in_flight.find(sha_key);
    }
    if (it != g_in_flight.end() && it->second && it->second->cancel_flag) {
      it->second->cancel_flag->store(true);
      canceled = true;
    }
  }
  return xue_hua_cache_cache_host_api_cancel_download_response_new(
      canceled ? TRUE : FALSE);
}

static void xue_hua_navite_cache_manager_plugin_dispose(GObject* object) {
  XueHuaNaviteCacheManagerPlugin* self =
      XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(object);
  self->disposed.store(true, std::memory_order_release);
  GetPersistCoordinator().FlushNow();
  if (self->messenger) {
    xue_hua_cache_cache_host_api_clear_method_handlers(self->messenger,
                                                       nullptr);
  }
  g_clear_object(&self->flutter_api);
  g_clear_object(&self->messenger);
  G_OBJECT_CLASS(xue_hua_navite_cache_manager_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_navite_cache_manager_plugin_class_init(
    XueHuaNaviteCacheManagerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = xue_hua_navite_cache_manager_plugin_dispose;
}

static void xue_hua_navite_cache_manager_plugin_init(
    XueHuaNaviteCacheManagerPlugin* self) {
  self->messenger = nullptr;
  self->flutter_api = nullptr;
  self->disposed.store(false, std::memory_order_relaxed);
}

void xue_hua_navite_cache_manager_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  XueHuaNaviteCacheManagerPlugin* plugin = XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN(
      g_object_new(xue_hua_navite_cache_manager_plugin_get_type(), nullptr));

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  plugin->messenger =
      static_cast<FlBinaryMessenger*>(g_object_ref(messenger));
  plugin->flutter_api =
      xue_hua_cache_cache_progress_flutter_api_new(messenger, nullptr);

  xue_hua_cache_cache_host_api_set_method_handlers(
      messenger, nullptr, &kCacheHostApiVTable, g_object_ref(plugin),
      g_object_unref);

  g_object_unref(plugin);
}
