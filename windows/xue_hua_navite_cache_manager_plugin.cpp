#include "xue_hua_navite_cache_manager_plugin.h"

#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <shlobj.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <thread>

namespace fs = std::filesystem;

namespace xue_hua_navite_cache_manager {

namespace {

int64_t CurrentTimeMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, str.data(),
                                        static_cast<int>(str.size()), nullptr, 0);
  std::wstring out(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      &out[0], size_needed);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                                        static_cast<int>(wstr.size()), nullptr,
                                        0, nullptr, nullptr);
  std::string out(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                      &out[0], size_needed, nullptr, nullptr);
  return out;
}

std::string ComputeBCryptHash(const uint8_t* data,
                              size_t length,
                              const std::string& algorithm) {
  LPCWSTR alg_id = (algorithm == "md5" || algorithm == "MD5")
                       ? BCRYPT_MD5_ALGORITHM
                       : BCRYPT_SHA256_ALGORITHM;
  BCRYPT_ALG_HANDLE hAlg = nullptr;
  BCRYPT_HASH_HANDLE hHash = nullptr;
  DWORD cbData = 0, cbHash = 0, cbHashObject = 0;

  if (BCryptOpenAlgorithmProvider(&hAlg, alg_id, nullptr, 0) != 0) {
    return "";
  }
  BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH, (PBYTE)&cbHashObject,
                    sizeof(DWORD), &cbData, 0);
  BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH, (PBYTE)&cbHash, sizeof(DWORD),
                    &cbData, 0);

  std::vector<uint8_t> hashObject(cbHashObject);
  std::vector<uint8_t> hashBytes(cbHash);

  if (BCryptCreateHash(hAlg, &hHash, hashObject.data(), cbHashObject, nullptr,
                       0, 0) == 0) {
    BCryptHashData(hHash, const_cast<PUCHAR>(data), static_cast<ULONG>(length),
                   0);
    BCryptFinishHash(hHash, hashBytes.data(), cbHash, 0);
    BCryptDestroyHash(hHash);
  }
  BCryptCloseAlgorithmProvider(hAlg, 0);

  std::ostringstream oss;
  for (uint8_t b : hashBytes) {
    oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
  }
  return oss.str();
}

std::string GetStringArg(const flutter::EncodableMap& args,
                         const std::string& key,
                         const std::string& default_val = "") {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return default_val;
}

int64_t GetInt64Arg(const flutter::EncodableMap& args,
                    const std::string& key,
                    int64_t default_val = 0) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (std::holds_alternative<int64_t>(it->second)) {
      return std::get<int64_t>(it->second);
    }
    if (std::holds_alternative<int32_t>(it->second)) {
      return static_cast<int64_t>(std::get<int32_t>(it->second));
    }
  }
  return default_val;
}

bool HasArg(const flutter::EncodableMap& args, const std::string& key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it != args.end() && !it->second.IsNull();
}

bool GetBoolArg(const flutter::EncodableMap& args,
                const std::string& key,
                bool default_val = false) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return default_val;
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

std::wstring QueryWinHttpHeader(HINTERNET hRequest, DWORD info_level) {
  DWORD dwSize = 0;
  WinHttpQueryHeaders(hRequest, info_level, WINHTTP_HEADER_NAME_BY_INDEX,
                      nullptr, &dwSize, WINHTTP_NO_HEADER_INDEX);
  if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && dwSize > 0) {
    std::wstring buffer(dwSize / sizeof(wchar_t), L'\0');
    if (WinHttpQueryHeaders(hRequest, info_level, WINHTTP_HEADER_NAME_BY_INDEX,
                            &buffer[0], &dwSize, WINHTTP_NO_HEADER_INDEX)) {
      if (!buffer.empty() && buffer.back() == L'\0') {
        buffer.pop_back();
      }
      return buffer;
    }
  }
  return L"";
}

}  // namespace

flutter::EncodableMap CacheRecord::ToEncodableMap() const {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("key")] = flutter::EncodableValue(key);
  map[flutter::EncodableValue("url")] = flutter::EncodableValue(url);
  map[flutter::EncodableValue("filePath")] = flutter::EncodableValue(file_path);
  map[flutter::EncodableValue("sizeBytes")] = flutter::EncodableValue(size_bytes);
  map[flutter::EncodableValue("createdAtMs")] = flutter::EncodableValue(created_at_ms);
  map[flutter::EncodableValue("lastAccessedAtMs")] = flutter::EncodableValue(last_accessed_at_ms);
  map[flutter::EncodableValue("expiresAtMs")] = flutter::EncodableValue(expires_at_ms);
  map[flutter::EncodableValue("hitCount")] = flutter::EncodableValue(hit_count);
  map[flutter::EncodableValue("tag")] =
      tag.empty() ? flutter::EncodableValue() : flutter::EncodableValue(tag);
  map[flutter::EncodableValue("mimeType")] =
      mime_type.empty() ? flutter::EncodableValue()
                        : flutter::EncodableValue(mime_type);
  map[flutter::EncodableValue("eTag")] =
      etag.empty() ? flutter::EncodableValue() : flutter::EncodableValue(etag);
  map[flutter::EncodableValue("lastModified")] =
      last_modified.empty() ? flutter::EncodableValue()
                            : flutter::EncodableValue(last_modified);
  map[flutter::EncodableValue("checksum")] =
      checksum.empty() ? flutter::EncodableValue()
                       : flutter::EncodableValue(checksum);
  map[flutter::EncodableValue("checksumAlgorithm")] =
      flutter::EncodableValue(checksum_algorithm);
  map[flutter::EncodableValue("pinned")] = flutter::EncodableValue(pinned);
  return map;
}

