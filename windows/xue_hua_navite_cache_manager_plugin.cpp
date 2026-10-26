#include "xue_hua_navite_cache_manager_plugin.h"

#include <windows.h>
#include <objbase.h>
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

// Private message for the platform-thread dispatcher window. The Flutter
// runner pumps every HWND on the platform thread (GetMessage hwnd == nullptr),
// which is the thread shell.cc checks before an EventChannel send.
constexpr UINT kPlatformTaskMessage = WM_APP + 0x351;

// 600ms matches the index-flush contract documented for the 10k entry engine.
constexpr int64_t kIndexFlushDebounceMs = 600;

// Uses PluginRegistrarWindows::PostPlatformThreadTask when this Flutter SDK
// exposes it (master after 2026-10-22). Flutter 3.47 through 3.50.0-0.2.pre
// do not, and the trailing-return SFINAE falls through to the message window.
template <typename Registrar>
auto PostWithRegistrar(Registrar* registrar, std::function<void()>& task, int)
    -> decltype(registrar->PostPlatformThreadTask(task), bool()) {
  registrar->PostPlatformThreadTask(std::move(task));
  return true;
}

template <typename Registrar>
bool PostWithRegistrar(Registrar*, std::function<void()>&, long) {
  return false;
}

LRESULT CALLBACK PlatformThreadWndProc(HWND hwnd,
                                       UINT message,
                                       WPARAM wparam,
                                       LPARAM lparam) {
  if (message == kPlatformTaskMessage) {
    std::unique_ptr<std::function<void()>> task(
        reinterpret_cast<std::function<void()>*>(lparam));
    if (task && *task) {
      try {
        (*task)();
      } catch (...) {
      }
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

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

  auto plugin = std::make_unique<XueHuaNaviteCacheManagerPlugin>(registrar);
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

struct XueHuaNaviteCacheManagerPlugin::EventDispatchState {
  std::mutex mu;
  bool alive = true;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink;
};

XueHuaNaviteCacheManagerPlugin::XueHuaNaviteCacheManagerPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      event_state_(std::make_shared<EventDispatchState>()) {
  StartPlatformDispatcher();
  persist_thread_ = std::thread([this]() { IndexFlushLoop(); });
  EnsureDownloadWorkers(max_concurrent_downloads_);
}

XueHuaNaviteCacheManagerPlugin::~XueHuaNaviteCacheManagerPlugin() {
  {
    std::lock_guard<std::mutex> lock(pool_mutex_);
    pool_stopping_ = true;
  }
  pool_cv_.notify_all();
  for (auto& worker : download_workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }
  {
    std::lock_guard<std::mutex> lock(persist_mutex_);
    persist_stopping_ = true;
    persist_scheduled_ = true;
    persist_deadline_ = std::chrono::steady_clock::now();
  }
  persist_cv_.notify_all();
  if (persist_thread_.joinable()) {
    persist_thread_.join();
  }
  // Run callbacks already queued on the message window while the messenger
  // still exists, then retire the sink. Tasks posted through the registrar
  // capture their own EventDispatchState share and no-op once alive is false.
  StopPlatformDispatcher();
  if (auto dispatch = CopyEventState()) {
    std::lock_guard<std::mutex> lock(dispatch->mu);
    dispatch->alive = false;
    dispatch->sink.reset();
  }
}

std::shared_ptr<XueHuaNaviteCacheManagerPlugin::EventDispatchState>
XueHuaNaviteCacheManagerPlugin::CopyEventState() const {
  std::lock_guard<std::mutex> lock(event_state_mu_);
  return event_state_;
}

void XueHuaNaviteCacheManagerPlugin::StartPlatformDispatcher() {
  HINSTANCE instance = GetModuleHandleW(nullptr);
  const wchar_t* class_name = L"XueHuaNaviteCacheManager.PlatformThread";
  WNDCLASSW existing = {};
  if (!GetClassInfoW(instance, class_name, &existing)) {
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = PlatformThreadWndProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    RegisterClassW(&window_class);
  }
  platform_hwnd_ = CreateWindowExW(0, class_name, L"", 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, nullptr, instance, nullptr);
}

void XueHuaNaviteCacheManagerPlugin::StopPlatformDispatcher() {
  HWND hwnd = static_cast<HWND>(platform_hwnd_);
  if (!hwnd) return;
  MSG msg;
  while (PeekMessageW(&msg, hwnd, kPlatformTaskMessage, kPlatformTaskMessage,
                      PM_REMOVE)) {
    std::unique_ptr<std::function<void()>> task(
        reinterpret_cast<std::function<void()>*>(msg.lParam));
    if (task && *task) {
      try {
        (*task)();
      } catch (...) {
      }
    }
  }
  DestroyWindow(hwnd);
  platform_hwnd_ = nullptr;
}

void XueHuaNaviteCacheManagerPlugin::PostToPlatformThread(
    std::function<void()> task) {
  if (!task) return;
  // Official engine queue when the SDK has it. 3.50 beta does not, so the
  // message-only window below is what actually fixes the driver failure.
  if (registrar_ != nullptr && PostWithRegistrar(registrar_, task, 0)) {
    return;
  }
  HWND hwnd = static_cast<HWND>(platform_hwnd_);
  if (!hwnd) {
    return;
  }
  auto* heap_task = new std::function<void()>(std::move(task));
  if (!PostMessageW(hwnd, kPlatformTaskMessage, 0,
                    reinterpret_cast<LPARAM>(heap_task))) {
    delete heap_task;
  }
}

void XueHuaNaviteCacheManagerPlugin::ScheduleIndexFlush() {
  index_dirty_.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(persist_mutex_);
    persist_deadline_ = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kIndexFlushDebounceMs);
    persist_scheduled_ = true;
  }
  persist_cv_.notify_one();
}

void XueHuaNaviteCacheManagerPlugin::IndexFlushLoop() {
  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_ready = SUCCEEDED(com_hr);
  std::unique_lock<std::mutex> lock(persist_mutex_);
  while (!persist_stopping_) {
    if (!persist_scheduled_) {
      persist_cv_.wait(lock, [this]() {
        return persist_stopping_ || persist_scheduled_;
      });
      continue;
    }
    const auto deadline = persist_deadline_;
    persist_cv_.wait_until(lock, deadline, [this, deadline]() {
      return persist_stopping_ || persist_deadline_ != deadline;
    });
    if (persist_stopping_) break;
    if (std::chrono::steady_clock::now() < persist_deadline_) {
      continue;
    }
    persist_scheduled_ = false;
    lock.unlock();
    FlushIndexSnapshot();
    lock.lock();
  }
  lock.unlock();
  FlushIndexSnapshot();
  if (com_ready) {
    CoUninitialize();
  }
}

void XueHuaNaviteCacheManagerPlugin::FlushIndexSnapshot() {
  struct Snapshot {
    std::string path;
    int64_t hit = 0;
    int64_t miss = 0;
    int64_t eviction = 0;
    std::vector<CacheRecord> entries;
  } snap;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!index_dirty_.exchange(false, std::memory_order_acq_rel)) {
      return;
    }
    snap.path = GetIndexFilePath();
    snap.hit = hit_count_;
    snap.miss = miss_count_;
    snap.eviction = eviction_count_;
    snap.entries.reserve(entries_.size());
    for (const auto& kv : entries_) {
      snap.entries.push_back(kv.second);
    }
  }
  if (snap.path.empty()) {
    index_dirty_.store(true, std::memory_order_release);
    return;
  }
  const std::string tmp_path = snap.path + ".tmp";
  bool wrote = false;
  {
    std::ofstream out(fs::u8path(tmp_path), std::ios::trunc);
    if (out.is_open()) {
      out << snap.hit << " " << snap.miss << " " << snap.eviction << "\n";
      for (const auto& r : snap.entries) {
        out << r.key << "\t" << r.url << "\t" << r.file_path << "\t"
            << r.size_bytes << "\t" << r.created_at_ms << "\t"
            << r.last_accessed_at_ms << "\t" << r.expires_at_ms << "\t"
            << r.hit_count << "\t" << r.tag << "\t" << r.mime_type << "\t"
            << r.etag << "\t" << r.last_modified << "\t" << r.checksum << "\t"
            << r.checksum_algorithm << "\t" << (r.pinned ? "1" : "0") << "\n";
      }
      wrote = static_cast<bool>(out);
    }
  }
  const std::wstring tmp_wide = Utf8ToWide(tmp_path);
  if (!wrote) {
    DeleteFileW(tmp_wide.c_str());
    index_dirty_.store(true, std::memory_order_release);
    return;
  }
  const std::wstring dest_wide = Utf8ToWide(snap.path);
  if (!MoveFileExW(tmp_wide.c_str(), dest_wide.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(tmp_wide.c_str());
    index_dirty_.store(true, std::memory_order_release);
  }
}

void XueHuaNaviteCacheManagerPlugin::SetEventSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  auto dispatch = CopyEventState();
  if (!dispatch) return;
  std::lock_guard<std::mutex> lock(dispatch->mu);
  dispatch->sink = std::move(sink);
}

void XueHuaNaviteCacheManagerPlugin::EmitProgress(
    const std::string& key,
    const std::string& url,
    const std::string& state,
    int64_t bytes_received,
    int64_t total_bytes,
    const std::string& file_path,
    const std::string& error_message) {
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
  auto dispatch = CopyEventState();
  PostToPlatformThread([dispatch, payload = std::move(payload)]() {
    if (!dispatch) return;
    std::lock_guard<std::mutex> lock(dispatch->mu);
    if (!dispatch->alive || !dispatch->sink) return;
    dispatch->sink->Success(flutter::EncodableValue(payload));
  });
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
  // Memory is already updated by the caller. Disk IO is coalesced off the
  // platform thread so a 10k putBytes loop does not rewrite the whole index
  // on every call. The same TSV format is preserved.
  ScheduleIndexFlush();
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
    std::string* out_error_msg,
    const std::shared_ptr<std::atomic<bool>>& external_cancel) {
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

  std::shared_ptr<std::atomic<bool>> cancel_flag =
      external_cancel ? external_cancel
                      : std::make_shared<std::atomic<bool>>(false);
  const bool owns_cancel = static_cast<bool>(!external_cancel);
  struct CancelGuard {
    XueHuaNaviteCacheManagerPlugin* plugin;
    std::string guarded_key;
    bool own = false;
    ~CancelGuard() {
      if (!own || plugin == nullptr) return;
      std::lock_guard<std::mutex> lock(plugin->mutex_);
      plugin->active_cancels_.erase(guarded_key);
    }
  } cancel_guard{this, key, false};
  if (owns_cancel) {
    std::lock_guard<std::mutex> lock(mutex_);
    active_cancels_[key] = cancel_flag;
    cancel_guard.own = true;
  }
  if (cancel_flag->load()) {
    *out_error_code = "CANCELED";
    *out_error_msg = "Download canceled";
    EmitProgress(key, url, "canceled", 0, -1, "", "Download canceled");
    return false;
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
  int64_t last_progress_emit_ms = 0;
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
      // Match Android: at most one in-progress event per 50ms so gallery
      // downloads cannot saturate the platform thread.
      const int64_t now_ms = CurrentTimeMs();
      if (last_progress_emit_ms == 0 || now_ms - last_progress_emit_ms >= 50) {
        last_progress_emit_ms = now_ms;
        EmitProgress(key, url, "inProgress",
                     static_cast<int64_t>(buffer.size()), -1);
      }
    } else {
      break;
    }
  } while (dwDownloaded > 0);

  WinHttpCloseHandle(hRequest);
  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);

  {
    std::lock_guard<std::mutex> lock(mutex_);
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

bool XueHuaNaviteCacheManagerPlugin::TryServeFreshCacheLocked(
    const std::string& key,
    const std::string& url,
    const std::string& tag,
    bool pinned,
    int64_t start_ms,
    flutter::EncodableMap* out_result) {
  auto it = entries_.find(key);
  std::error_code ec;
  if (it == entries_.end() ||
      !fs::exists(fs::u8path(it->second.file_path), ec) ||
      it->second.IsExpired(start_ms)) {
    return false;
  }
  it->second.last_accessed_at_ms = start_ms;
  it->second.hit_count += 1;
  if (!tag.empty()) it->second.tag = tag;
  if (pinned) it->second.pinned = true;
  hit_count_++;
  PersistIndexLocked();
  EmitProgress(key, url, "cacheHit", it->second.size_bytes, it->second.size_bytes,
               it->second.file_path);
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

void XueHuaNaviteCacheManagerPlugin::FinishInFlight(
    const std::string& key,
    const std::shared_ptr<InFlightDownload>& state,
    const DownloadOutcome& outcome) {
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = in_flight_.find(key);
    if (it != in_flight_.end() && it->second == state) {
      waiters.swap(it->second->waiters);
      in_flight_.erase(it);
    } else if (state) {
      waiters.swap(state->waiters);
    }
    auto cancel = active_cancels_.find(key);
    if (cancel != active_cancels_.end() && state &&
        cancel->second == state->cancel_flag) {
      active_cancels_.erase(cancel);
    }
  }
  for (const auto& waiter : waiters) {
    waiter(outcome);
  }
}

void XueHuaNaviteCacheManagerPlugin::EnsureDownloadWorkers(int workers) {
  if (workers < 1) workers = 1;
  std::lock_guard<std::mutex> lock(pool_mutex_);
  max_concurrent_downloads_ = workers;
  while (static_cast<int>(download_workers_.size()) < workers) {
    download_workers_.emplace_back([this]() { DownloadWorkerLoop(); });
  }
  pool_cv_.notify_all();
}

void XueHuaNaviteCacheManagerPlugin::DownloadWorkerLoop() {
  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_ready = SUCCEEDED(com_hr);
  for (;;) {
    std::function<void()> job;
    {
      std::unique_lock<std::mutex> lock(pool_mutex_);
      pool_cv_.wait(lock, [this]() {
        return (pool_stopping_ && download_jobs_.empty()) ||
               (!download_jobs_.empty() &&
                active_download_slots_ < max_concurrent_downloads_);
      });
      if (download_jobs_.empty()) {
        break;
      }
      job = std::move(download_jobs_.front());
      download_jobs_.pop();
      active_download_slots_ += 1;
    }
    try {
      job();
    } catch (...) {
    }
    {
      std::lock_guard<std::mutex> lock(pool_mutex_);
      active_download_slots_ -= 1;
    }
    pool_cv_.notify_all();
  }
  if (com_ready) {
    CoUninitialize();
  }
}

void XueHuaNaviteCacheManagerPlugin::PostDownloadJob(std::function<void()> job) {
  {
    std::lock_guard<std::mutex> lock(pool_mutex_);
    if (pool_stopping_) return;
    download_jobs_.push(std::move(job));
  }
  pool_cv_.notify_one();
}

void XueHuaNaviteCacheManagerPlugin::ScheduleDownload(
    const flutter::EncodableMap& args,
    const std::function<void(const DownloadOutcome&)>& callback) {
  const int64_t start_ms = CurrentTimeMs();
  const std::string url = GetStringArg(args, "url");
  if (url.empty()) {
    DownloadOutcome outcome;
    outcome.ok = false;
    outcome.error_code = "INVALID_URL";
    outcome.error_msg = "URL is required";
    callback(outcome);
    return;
  }
  const std::string custom_key = GetStringArg(args, "customKey");
  const std::string tag = GetStringArg(args, "tag");
  const bool force_refresh = GetBoolArg(args, "forceRefresh", false);
  const bool pinned = GetBoolArg(args, "pinned", false);
  const std::string key = ResolveKey(url, custom_key);

  DownloadOutcome early;
  bool has_early = false;
  std::shared_ptr<InFlightDownload> state;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!force_refresh) {
      flutter::EncodableMap cached;
      if (TryServeFreshCacheLocked(key, url, tag, pinned, start_ms, &cached)) {
        early.ok = true;
        early.result = std::move(cached);
        has_early = true;
      }
    }
    if (!has_early) {
      auto existing = in_flight_.find(key);
      if (existing != in_flight_.end()) {
        existing->second->waiters.push_back(callback);
        return;
      }
      state = std::make_shared<InFlightDownload>();
      state->cancel_flag = std::make_shared<std::atomic<bool>>(false);
      state->waiters.push_back(callback);
      in_flight_[key] = state;
      active_cancels_[key] = state->cancel_flag;
    }
  }
  if (has_early) {
    callback(early);
    return;
  }

  PostDownloadJob([this, args, key, state]() {
    DownloadOutcome outcome;
    try {
      if (state->cancel_flag->load()) {
        outcome.ok = false;
        outcome.error_code = "CANCELED";
        outcome.error_msg = "Download canceled";
        EmitProgress(key, GetStringArg(args, "url"), "canceled", 0, -1, "",
                     "Download canceled");
      } else {
        std::string err_code;
        std::string err_msg;
        flutter::EncodableMap out;
        outcome.ok = ExecuteDownloadLockedOrUnlocked(
            args, &out, &err_code, &err_msg, state->cancel_flag);
        outcome.result = std::move(out);
        outcome.error_code = std::move(err_code);
        outcome.error_msg = std::move(err_msg);
      }
    } catch (const std::exception& ex) {
      outcome.ok = false;
      outcome.error_code = "DOWNLOAD_FAILED";
      outcome.error_msg = ex.what();
    } catch (...) {
      outcome.ok = false;
      outcome.error_code = "DOWNLOAD_FAILED";
      outcome.error_msg = "Download failed";
    }
    FinishInFlight(key, state, outcome);
  });
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
    if (HasArg(args, "maxConcurrentDownloads")) {
      int conc = static_cast<int>(GetInt64Arg(args, "maxConcurrentDownloads", 4));
      if (conc < 1) conc = 1;
      EnsureDownloadWorkers(conc);
    }
    result->Success();
  } else if (method == "downloadFile") {
    auto shared_result =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            std::move(result));
    ScheduleDownload(args, [this, shared_result](const DownloadOutcome& outcome) {
      PostToPlatformThread([shared_result, outcome]() {
        if (outcome.ok) {
          shared_result->Success(flutter::EncodableValue(outcome.result));
        } else {
          shared_result->Error(outcome.error_code, outcome.error_msg);
        }
      });
    });
  } else if (method == "prefetchAll") {
    auto shared_result =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            std::move(result));
    std::vector<flutter::EncodableMap> requests;
    auto it = args.find(flutter::EncodableValue("requests"));
    if (it != args.end() &&
        std::holds_alternative<flutter::EncodableList>(it->second)) {
      const auto& reqs = std::get<flutter::EncodableList>(it->second);
      for (const auto& item : reqs) {
        if (std::holds_alternative<flutter::EncodableMap>(item)) {
          requests.push_back(std::get<flutter::EncodableMap>(item));
        }
      }
    }
    if (requests.empty()) {
      shared_result->Success(flutter::EncodableValue(flutter::EncodableList()));
    } else {
      struct PrefetchState {
        std::mutex mu;
        int remaining = 0;
        std::vector<std::pair<bool, flutter::EncodableValue>> slots;
      };
      auto prefetch_state = std::make_shared<PrefetchState>();
      prefetch_state->remaining = static_cast<int>(requests.size());
      prefetch_state->slots.resize(requests.size());
      for (size_t index = 0; index < requests.size(); ++index) {
        ScheduleDownload(
            requests[index],
            [this, shared_result, prefetch_state, index](const DownloadOutcome& outcome) {
              flutter::EncodableList list_out;
              bool done = false;
              {
                std::lock_guard<std::mutex> lock(prefetch_state->mu);
                if (outcome.ok) {
                  auto entry = outcome.result.find(flutter::EncodableValue("entry"));
                  if (entry != outcome.result.end()) {
                    prefetch_state->slots[index] = std::make_pair(true, entry->second);
                  }
                }
                prefetch_state->remaining -= 1;
                if (prefetch_state->remaining == 0) {
                  done = true;
                  for (const auto& slot : prefetch_state->slots) {
                    if (slot.first) {
                      list_out.push_back(slot.second);
                    }
                  }
                }
              }
              if (done) {
                PostToPlatformThread(
                    [shared_result, list_out = std::move(list_out)]() {
                      shared_result->Success(flutter::EncodableValue(list_out));
                    });
              }
            });
      }
    }
  } else if (method == "cancelDownload") {
    // Match Linux/Apple/Android: custom keys that are not yet in the index must
    // still cancel by the raw keyOrUrl (ResolveKey alone would SHA-256 them).
    std::string key_or_url = GetStringArg(args, "keyOrUrl");
    std::string key = ResolveKey(key_or_url);
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = active_cancels_.find(key);
    if (it == active_cancels_.end()) {
      it = active_cancels_.find(key_or_url);
    }
    if (it == active_cancels_.end()) {
      auto flight = in_flight_.find(key);
      if (flight == in_flight_.end()) {
        flight = in_flight_.find(key_or_url);
      }
      if (flight != in_flight_.end() && flight->second &&
          flight->second->cancel_flag) {
        flight->second->cancel_flag->store(true);
        result->Success(flutter::EncodableValue(true));
        return;
      }
      result->Success(flutter::EncodableValue(false));
    } else {
      it->second->store(true);
      result->Success(flutter::EncodableValue(true));
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