// static
void XueHuaNaviteCacheManagerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "xue_hua_navite_cache_manager",
          &flutter::StandardMethodCodec::GetInstance());

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "xue_hua_navite_cache_manager/events",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<XueHuaNaviteCacheManagerPlugin>();
  auto* plugin_pointer = plugin.get();

  method_channel->SetMethodCallHandler(
      [plugin_pointer](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        plugin_pointer->SetEventSink(std::move(events));
        return nullptr;
      },
      [plugin_pointer](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        plugin_pointer->SetEventSink(nullptr);
        return nullptr;
      });
  event_channel->SetStreamHandler(std::move(handler));

  registrar->AddPlugin(std::move(plugin));
}

XueHuaNaviteCacheManagerPlugin::XueHuaNaviteCacheManagerPlugin() {}

XueHuaNaviteCacheManagerPlugin::~XueHuaNaviteCacheManagerPlugin() {}

void XueHuaNaviteCacheManagerPlugin::SetEventSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  event_sink_ = std::move(sink);
}

void XueHuaNaviteCacheManagerPlugin::EmitProgress(
    const std::string& key,
    const std::string& url,
    const std::string& state,
    int64_t bytes_received,
    int64_t total_bytes,
    const std::string& file_path,
    const std::string& error_message) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  if (!event_sink_) return;
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("key")] = flutter::EncodableValue(key);
  payload[flutter::EncodableValue("url")] = flutter::EncodableValue(url);
  payload[flutter::EncodableValue("state")] = flutter::EncodableValue(state);
  payload[flutter::EncodableValue("bytesReceived")] =
      flutter::EncodableValue(bytes_received);
  payload[flutter::EncodableValue("totalBytes")] =
      flutter::EncodableValue(total_bytes);
  payload[flutter::EncodableValue("filePath")] =
      file_path.empty() ? flutter::EncodableValue()
                        : flutter::EncodableValue(file_path);
  payload[flutter::EncodableValue("errorMessage")] =
      error_message.empty() ? flutter::EncodableValue()
                            : flutter::EncodableValue(error_message);
  event_sink_->Success(flutter::EncodableValue(payload));
}

std::string XueHuaNaviteCacheManagerPlugin::GetCacheRootDir() const {
  PWSTR path_tmp = nullptr;
  std::filesystem::path base_path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                     &path_tmp))) {
    base_path = std::filesystem::path(path_tmp) / "Temp" / cache_subdirectory_;
    CoTaskMemFree(path_tmp);
  } else {
    base_path = std::filesystem::temp_directory_path() / cache_subdirectory_;
  }
  std::error_code ec;
  std::filesystem::create_directories(base_path, ec);
  return WideToUtf8(base_path.wstring());
}

std::string XueHuaNaviteCacheManagerPlugin::GetIndexFilePath() const {
  fs::path p = fs::u8path(GetCacheRootDir()) / "cache_index_v1.tsv";
  return WideToUtf8(p.wstring());
}

void XueHuaNaviteCacheManagerPlugin::EnsureIndexLoaded() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (index_loaded_) return;
  index_loaded_ = true;
  entries_.clear();

  std::ifstream in(fs::u8path(GetIndexFilePath()));
  if (!in.is_open()) return;

  std::string line;
  if (std::getline(in, line)) {
    std::istringstream header_ss(line);
    header_ss >> hit_count_ >> miss_count_ >> eviction_count_;
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
      CacheRecord rec;
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

      std::error_code ec;
      if (!rec.key.empty() && fs::exists(fs::u8path(rec.file_path), ec)) {
        entries_[rec.key] = rec;
      }
    }
  }
}

void XueHuaNaviteCacheManagerPlugin::PersistIndexLocked() {
  std::ofstream out(fs::u8path(GetIndexFilePath()), std::ios::trunc);
  if (!out.is_open()) return;
  out << hit_count_ << " " << miss_count_ << " " << eviction_count_ << "\n";
  for (const auto& kv : entries_) {
    const auto& r = kv.second;
    out << r.key << "\t" << r.url << "\t" << r.file_path << "\t" << r.size_bytes
        << "\t" << r.created_at_ms << "\t" << r.last_accessed_at_ms << "\t"
        << r.expires_at_ms << "\t" << r.hit_count << "\t" << r.tag << "\t"
        << r.mime_type << "\t" << r.etag << "\t" << r.last_modified << "\t"
        << r.checksum << "\t" << r.checksum_algorithm << "\t"
        << (r.pinned ? "1" : "0") << "\n";
  }
}

std::string XueHuaNaviteCacheManagerPlugin::ResolveKey(
    const std::string& key_or_url,
    const std::string& custom_key) {
  if (!custom_key.empty()) return custom_key;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (entries_.find(key_or_url) != entries_.end()) {
      return key_or_url;
    }
  }
  return ComputeBCryptHash(reinterpret_cast<const uint8_t*>(key_or_url.data()),
                           key_or_url.size(), "sha256");
}

int XueHuaNaviteCacheManagerPlugin::RemoveExpiredLocked() {
  int64_t now = CurrentTimeMs();
  std::vector<std::string> expired_keys;
  for (const auto& kv : entries_) {
    if (!kv.second.pinned && kv.second.IsExpired(now)) {
      expired_keys.push_back(kv.first);
    }
  }
  std::error_code ec;
  for (const auto& k : expired_keys) {
    fs::remove(fs::u8path(entries_[k].file_path), ec);
    entries_.erase(k);
  }
  eviction_count_ += static_cast<int64_t>(expired_keys.size());
  return static_cast<int>(expired_keys.size());
}

int XueHuaNaviteCacheManagerPlugin::EnforceQuotaLocked(
    int64_t target_max_bytes,
    const std::string& protected_key) {
  int evicted = RemoveExpiredLocked();
  if (eviction_policy_ == "ttlOnly") return evicted;

  int64_t total_bytes = 0;
  for (const auto& kv : entries_) {
    total_bytes += kv.second.size_bytes;
  }
  if (total_bytes <= target_max_bytes &&
      static_cast<int>(entries_.size()) <= max_entries_) {
    return evicted;
  }

  std::vector<CacheRecord> candidates;
  for (const auto& kv : entries_) {
    if (!kv.second.pinned && kv.first != protected_key) {
      candidates.push_back(kv.second);
    }
  }

  std::sort(candidates.begin(), candidates.end(),
            [this](const CacheRecord& a, const CacheRecord& b) {
              if (eviction_policy_ == "lfu") {
                if (a.hit_count != b.hit_count) return a.hit_count < b.hit_count;
                return a.last_accessed_at_ms < b.last_accessed_at_ms;
              }
              if (eviction_policy_ == "fifo") {
                return a.created_at_ms < b.created_at_ms;
              }
              return a.last_accessed_at_ms < b.last_accessed_at_ms;
            });

  std::error_code ec;
  for (const auto& cand : candidates) {
    if (total_bytes <= target_max_bytes &&
        static_cast<int>(entries_.size()) <= max_entries_) {
      break;
    }
    fs::remove(fs::u8path(cand.file_path), ec);
    total_bytes -= cand.size_bytes;
    entries_.erase(cand.key);
    evicted++;
    eviction_count_++;
  }
  return evicted;
}

bool XueHuaNaviteCacheManagerPlugin::ExecuteDownloadLockedOrUnlocked(
    const flutter::EncodableMap& args,
    flutter::EncodableMap* out_result,
    std::string* out_error_code,
    std::string* out_error_msg) {
  int64_t start_ms = CurrentTimeMs();
  std::string url = GetStringArg(args, "url");
  if (url.empty()) {
    *out_error_code = "INVALID_URL";
    *out_error_msg = "URL is required";
    return false;
  }
  std::string custom_key = GetStringArg(args, "customKey");
  std::string tag = GetStringArg(args, "tag");
  std::string file_extension = GetStringArg(args, "fileExtension");
  bool has_ttl = HasArg(args, "ttlSeconds");
  int64_t ttl_override = GetInt64Arg(args, "ttlSeconds", default_ttl_seconds_);
  bool force_refresh = GetBoolArg(args, "forceRefresh", false);
  bool fallback_on_error = GetBoolArg(args, "fallbackToCacheOnError", true);
  bool pinned = GetBoolArg(args, "pinned", false);
  std::string checksum_alg = GetStringArg(args, "checksumAlgorithm", "none");
  std::string expected_checksum = GetStringArg(args, "expectedChecksum");

  std::string key = ResolveKey(url, custom_key);
  CacheRecord existing_record;
  bool has_existing = false;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(key);
    std::error_code ec;
    if (it != entries_.end() && fs::exists(fs::u8path(it->second.file_path), ec)) {
      existing_record = it->second;
      has_existing = true;
      if (!force_refresh && !it->second.IsExpired(start_ms)) {
        it->second.last_accessed_at_ms = start_ms;
        it->second.hit_count += 1;
        if (!tag.empty()) it->second.tag = tag;
        if (pinned) it->second.pinned = true;
        hit_count_++;
        PersistIndexLocked();
        EmitProgress(key, url, "cacheHit", it->second.size_bytes,
                     it->second.size_bytes, it->second.file_path);
        (*out_result)[flutter::EncodableValue("entry")] =
            flutter::EncodableValue(it->second.ToEncodableMap());
        (*out_result)[flutter::EncodableValue("source")] =
            flutter::EncodableValue("cacheHit");
        (*out_result)[flutter::EncodableValue("httpStatusCode")] =
            flutter::EncodableValue();
        (*out_result)[flutter::EncodableValue("elapsedMs")] =
            flutter::EncodableValue(CurrentTimeMs() - start_ms);
        return true;
      }
    }
    miss_count_++;
  }

  auto cancel_flag = std::make_shared<std::atomic<bool>>(false);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_[key] = cancel_flag;
  }
  EmitProgress(key, url, "started", 0, -1);

  std::wstring wurl = Utf8ToWide(url);
  URL_COMPONENTS urlComp = {};
  urlComp.dwStructSize = sizeof(urlComp);
  wchar_t hostName[256] = {};
  wchar_t urlPath[2048] = {};
  urlComp.lpszHostName = hostName;
  urlComp.dwHostNameLength = _countof(hostName);
  urlComp.lpszUrlPath = urlPath;
  urlComp.dwUrlPathLength = _countof(urlPath);

  if (!WinHttpCrackUrl(wurl.c_str(), static_cast<DWORD>(wurl.size()), 0,
                       &urlComp)) {
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    *out_error_code = "INVALID_URL";
    *out_error_msg = "WinHttpCrackUrl failed";
    return false;
  }

  HINTERNET hSession = WinHttpOpen(L"XueHuaNativeCacheManager/1.0",
                                   WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                   WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0);
  if (!hSession) {
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    *out_error_code = "NETWORK_ERROR";
    *out_error_msg = "WinHttpOpen failed";
    return false;
  }

  WinHttpSetTimeouts(hSession, connect_timeout_ms_, connect_timeout_ms_,
                     read_timeout_ms_, read_timeout_ms_);

  HINTERNET hConnect =
      WinHttpConnect(hSession, hostName, urlComp.nPort, 0);
  if (!hConnect) {
    WinHttpCloseHandle(hSession);
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    *out_error_code = "NETWORK_ERROR";
    *out_error_msg = "WinHttpConnect failed";
    return false;
  }

  DWORD flags =
      (urlComp.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
  HINTERNET hRequest =
      WinHttpOpenRequest(hConnect, L"GET", urlPath, nullptr,
                         WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
  if (!hRequest) {
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    *out_error_code = "NETWORK_ERROR";
    *out_error_msg = "WinHttpOpenRequest failed";
    return false;
  }

  if (respect_http_cache_headers_ && has_existing) {
    if (!existing_record.etag.empty()) {
      std::wstring hdr = L"If-None-Match: " + Utf8ToWide(existing_record.etag);
      WinHttpAddRequestHeaders(hRequest, hdr.c_str(),
                               static_cast<DWORD>(hdr.size()),
                               WINHTTP_ADDREQ_FLAG_ADD);
    }
    if (!existing_record.last_modified.empty()) {
      std::wstring hdr =
          L"If-Modified-Since: " + Utf8ToWide(existing_record.last_modified);
      WinHttpAddRequestHeaders(hRequest, hdr.c_str(),
                               static_cast<DWORD>(hdr.size()),
                               WINHTTP_ADDREQ_FLAG_ADD);
    }
  }

  BOOL bResults = WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                     WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
  if (bResults) {
    bResults = WinHttpReceiveResponse(hRequest, nullptr);
  }

  if (!bResults) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    if (fallback_on_error && has_existing) {
      (*out_result)[flutter::EncodableValue("entry")] =
          flutter::EncodableValue(existing_record.ToEncodableMap());
      (*out_result)[flutter::EncodableValue("source")] =
          flutter::EncodableValue("staleCacheFallback");
      (*out_result)[flutter::EncodableValue("httpStatusCode")] =
          flutter::EncodableValue();
      (*out_result)[flutter::EncodableValue("elapsedMs")] =
          flutter::EncodableValue(CurrentTimeMs() - start_ms);
      return true;
    }
    *out_error_code = "NETWORK_ERROR";
    *out_error_msg = "WinHttpSendRequest/ReceiveResponse failed";
    return false;
  }

  DWORD status_code = 0;
  DWORD dwSize = sizeof(status_code);
  WinHttpQueryHeaders(hRequest,
                      WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                      WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &dwSize,
                      WINHTTP_NO_HEADER_INDEX);

  if (status_code == 304 && has_existing) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    int64_t now = CurrentTimeMs();
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    existing_record.last_accessed_at_ms = now;
    existing_record.expires_at_ms =
        now + (has_ttl ? ttl_override : default_ttl_seconds_) * 1000LL;
    existing_record.hit_count += 1;
    entries_[key] = existing_record;
    PersistIndexLocked();

    EmitProgress(key, url, "cacheHit", existing_record.size_bytes,
                 existing_record.size_bytes, existing_record.file_path);
    (*out_result)[flutter::EncodableValue("entry")] =
        flutter::EncodableValue(existing_record.ToEncodableMap());
    (*out_result)[flutter::EncodableValue("source")] =
        flutter::EncodableValue("revalidated");
    (*out_result)[flutter::EncodableValue("httpStatusCode")] =
        flutter::EncodableValue(304);
    (*out_result)[flutter::EncodableValue("elapsedMs")] =
        flutter::EncodableValue(now - start_ms);
    return true;
  }

  if (status_code < 200 || status_code >= 300) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
    if (fallback_on_error && has_existing) {
      (*out_result)[flutter::EncodableValue("entry")] =
          flutter::EncodableValue(existing_record.ToEncodableMap());
      (*out_result)[flutter::EncodableValue("source")] =
          flutter::EncodableValue("staleCacheFallback");
      (*out_result)[flutter::EncodableValue("httpStatusCode")] =
          flutter::EncodableValue(static_cast<int>(status_code));
      (*out_result)[flutter::EncodableValue("elapsedMs")] =
          flutter::EncodableValue(CurrentTimeMs() - start_ms);
      return true;
    }
    *out_error_code = "HTTP_ERROR";
    *out_error_msg = "HTTP status " + std::to_string(status_code);
    return false;
  }

  std::string content_type =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_CONTENT_TYPE));
  std::string etag =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_ETAG));
  std::string last_modified =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_LAST_MODIFIED));

  std::vector<uint8_t> buffer;
  DWORD dwDownloaded = 0;
  do {
    DWORD dwAvailable = 0;
    if (!WinHttpQueryDataAvailable(hRequest, &dwAvailable) || dwAvailable == 0) {
      break;
    }
    if (cancel_flag->load()) {
      WinHttpCloseHandle(hRequest);
      WinHttpCloseHandle(hConnect);
      WinHttpCloseHandle(hSession);
      std::lock_guard<std::mutex> lock(mutex_);
      active_cancels_.erase(key);
      EmitProgress(key, url, "canceled", 0, -1, "", "Download canceled");
      *out_error_code = "CANCELED";
      *out_error_msg = "Download canceled";
      return false;
    }
    size_t cur_size = buffer.size();
    buffer.resize(cur_size + dwAvailable);
    if (WinHttpReadData(hRequest, buffer.data() + cur_size, dwAvailable,
                        &dwDownloaded)) {
      buffer.resize(cur_size + dwDownloaded);
      EmitProgress(key, url, "inProgress",
                   static_cast<int64_t>(buffer.size()), -1);
    } else {
      break;
    }
  } while (dwDownloaded > 0);

  WinHttpCloseHandle(hRequest);
  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_.erase(key);
  }

  std::string computed_hash;
  if (checksum_alg != "none") {
    computed_hash =
        ComputeBCryptHash(buffer.data(), buffer.size(), checksum_alg);
    if (!expected_checksum.empty() && computed_hash != expected_checksum) {
      EmitProgress(key, url, "failed", 0, -1, "", "Checksum mismatch");
      *out_error_code = "CHECKSUM_MISMATCH";
      *out_error_msg = "Checksum mismatch";
      return false;
    }
  }

  std::string ext = InferExtension(url, content_type, file_extension);
  fs::path dest_path = fs::u8path(GetCacheRootDir()) / (key + "." + ext);
  {
    std::ofstream ofs(dest_path, std::ios::binary | std::ios::trunc);
    ofs.write(reinterpret_cast<const char*>(buffer.data()),
              static_cast<std::streamsize>(buffer.size()));
  }

  int64_t now = CurrentTimeMs();
  int64_t ttl_sec = has_ttl ? ttl_override : default_ttl_seconds_;

  CacheRecord record;
  record.key = key;
  record.url = url;
  record.file_path = WideToUtf8(dest_path.wstring());
  record.size_bytes = static_cast<int64_t>(buffer.size());
  record.created_at_ms = now;
  record.last_accessed_at_ms = now;
  record.expires_at_ms = now + ttl_sec * 1000LL;
  record.hit_count = 1;
  record.tag = tag;
  record.mime_type =
      content_type.empty() ? "application/octet-stream" : content_type;
  record.etag = etag;
  record.last_modified = last_modified;
  record.checksum = computed_hash;
  record.checksum_algorithm = checksum_alg;
  record.pinned = pinned;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_[key] = record;
    if (auto_trim_on_write_) {
      EnforceQuotaLocked(max_disk_cache_bytes_, key);
    }
    PersistIndexLocked();
  }

  EmitProgress(key, url, "completed", record.size_bytes, record.size_bytes,
               record.file_path);

  (*out_result)[flutter::EncodableValue("entry")] =
      flutter::EncodableValue(record.ToEncodableMap());
  (*out_result)[flutter::EncodableValue("source")] =
      flutter::EncodableValue("networkDownload");
  (*out_result)[flutter::EncodableValue("httpStatusCode")] =
      flutter::EncodableValue(static_cast<int>(status_code));
  (*out_result)[flutter::EncodableValue("elapsedMs")] =
      flutter::EncodableValue(CurrentTimeMs() - start_ms);
  return true;
}

void XueHuaNaviteCacheManagerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  EnsureIndexLoaded();
  const std::string& method = method_call.method_name();
  flutter::EncodableMap args;
  if (method_call.arguments() &&
      std::holds_alternative<flutter::EncodableMap>(*method_call.arguments())) {
    args = std::get<flutter::EncodableMap>(*method_call.arguments());
  }

  if (method == "configure") {
    std::lock_guard<std::mutex> lock(mutex_);
    max_disk_cache_bytes_ =
        GetInt64Arg(args, "maxDiskCacheBytes", max_disk_cache_bytes_);
    max_entries_ =
        static_cast<int>(GetInt64Arg(args, "maxEntries", max_entries_));
    default_ttl_seconds_ =
        GetInt64Arg(args, "defaultTtlSeconds", default_ttl_seconds_);
    eviction_policy_ = GetStringArg(args, "evictionPolicy", eviction_policy_);
    std::string subdir =
        GetStringArg(args, "cacheSubdirectory", cache_subdirectory_);
    if (!subdir.empty()) cache_subdirectory_ = subdir;
    respect_http_cache_headers_ =
        GetBoolArg(args, "respectHttpCacheHeaders", respect_http_cache_headers_);
    auto_trim_on_write_ = GetBoolArg(args, "autoTrimOnWrite", auto_trim_on_write_);
    if (auto_trim_on_write_) {
      EnforceQuotaLocked(max_disk_cache_bytes_, "");
      PersistIndexLocked();
    }
    result->Success();
  } else if (method == "downloadFile") {
    flutter::EncodableMap out_map;
    std::string err_code, err_msg;
    if (ExecuteDownloadLockedOrUnlocked(args, &out_map, &err_code, &err_msg)) {
      result->Success(flutter::EncodableValue(out_map));
    } else {
      result->Error(err_code, err_msg);
    }
  } else if (method == "prefetchAll") {
    flutter::EncodableList list_out;
    auto it = args.find(flutter::EncodableValue("requests"));
    if (it != args.end() &&
        std::holds_alternative<flutter::EncodableList>(it->second)) {
      const auto& reqs = std::get<flutter::EncodableList>(it->second);
      for (const auto& item : reqs) {
        if (std::holds_alternative<flutter::EncodableMap>(item)) {
          flutter::EncodableMap out_map;
          std::string err_code, err_msg;
          if (ExecuteDownloadLockedOrUnlocked(
                  std::get<flutter::EncodableMap>(item), &out_map, &err_code,
                  &err_msg)) {
            list_out.push_back(out_map[flutter::EncodableValue("entry")]);
          }
        }
      }
    }
    result->Success(flutter::EncodableValue(list_out));
  } else if (method == "cancelDownload") {
    std::string key_or_url = GetStringArg(args, "keyOrUrl");
    std::string key = ResolveKey(key_or_url);
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = active_cancels_.find(key);
    if (it != active_cancels_.end()) {
      it->second->store(true);
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Success(flutter::EncodableValue(false));
    }
  } else if (method == "getFileFromCache") {
    std::string key_or_url = GetStringArg(args, "keyOrUrl");
    bool ignore_expired = GetBoolArg(args, "ignoreExpired", true);
    std::string key = ResolveKey(key_or_url);

    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(key);
    std::error_code ec;
    if (it == entries_.end() || !fs::exists(fs::u8path(it->second.file_path), ec)) {
      miss_count_++;
      result->Success(flutter::EncodableValue());
      return;
    }
    int64_t now = CurrentTimeMs();
    if (ignore_expired && it->second.IsExpired(now)) {
      miss_count_++;
      result->Success(flutter::EncodableValue());
      return;
    }
    it->second.last_accessed_at_ms = now;
    it->second.hit_count++;
    hit_count_++;
    PersistIndexLocked();
    result->Success(flutter::EncodableValue(it->second.ToEncodableMap()));
  } else if (method == "readCacheBytes") {
    std::string key_or_url = GetStringArg(args, "keyOrUrl");
    bool ignore_expired = GetBoolArg(args, "ignoreExpired", true);
    std::string key = ResolveKey(key_or_url);

    std::string file_path;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = entries_.find(key);
      int64_t now = CurrentTimeMs();
      std::error_code ec;
      if (it != entries_.end() &&
          (!ignore_expired || !it->second.IsExpired(now)) &&
          fs::exists(fs::u8path(it->second.file_path), ec)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        hit_count_++;
        PersistIndexLocked();
        file_path = it->second.file_path;
      } else {
        miss_count_++;
      }
    }
    if (file_path.empty()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    std::ifstream ifs(fs::u8path(file_path), std::ios::binary | std::ios::ate);
    if (!ifs.is_open()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    std::streamsize size = ifs.tellg();
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    ifs.read(reinterpret_cast<char*>(bytes.data()), size);
    result->Success(flutter::EncodableValue(bytes));
  } else if (method == "containsKey") {
    std::string key_or_url = GetStringArg(args, "keyOrUrl");
    bool ignore_expired = GetBoolArg(args, "ignoreExpired", true);
    std::string key = ResolveKey(key_or_url);

    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(key);
    std::error_code ec;
    if (it == entries_.end() || !fs::exists(fs::u8path(it->second.file_path), ec)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    if (ignore_expired && it->second.IsExpired(CurrentTimeMs())) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(true));
  } else if (method == "putBytes") {
    std::string key = GetStringArg(args, "key");
    auto it_bytes = args.find(flutter::EncodableValue("bytes"));
    if (key.empty() || it_bytes == args.end() ||
        !std::holds_alternative<std::vector<uint8_t>>(it_bytes->second)) {
      result->Error("INVALID_ARGS", "key and bytes are required");
      return;
    }
    const auto& bytes = std::get<std::vector<uint8_t>>(it_bytes->second);
    std::string url = GetStringArg(args, "url", "local://" + key);
    std::string file_ext = GetStringArg(args, "fileExtension");
    std::string mime_type =
        GetStringArg(args, "mimeType", "application/octet-stream");
    std::string tag = GetStringArg(args, "tag");
    int64_t ttl_sec = GetInt64Arg(args, "ttlSeconds", default_ttl_seconds_);
    bool pinned = GetBoolArg(args, "pinned", false);

    std::string ext = InferExtension(url, mime_type, file_ext);
    fs::path dest_path = fs::u8path(GetCacheRootDir()) / (key + "." + ext);
    {
      std::ofstream ofs(dest_path, std::ios::binary | std::ios::trunc);
      ofs.write(reinterpret_cast<const char*>(bytes.data()),
                static_cast<std::streamsize>(bytes.size()));
    }
    int64_t now = CurrentTimeMs();
    CacheRecord rec;
    rec.key = key;
    rec.url = url;
    rec.file_path = WideToUtf8(dest_path.wstring());
    rec.size_bytes = static_cast<int64_t>(bytes.size());
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag;
    rec.mime_type = mime_type;
    rec.checksum = ComputeBCryptHash(bytes.data(), bytes.size(), "sha256");
    rec.checksum_algorithm = "sha256";
    rec.pinned = pinned;

    {
      std::lock_guard<std::mutex> lock(mutex_);
      entries_[key] = rec;
      if (auto_trim_on_write_) {
        EnforceQuotaLocked(max_disk_cache_bytes_, key);
      }
      PersistIndexLocked();
    }
    result->Success(flutter::EncodableValue(rec.ToEncodableMap()));
  } else if (method == "putFile") {
    std::string key = GetStringArg(args, "key");
    std::string source_path = GetStringArg(args, "sourceFilePath");
    std::error_code ec;
    if (key.empty() || source_path.empty() ||
        !fs::exists(fs::u8path(source_path), ec)) {
      result->Error("INVALID_SOURCE", "Source file does not exist");
      return;
    }
    std::ifstream ifs(fs::u8path(source_path), std::ios::binary | std::ios::ate);
    std::streamsize size = ifs.tellg();
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    ifs.read(reinterpret_cast<char*>(bytes.data()), size);

    std::string url = GetStringArg(args, "url", "file://" + source_path);
    std::string file_ext = GetStringArg(args, "fileExtension");
    std::string mime_type =
        GetStringArg(args, "mimeType", "application/octet-stream");
    std::string tag = GetStringArg(args, "tag");
    int64_t ttl_sec = GetInt64Arg(args, "ttlSeconds", default_ttl_seconds_);
    bool pinned = GetBoolArg(args, "pinned", false);

    std::string ext = InferExtension(url, mime_type, file_ext);
    fs::path dest_path = fs::u8path(GetCacheRootDir()) / (key + "." + ext);
    fs::copy_file(fs::u8path(source_path), dest_path,
                  fs::copy_options::overwrite_existing, ec);

    int64_t now = CurrentTimeMs();
    CacheRecord rec;
    rec.key = key;
    rec.url = url;
    rec.file_path = WideToUtf8(dest_path.wstring());
    rec.size_bytes = static_cast<int64_t>(bytes.size());
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag;
    rec.mime_type = mime_type;
    rec.checksum = ComputeBCryptHash(bytes.data(), bytes.size(), "sha256");
    rec.checksum_algorithm = "sha256";
    rec.pinned = pinned;

    {
      std::lock_guard<std::mutex> lock(mutex_);
      entries_[key] = rec;
      if (auto_trim_on_write_) {
        EnforceQuotaLocked(max_disk_cache_bytes_, key);
      }
      PersistIndexLocked();
    }
    result->Success(flutter::EncodableValue(rec.ToEncodableMap()));
  } else if (method == "setPinned") {
    std::string key = ResolveKey(GetStringArg(args, "keyOrUrl"));
    bool pinned = GetBoolArg(args, "pinned", false);
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(key);
    if (it == entries_.end()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    it->second.pinned = pinned;
    PersistIndexLocked();
    result->Success(flutter::EncodableValue(true));
  } else if (method == "removeFile") {
    std::string key = ResolveKey(GetStringArg(args, "keyOrUrl"));
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(key);
    if (it == entries_.end()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    std::error_code ec;
    fs::remove(fs::u8path(it->second.file_path), ec);
    entries_.erase(it);
    PersistIndexLocked();
    result->Success(flutter::EncodableValue(true));
  } else if (method == "removeByTag") {
    std::string tag = GetStringArg(args, "tag");
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> keys;
    for (const auto& kv : entries_) {
      if (kv.second.tag == tag) keys.push_back(kv.first);
    }
    std::error_code ec;
    for (const auto& k : keys) {
      fs::remove(fs::u8path(entries_[k].file_path), ec);
      entries_.erase(k);
    }
    if (!keys.empty()) PersistIndexLocked();
    result->Success(flutter::EncodableValue(static_cast<int>(keys.size())));
  } else if (method == "removeExpired") {
    std::lock_guard<std::mutex> lock(mutex_);
    int removed = RemoveExpiredLocked();
    if (removed > 0) PersistIndexLocked();
    result->Success(flutter::EncodableValue(removed));
  } else if (method == "trimToSize") {
    int64_t max_bytes = GetInt64Arg(args, "maxBytes", max_disk_cache_bytes_);
    std::lock_guard<std::mutex> lock(mutex_);
    int evicted = EnforceQuotaLocked(max_bytes, "");
    if (evicted > 0) PersistIndexLocked();
    result->Success(flutter::EncodableValue(evicted));
  } else if (method == "clearAll") {
    bool include_pinned = GetBoolArg(args, "includePinned", true);
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::string> keys;
    for (const auto& kv : entries_) {
      if (include_pinned || !kv.second.pinned) keys.push_back(kv.first);
    }
    std::error_code ec;
    for (const auto& k : keys) {
      fs::remove(fs::u8path(entries_[k].file_path), ec);
      entries_.erase(k);
    }
    PersistIndexLocked();
    result->Success(flutter::EncodableValue(static_cast<int>(keys.size())));
  } else if (method == "listEntries") {
    std::string tag = GetStringArg(args, "tag");
    bool has_tag = HasArg(args, "tag");
    bool include_expired = GetBoolArg(args, "includeExpired", true);
    int64_t now = CurrentTimeMs();

    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<CacheRecord> filtered;
    for (const auto& kv : entries_) {
      if ((!has_tag || kv.second.tag == tag) &&
          (include_expired || !kv.second.IsExpired(now))) {
        filtered.push_back(kv.second);
      }
    }
    std::sort(filtered.begin(), filtered.end(),
              [](const CacheRecord& a, const CacheRecord& b) {
                return a.last_accessed_at_ms > b.last_accessed_at_ms;
              });
    flutter::EncodableList out;
    for (const auto& r : filtered) {
      out.push_back(flutter::EncodableValue(r.ToEncodableMap()));
    }
    result->Success(flutter::EncodableValue(out));
  } else if (method == "getStats") {
    int64_t now = CurrentTimeMs();
    std::lock_guard<std::mutex> lock(mutex_);
    int64_t total_bytes = 0;
    int expired_count = 0;
    int pinned_count = 0;
    flutter::EncodableMap bytes_by_tag;
    std::map<std::string, int64_t> tag_sums;

    for (const auto& kv : entries_) {
      total_bytes += kv.second.size_bytes;
      if (kv.second.IsExpired(now)) expired_count++;
      if (kv.second.pinned) pinned_count++;
      std::string t = kv.second.tag.empty() ? "untagged" : kv.second.tag;
      tag_sums[t] += kv.second.size_bytes;
    }
    for (const auto& tkv : tag_sums) {
      bytes_by_tag[flutter::EncodableValue(tkv.first)] =
          flutter::EncodableValue(tkv.second);
    }

    flutter::EncodableMap stats;
    stats[flutter::EncodableValue("totalEntries")] =
        flutter::EncodableValue(static_cast<int>(entries_.size()));
    stats[flutter::EncodableValue("totalBytes")] =
        flutter::EncodableValue(total_bytes);
    stats[flutter::EncodableValue("expiredEntries")] =
        flutter::EncodableValue(expired_count);
    stats[flutter::EncodableValue("pinnedEntries")] =
        flutter::EncodableValue(pinned_count);
    stats[flutter::EncodableValue("maxDiskCacheBytes")] =
        flutter::EncodableValue(max_disk_cache_bytes_);
    stats[flutter::EncodableValue("cacheDirectoryPath")] =
        flutter::EncodableValue(GetCacheRootDir());
    stats[flutter::EncodableValue("hitCount")] =
        flutter::EncodableValue(hit_count_);
    stats[flutter::EncodableValue("missCount")] =
        flutter::EncodableValue(miss_count_);
    stats[flutter::EncodableValue("evictionCount")] =
        flutter::EncodableValue(eviction_count_);
    stats[flutter::EncodableValue("bytesByTag")] =
        flutter::EncodableValue(bytes_by_tag);
    result->Success(flutter::EncodableValue(stats));
  } else if (method == "getCapabilities") {
    flutter::EncodableMap caps;
    caps[flutter::EncodableValue("platformName")] =
        flutter::EncodableValue("windows");
    caps[flutter::EncodableValue("supportsFileSystemPaths")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsConditionalHttpRevalidation")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsNativeCryptoHash")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsLowDiskSpaceNotifications")] =
        flutter::EncodableValue(false);
    caps[flutter::EncodableValue("storageMechanism")] =
        flutter::EncodableValue("LOCALAPPDATA/Temp + WinHTTP + Windows BCrypt");
    caps[flutter::EncodableValue("defaultCacheRootPath")] =
        flutter::EncodableValue(GetCacheRootDir());
    result->Success(flutter::EncodableValue(caps));
  } else {
    result->NotImplemented();
  }
}

}  // namespace xue_hua_navite_cache_manager
