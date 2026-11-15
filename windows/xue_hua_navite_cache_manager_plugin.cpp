#include "xue_hua_navite_cache_manager_plugin.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <objbase.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <shlobj.h>

#include <flutter/plugin_registrar_windows.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <thread>
#include <utility>

namespace fs = std::filesystem;

namespace xue_hua_navite_cache_manager {

namespace {

// Private message for the platform-thread dispatcher window. The Flutter
// runner pumps every HWND on the platform thread (GetMessage hwnd == nullptr).
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
  int size_needed = MultiByteToWideChar(
      CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      &out[0], size_needed);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                                        static_cast<int>(wstr.size()), nullptr,
                                        0, nullptr, nullptr);
  if (size_needed <= 0) return std::string();
  std::string out(static_cast<size_t>(size_needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                      &out[0], size_needed, nullptr, nullptr);
  return out;
}

std::string AsciiLower(const std::string& input) {
  std::string out = input;
  for (char& ch : out) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return out;
}

std::string TrimAscii(const std::string& input) {
  size_t begin = 0;
  while (begin < input.size() &&
         std::isspace(static_cast<unsigned char>(input[begin]))) {
    begin++;
  }
  size_t end = input.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(input[end - 1]))) {
    end--;
  }
  return input.substr(begin, end - begin);
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

std::string ComputeBCryptHash(const uint8_t* data,
                              size_t length,
                              const std::string& algorithm) {
  const std::string alg_lower = AsciiLower(algorithm);
  LPCWSTR alg_id = (alg_lower == "md5") ? BCRYPT_MD5_ALGORITHM
                                        : BCRYPT_SHA256_ALGORITHM;
  BCRYPT_ALG_HANDLE hAlg = nullptr;
  BCRYPT_HASH_HANDLE hHash = nullptr;
  DWORD cbData = 0;
  DWORD cbHash = 0;
  DWORD cbHashObject = 0;

  if (BCryptOpenAlgorithmProvider(&hAlg, alg_id, nullptr, 0) != 0) {
    return "";
  }
  if (BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PBYTE>(&cbHashObject), sizeof(DWORD),
                        &cbData, 0) != 0 ||
      BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH,
                        reinterpret_cast<PBYTE>(&cbHash), sizeof(DWORD),
                        &cbData, 0) != 0) {
    BCryptCloseAlgorithmProvider(hAlg, 0);
    return "";
  }

  std::vector<uint8_t> hashObject(cbHashObject);
  std::vector<uint8_t> hashBytes(cbHash);

  bool ok = false;
  if (BCryptCreateHash(hAlg, &hHash, hashObject.data(), cbHashObject, nullptr,
                       0, 0) == 0) {
    PUCHAR input_ptr =
        (length > 0 && data != nullptr) ? const_cast<PUCHAR>(data) : nullptr;
    if (BCryptHashData(hHash, input_ptr, static_cast<ULONG>(length), 0) == 0 &&
        BCryptFinishHash(hHash, hashBytes.data(), cbHash, 0) == 0) {
      ok = true;
    }
    BCryptDestroyHash(hHash);
  }
  BCryptCloseAlgorithmProvider(hAlg, 0);

  if (!ok) {
    return "";
  }

  std::ostringstream oss;
  for (uint8_t b : hashBytes) {
    oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
  }
  return oss.str();
}

std::string ChecksumAlgToString(WireCacheChecksumAlgorithm alg) {
  switch (alg) {
    case WireCacheChecksumAlgorithm::kMd5:
      return "md5";
    case WireCacheChecksumAlgorithm::kSha256:
      return "sha256";
    case WireCacheChecksumAlgorithm::kNone:
    default:
      return "none";
  }
}

WireCacheChecksumAlgorithm WireChecksumFromString(const std::string& raw) {
  const std::string lower = AsciiLower(raw);
  if (lower == "md5") return WireCacheChecksumAlgorithm::kMd5;
  if (lower == "sha256") return WireCacheChecksumAlgorithm::kSha256;
  return WireCacheChecksumAlgorithm::kNone;
}

std::string EvictionPolicyToString(WireCacheEvictionPolicy policy) {
  switch (policy) {
    case WireCacheEvictionPolicy::kLfu:
      return "lfu";
    case WireCacheEvictionPolicy::kFifo:
      return "fifo";
    case WireCacheEvictionPolicy::kTtlOnly:
      return "ttlOnly";
    case WireCacheEvictionPolicy::kLru:
    default:
      return "lru";
  }
}

std::string InferExtension(const std::string& url,
                           const std::string& mime_type,
                           const std::string& explicit_ext) {
  std::string trimmed_ext = TrimAscii(explicit_ext);
  while (!trimmed_ext.empty() && trimmed_ext.front() == '.') {
    trimmed_ext.erase(trimmed_ext.begin());
  }
  if (!trimmed_ext.empty()) {
    return AsciiLower(trimmed_ext);
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
  auto semi_pos = clean_mime.find(';');
  if (semi_pos != std::string::npos) {
    clean_mime = clean_mime.substr(0, semi_pos);
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

std::wstring QueryWinHttpHeader(HINTERNET hRequest, DWORD info_level) {
  DWORD dwSize = 0;
  WinHttpQueryHeaders(hRequest, info_level, WINHTTP_HEADER_NAME_BY_INDEX,
                      nullptr, &dwSize, WINHTTP_NO_HEADER_INDEX);
  if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && dwSize > 0) {
    std::wstring buffer(dwSize / sizeof(wchar_t), L'\0');
    if (WinHttpQueryHeaders(hRequest, info_level, WINHTTP_HEADER_NAME_BY_INDEX,
                            &buffer[0], &dwSize, WINHTTP_NO_HEADER_INDEX)) {
      while (!buffer.empty() && buffer.back() == L'\0') {
        buffer.pop_back();
      }
      return buffer;
    }
  }
  return L"";
}

int64_t QueryContentLength(HINTERNET hRequest) {
  const std::string raw =
      TrimAscii(WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_CONTENT_LENGTH)));
  if (raw.empty()) return -1;
  char* end_ptr = nullptr;
  const long long parsed = std::strtoll(raw.c_str(), &end_ptr, 10);
  if (end_ptr == raw.c_str() || parsed <= 0) {
    return -1;
  }
  return static_cast<int64_t>(parsed);
}

std::map<std::string, std::string> ExtractStringMap(
    const ::flutter::EncodableMap& encodable) {
  std::map<std::string, std::string> out;
  for (const auto& kv : encodable) {
    if (std::holds_alternative<std::string>(kv.first) &&
        std::holds_alternative<std::string>(kv.second)) {
      out[std::get<std::string>(kv.first)] = std::get<std::string>(kv.second);
    }
  }
  return out;
}

std::vector<WireCacheRequest> UnpackPrefetchRequests(
    const ::flutter::EncodableList& requests) {
  std::vector<WireCacheRequest> out;
  out.reserve(requests.size());
  for (const auto& item : requests) {
    if (const auto* custom =
            std::get_if<::flutter::CustomEncodableValue>(&item)) {
      if (custom->type() == typeid(WireCacheRequest)) {
        out.push_back(std::any_cast<const WireCacheRequest&>(*custom));
      }
    }
  }
  return out;
}

}  // namespace

struct XueHuaNaviteCacheManagerPlugin::EventDispatchState {
  std::mutex mu;
  bool alive = true;
  std::shared_ptr<CacheProgressFlutterApi> flutter_api;
};

WireCacheEntry CacheRecord::ToWireEntry() const {
  return WireCacheEntry(
      key, url, file_path, size_bytes, created_at_ms, last_accessed_at_ms,
      expires_at_ms, hit_count, tag.empty() ? nullptr : &tag,
      mime_type.empty() ? nullptr : &mime_type, etag.empty() ? nullptr : &etag,
      last_modified.empty() ? nullptr : &last_modified,
      checksum.empty() ? nullptr : &checksum,
      WireChecksumFromString(checksum_algorithm), pinned);
}

// static
void XueHuaNaviteCacheManagerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<XueHuaNaviteCacheManagerPlugin>(registrar);
  CacheHostApi::SetUp(registrar->messenger(), plugin.get());
  registrar->AddPlugin(std::move(plugin));
}

XueHuaNaviteCacheManagerPlugin::XueHuaNaviteCacheManagerPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      event_state_(std::make_shared<EventDispatchState>()) {
  if (registrar_ != nullptr) {
    event_state_->flutter_api =
        std::make_shared<CacheProgressFlutterApi>(registrar_->messenger());
  }
  StartPlatformDispatcher();
  persist_thread_ = std::thread([this]() { IndexFlushLoop(); });
  EnsureIoWorkers(4);
  EnsureDownloadWorkers(max_concurrent_downloads_);
}

XueHuaNaviteCacheManagerPlugin::~XueHuaNaviteCacheManagerPlugin() {
  {
    std::lock_guard<std::mutex> lock(io_pool_mutex_);
    io_pool_stopping_ = true;
  }
  io_pool_cv_.notify_all();
  for (auto& worker : io_workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }

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

  // Drain any tasks already queued on the message window while the messenger is
  // still valid, then mark the dispatch state dead so late registrar-queued
  // tasks become no-ops.
  StopPlatformDispatcher();
  if (auto dispatch = CopyEventState()) {
    std::lock_guard<std::mutex> lock(dispatch->mu);
    dispatch->alive = false;
    dispatch->flutter_api.reset();
  }
  if (registrar_ != nullptr) {
    CacheHostApi::SetUp(registrar_->messenger(), nullptr);
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

void XueHuaNaviteCacheManagerPlugin::EnsureIoWorkers(int workers) {
  if (workers < 1) workers = 1;
  std::lock_guard<std::mutex> lock(io_pool_mutex_);
  while (static_cast<int>(io_workers_.size()) < workers) {
    io_workers_.emplace_back([this]() { IoWorkerLoop(); });
  }
}

void XueHuaNaviteCacheManagerPlugin::IoWorkerLoop() {
  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_ready = SUCCEEDED(com_hr);
  for (;;) {
    std::function<void()> job;
    {
      std::unique_lock<std::mutex> lock(io_pool_mutex_);
      io_pool_cv_.wait(lock, [this]() {
        return io_pool_stopping_ || !io_jobs_.empty();
      });
      if (io_jobs_.empty()) {
        break;
      }
      job = std::move(io_jobs_.front());
      io_jobs_.pop();
    }
    try {
      job();
    } catch (...) {
    }
  }
  if (com_ready) {
    CoUninitialize();
  }
}

void XueHuaNaviteCacheManagerPlugin::PostIoJob(std::function<void()> job) {
  if (!job) return;
  {
    std::lock_guard<std::mutex> lock(io_pool_mutex_);
    if (io_pool_stopping_) return;
    io_jobs_.push(std::move(job));
  }
  io_pool_cv_.notify_one();
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
        return pool_stopping_ ||
               (!download_jobs_.empty() &&
                active_download_slots_ < std::max(1, max_concurrent_downloads_));
      });
      if (pool_stopping_ || download_jobs_.empty()) {
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
  if (!job) return;
  {
    std::lock_guard<std::mutex> lock(pool_mutex_);
    if (pool_stopping_) return;
    download_jobs_.push(std::move(job));
  }
  pool_cv_.notify_one();
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

void XueHuaNaviteCacheManagerPlugin::FlushIndexSnapshot(
    const std::string& override_subdir) {
  if (!index_dirty_.load(std::memory_order_acquire)) {
    return;
  }

  std::string target_subdir = override_subdir;
  if (target_subdir.empty()) {
    std::lock_guard<std::mutex> lock(config_mutex_);
    target_subdir = cache_subdirectory_;
  }
  const std::string root_dir = ResolveCacheRootPath(target_subdir);
  const fs::path root_path(Utf8ToWide(root_dir));
  const fs::path index_fs_path = root_path / L"cache_index_v1.tsv";
  const std::string index_path = WideToUtf8(index_fs_path.wstring());

  struct Snapshot {
    int64_t hit = 0;
    int64_t miss = 0;
    int64_t eviction = 0;
    std::vector<CacheRecord> entries;
  } snap;
  {
    std::lock_guard<std::mutex> lock(index_mutex_);
    if (!index_dirty_.exchange(false, std::memory_order_acq_rel)) {
      return;
    }
    snap.hit = hit_count_;
    snap.miss = miss_count_;
    snap.eviction = eviction_count_;
    snap.entries.reserve(entries_.size());
    for (const auto& kv : entries_) {
      snap.entries.push_back(kv.second);
    }
  }
  if (index_path.empty()) {
    index_dirty_.store(true, std::memory_order_release);
    return;
  }

  std::error_code ec;
  fs::create_directories(root_path, ec);

  const std::string tmp_path = index_path + ".tmp";
  const std::wstring tmp_wide = Utf8ToWide(tmp_path);
  bool wrote = false;
  {
    std::ofstream out(fs::path(tmp_wide), std::ios::trunc);
    if (out.is_open()) {
      out << snap.hit << " " << snap.miss << " " << snap.eviction << "\n";
      for (const auto& r : snap.entries) {
        out << SanitizeTsvField(r.key) << "\t"
            << SanitizeTsvField(r.url) << "\t"
            << SanitizeTsvField(r.file_path) << "\t"
            << r.size_bytes << "\t" << r.created_at_ms << "\t"
            << r.last_accessed_at_ms << "\t" << r.expires_at_ms << "\t"
            << r.hit_count << "\t"
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
  if (!wrote) {
    DeleteFileW(tmp_wide.c_str());
    index_dirty_.store(true, std::memory_order_release);
    return;
  }
  const std::wstring dest_wide = Utf8ToWide(index_path);
  if (!MoveFileExW(tmp_wide.c_str(), dest_wide.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(tmp_wide.c_str());
    index_dirty_.store(true, std::memory_order_release);
  }
}

void XueHuaNaviteCacheManagerPlugin::EmitProgress(
    const std::string& key,
    const std::string& url,
    WireCacheTransferState state,
    int64_t bytes_received,
    int64_t total_bytes,
    const std::string& file_path,
    const std::string& error_message) {
  WireCacheProgressEvent event(
      key, url, state, bytes_received, total_bytes,
      file_path.empty() ? nullptr : &file_path,
      error_message.empty() ? nullptr : &error_message);
  auto dispatch = CopyEventState();
  PostToPlatformThread([dispatch, event = std::move(event)]() {
    if (!dispatch) return;
    std::shared_ptr<CacheProgressFlutterApi> api;
    {
      std::lock_guard<std::mutex> lock(dispatch->mu);
      if (!dispatch->alive || !dispatch->flutter_api) return;
      api = dispatch->flutter_api;
    }
    api->OnProgress(event, []() {}, [](const FlutterError&) {});
  });
}

std::string XueHuaNaviteCacheManagerPlugin::ResolveCacheRootPath(
    const std::string& subdirectory) const {
  PWSTR path_tmp = nullptr;
  fs::path base_path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                     &path_tmp))) {
    base_path = fs::path(path_tmp) / L"Temp" / fs::path(Utf8ToWide(subdirectory));
    CoTaskMemFree(path_tmp);
  } else {
    std::error_code ec;
    base_path = fs::temp_directory_path(ec) / fs::path(Utf8ToWide(subdirectory));
  }
  return WideToUtf8(base_path.wstring());
}

std::string XueHuaNaviteCacheManagerPlugin::GetCacheRootDir(
    bool create_if_missing) const {
  std::string subdir;
  {
    std::lock_guard<std::mutex> lock(config_mutex_);
    subdir = cache_subdirectory_;
  }
  const std::string root = ResolveCacheRootPath(subdir);
  if (create_if_missing && !root.empty()) {
    std::error_code ec;
    fs::create_directories(fs::path(Utf8ToWide(root)), ec);
  }
  return root;
}

std::string XueHuaNaviteCacheManagerPlugin::GetIndexFilePath(
    const std::string& subdirectory) const {
  std::string root;
  if (subdirectory.empty()) {
    root = GetCacheRootDir(false);
  } else {
    root = ResolveCacheRootPath(subdirectory);
  }
  fs::path p = fs::path(Utf8ToWide(root)) / L"cache_index_v1.tsv";
  return WideToUtf8(p.wstring());
}

void XueHuaNaviteCacheManagerPlugin::EnsureIndexLoaded() {
  {
    std::lock_guard<std::mutex> lock(index_mutex_);
    if (index_loaded_) return;
  }

  const std::string index_path = GetIndexFilePath();
  std::map<std::string, CacheRecord> loaded_entries;
  int64_t loaded_total_bytes = 0;
  int64_t loaded_hit = 0;
  int64_t loaded_miss = 0;
  int64_t loaded_eviction = 0;

  std::ifstream in(fs::path(Utf8ToWide(index_path)));
  if (in.is_open()) {
    std::string line;
    if (std::getline(in, line)) {
      std::istringstream header_ss(line);
      header_ss >> loaded_hit >> loaded_miss >> loaded_eviction;
    }
    while (std::getline(in, line)) {
      if (line.empty()) continue;
      std::vector<std::string> parts;
      std::stringstream ss(line);
      std::string item;
      while (std::getline(ss, item, '\t')) {
        parts.push_back(item);
      }
      // Preserve trailing empty field if line ends with '\t'.
      if (!line.empty() && line.back() == '\t') {
        parts.emplace_back();
      }
      if (parts.size() >= 15) {
        try {
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
          if (!rec.key.empty() &&
              fs::exists(fs::path(Utf8ToWide(rec.file_path)), ec)) {
            loaded_entries[rec.key] = rec;
            loaded_total_bytes += rec.size_bytes;
          }
        } catch (...) {
        }
      }
    }
  }

  std::lock_guard<std::mutex> lock(index_mutex_);
  if (index_loaded_) return;
  index_loaded_ = true;
  entries_ = std::move(loaded_entries);
  total_cached_bytes_ = loaded_total_bytes;
  hit_count_ = loaded_hit;
  miss_count_ = loaded_miss;
  eviction_count_ = loaded_eviction;
}

void XueHuaNaviteCacheManagerPlugin::PersistIndexLocked() {
  ScheduleIndexFlush();
}

std::string XueHuaNaviteCacheManagerPlugin::ResolveKeyLocked(
    const std::string& key_or_url,
    const std::string& custom_key) const {
  const std::string trimmed_custom = TrimAscii(custom_key);
  if (!trimmed_custom.empty()) return trimmed_custom;
  if (entries_.find(key_or_url) != entries_.end()) {
    return key_or_url;
  }
  return ComputeBCryptHash(reinterpret_cast<const uint8_t*>(key_or_url.data()),
                           key_or_url.size(), "sha256");
}

std::string XueHuaNaviteCacheManagerPlugin::ResolveKey(
    const std::string& key_or_url,
    const std::string& custom_key) {
  const std::string trimmed_custom = TrimAscii(custom_key);
  if (!trimmed_custom.empty()) return trimmed_custom;
  {
    std::lock_guard<std::mutex> lock(index_mutex_);
    if (entries_.find(key_or_url) != entries_.end()) {
      return key_or_url;
    }
  }
  return ComputeBCryptHash(reinterpret_cast<const uint8_t*>(key_or_url.data()),
                           key_or_url.size(), "sha256");
}

int XueHuaNaviteCacheManagerPlugin::RemoveExpiredLocked() {
  const int64_t now = CurrentTimeMs();
  std::vector<std::string> expired_keys;
  for (const auto& kv : entries_) {
    if (!kv.second.pinned && kv.second.IsExpired(now)) {
      expired_keys.push_back(kv.first);
    }
  }
  std::error_code ec;
  for (const auto& k : expired_keys) {
    auto it = entries_.find(k);
    if (it != entries_.end()) {
      fs::remove(fs::path(Utf8ToWide(it->second.file_path)), ec);
      total_cached_bytes_ =
          std::max<int64_t>(0, total_cached_bytes_ - it->second.size_bytes);
      entries_.erase(it);
    }
  }
  eviction_count_ += static_cast<int64_t>(expired_keys.size());
  return static_cast<int>(expired_keys.size());
}

int XueHuaNaviteCacheManagerPlugin::EnforceQuotaLocked(
    int64_t target_max_bytes,
    int max_entries,
    const std::string& eviction_policy,
    const std::string& protected_key) {
  int evicted = RemoveExpiredLocked();
  if (eviction_policy == "ttlOnly") return evicted;

  if (total_cached_bytes_ <= target_max_bytes &&
      static_cast<int>(entries_.size()) <= max_entries) {
    return evicted;
  }

  std::vector<CacheRecord> candidates;
  candidates.reserve(entries_.size());
  for (const auto& kv : entries_) {
    if (!kv.second.pinned && kv.first != protected_key) {
      candidates.push_back(kv.second);
    }
  }

  std::sort(candidates.begin(), candidates.end(),
            [&eviction_policy](const CacheRecord& a, const CacheRecord& b) {
              if (eviction_policy == "lfu") {
                if (a.hit_count != b.hit_count) return a.hit_count < b.hit_count;
                return a.last_accessed_at_ms < b.last_accessed_at_ms;
              }
              if (eviction_policy == "fifo") {
                return a.created_at_ms < b.created_at_ms;
              }
              return a.last_accessed_at_ms < b.last_accessed_at_ms;
            });

  std::error_code ec;
  for (const auto& cand : candidates) {
    if (total_cached_bytes_ <= target_max_bytes &&
        static_cast<int>(entries_.size()) <= max_entries) {
      break;
    }
    auto it = entries_.find(cand.key);
    if (it != entries_.end()) {
      fs::remove(fs::path(Utf8ToWide(it->second.file_path)), ec);
      total_cached_bytes_ =
          std::max<int64_t>(0, total_cached_bytes_ - it->second.size_bytes);
      entries_.erase(it);
      evicted++;
      eviction_count_++;
    }
  }
  return evicted;
}

bool XueHuaNaviteCacheManagerPlugin::TryServeFreshCacheLocked(
    const std::string& key,
    const std::string& tag,
    bool pinned,
    int64_t start_ms,
    WireCacheFetchResult* out_result) {
  auto it = entries_.find(key);
  std::error_code ec;
  if (it == entries_.end() ||
      !fs::exists(fs::path(Utf8ToWide(it->second.file_path)), ec) ||
      it->second.IsExpired(start_ms)) {
    return false;
  }
  it->second.last_accessed_at_ms = start_ms;
  it->second.hit_count += 1;
  if (!tag.empty()) it->second.tag = tag;
  if (pinned) it->second.pinned = true;
  hit_count_++;
  PersistIndexLocked();

  const WireCacheEntry entry_wire = it->second.ToWireEntry();
  *out_result = WireCacheFetchResult(&entry_wire,
                                     WireCacheResultSource::kCacheHit, nullptr,
                                     CurrentTimeMs() - start_ms);
  return true;
}

XueHuaNaviteCacheManagerPlugin::DownloadOutcome
XueHuaNaviteCacheManagerPlugin::ExecuteDownload(
    const WireCacheRequest& request,
    const std::shared_ptr<std::atomic<bool>>& external_cancel) {
  DownloadOutcome outcome;
  const int64_t start_ms = CurrentTimeMs();
  const std::string url = TrimAscii(request.url());
  if (url.empty()) {
    outcome.ok = false;
    outcome.error_code = "INVALID_URL";
    outcome.error_msg = "URL is required";
    return outcome;
  }

  const std::string custom_key =
      request.custom_key() ? *request.custom_key() : "";
  const std::string tag = request.tag() ? *request.tag() : "";
  const std::string file_extension =
      request.file_extension() ? *request.file_extension() : "";
  const bool has_ttl = request.ttl_seconds() != nullptr;
  const int64_t ttl_override = has_ttl ? *request.ttl_seconds() : 0;
  const bool force_refresh = request.force_refresh();
  const bool fallback_on_error = request.fallback_to_cache_on_error();
  const bool pinned = request.pinned();
  const WireCacheChecksumAlgorithm checksum_alg = request.checksum_algorithm();
  const std::string checksum_alg_str = ChecksumAlgToString(checksum_alg);
  const std::string expected_checksum = AsciiLower(
      TrimAscii(request.expected_checksum() ? *request.expected_checksum() : ""));

  int64_t cfg_max_disk_bytes = 500LL * 1024LL * 1024LL;
  int cfg_max_entries = 20000;
  int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
  std::string cfg_eviction_policy = "lru";
  int cfg_connect_timeout_ms = 15000;
  int cfg_read_timeout_ms = 30000;
  std::map<std::string, std::string> cfg_default_headers;
  bool cfg_respect_http = true;
  bool cfg_auto_trim = true;
  {
    std::lock_guard<std::mutex> lock(config_mutex_);
    cfg_max_disk_bytes = max_disk_cache_bytes_;
    cfg_max_entries = max_entries_;
    cfg_default_ttl = default_ttl_seconds_;
    cfg_eviction_policy = eviction_policy_;
    cfg_connect_timeout_ms = connect_timeout_ms_;
    cfg_read_timeout_ms = read_timeout_ms_;
    cfg_default_headers = default_headers_;
    cfg_respect_http = respect_http_cache_headers_;
    cfg_auto_trim = auto_trim_on_write_;
  }

  const std::string key = ResolveKey(url, custom_key);
  CacheRecord existing_record;
  bool has_existing = false;
  std::optional<WireCacheFetchResult> fresh_hit;
  {
    std::lock_guard<std::mutex> lock(index_mutex_);
    if (!force_refresh) {
      WireCacheFetchResult cached_result(WireCacheResultSource::kCacheHit, 0);
      if (TryServeFreshCacheLocked(key, tag, pinned, start_ms,
                                   &cached_result)) {
        fresh_hit = std::move(cached_result);
      }
    }
    if (!fresh_hit.has_value()) {
      auto it = entries_.find(key);
      std::error_code ec;
      if (it != entries_.end() &&
          fs::exists(fs::path(Utf8ToWide(it->second.file_path)), ec)) {
        existing_record = it->second;
        has_existing = true;
      }
      miss_count_++;
    }
  }
  if (fresh_hit.has_value()) {
    const auto* entry_copy = fresh_hit->entry();
    if (entry_copy != nullptr) {
      EmitProgress(key, url, WireCacheTransferState::kCacheHit,
                   entry_copy->size_bytes(), entry_copy->size_bytes(),
                   entry_copy->file_path());
    }
    outcome.ok = true;
    outcome.result = std::move(*fresh_hit);
    return outcome;
  }

  std::shared_ptr<std::atomic<bool>> cancel_flag =
      external_cancel ? external_cancel
                      : std::make_shared<std::atomic<bool>>(false);
  const bool owns_cancel = !static_cast<bool>(external_cancel);
  struct CancelGuard {
    XueHuaNaviteCacheManagerPlugin* plugin;
    std::string guarded_key;
    bool own = false;
    ~CancelGuard() {
      if (!own || plugin == nullptr) return;
      std::lock_guard<std::mutex> lock(plugin->flight_mutex_);
      plugin->active_cancels_.erase(guarded_key);
    }
  } cancel_guard{this, key, false};

  if (owns_cancel) {
    std::lock_guard<std::mutex> lock(flight_mutex_);
    active_cancels_[key] = cancel_flag;
    cancel_guard.own = true;
  }

  if (cancel_flag->load()) {
    EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                 "Download canceled");
    outcome.ok = false;
    outcome.error_code = "CANCELED";
    outcome.error_msg = "Download canceled";
    return outcome;
  }

  EmitProgress(key, url, WireCacheTransferState::kStarted, 0, -1);

  const std::wstring wurl = Utf8ToWide(url);
  URL_COMPONENTS urlComp = {};
  urlComp.dwStructSize = sizeof(urlComp);
  const size_t buf_len = std::max<size_t>(2048, wurl.size() + 1);
  std::vector<wchar_t> hostName(buf_len, L'\0');
  std::vector<wchar_t> urlPath(buf_len, L'\0');
  urlComp.lpszHostName = hostName.data();
  urlComp.dwHostNameLength = static_cast<DWORD>(hostName.size());
  urlComp.lpszUrlPath = urlPath.data();
  urlComp.dwUrlPathLength = static_cast<DWORD>(urlPath.size());

  if (!WinHttpCrackUrl(wurl.c_str(), static_cast<DWORD>(wurl.size()), 0,
                       &urlComp)) {
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "WinHttpCrackUrl failed");
    outcome.ok = false;
    outcome.error_code = "INVALID_URL";
    outcome.error_msg = "WinHttpCrackUrl failed";
    return outcome;
  }

  HINTERNET hSession = WinHttpOpen(L"XueHuaNativeCacheManager/1.3",
                                   WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                   WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0);
  if (!hSession) {
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "WinHttpOpen failed");
    outcome.ok = false;
    outcome.error_code = "NETWORK_ERROR";
    outcome.error_msg = "WinHttpOpen failed";
    return outcome;
  }

  WinHttpSetTimeouts(hSession, cfg_connect_timeout_ms, cfg_connect_timeout_ms,
                     cfg_read_timeout_ms, cfg_read_timeout_ms);

  HINTERNET hConnect = WinHttpConnect(hSession, hostName.data(), urlComp.nPort, 0);
  if (!hConnect) {
    WinHttpCloseHandle(hSession);
    if (fallback_on_error && has_existing) {
      const WireCacheEntry existing_wire = existing_record.ToWireEntry();
      outcome.ok = true;
      outcome.result = WireCacheFetchResult(
          &existing_wire,
          WireCacheResultSource::kStaleCacheFallback, nullptr,
          CurrentTimeMs() - start_ms);
      return outcome;
    }
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "WinHttpConnect failed");
    outcome.ok = false;
    outcome.error_code = "NETWORK_ERROR";
    outcome.error_msg = "WinHttpConnect failed";
    return outcome;
  }

  const DWORD flags =
      (urlComp.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
  HINTERNET hRequest =
      WinHttpOpenRequest(hConnect, L"GET", urlPath.data(), nullptr,
                         WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
  if (!hRequest) {
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    if (fallback_on_error && has_existing) {
      const WireCacheEntry existing_wire = existing_record.ToWireEntry();
      outcome.ok = true;
      outcome.result = WireCacheFetchResult(
          &existing_wire,
          WireCacheResultSource::kStaleCacheFallback, nullptr,
          CurrentTimeMs() - start_ms);
      return outcome;
    }
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "WinHttpOpenRequest failed");
    outcome.ok = false;
    outcome.error_code = "NETWORK_ERROR";
    outcome.error_msg = "WinHttpOpenRequest failed";
    return outcome;
  }

  // Merge default headers and request headers (request wins case-insensitively).
  std::map<std::string, std::pair<std::string, std::string>> merged_headers;
  for (const auto& kv : cfg_default_headers) {
    const std::string clean_name = SanitizeHeaderName(kv.first);
    if (!clean_name.empty()) {
      merged_headers[AsciiLower(clean_name)] =
          std::make_pair(clean_name, SanitizeHeaderValue(kv.second));
    }
  }
  for (const auto& kv : ExtractStringMap(request.headers())) {
    const std::string clean_name = SanitizeHeaderName(kv.first);
    if (!clean_name.empty()) {
      merged_headers[AsciiLower(clean_name)] =
          std::make_pair(clean_name, SanitizeHeaderValue(kv.second));
    }
  }
  for (const auto& kv : merged_headers) {
    const std::wstring hdr =
        Utf8ToWide(kv.second.first + ": " + kv.second.second);
    WinHttpAddRequestHeaders(hRequest, hdr.c_str(),
                             static_cast<DWORD>(hdr.size()),
                             WINHTTP_ADDREQ_FLAG_ADD |
                                 WINHTTP_ADDREQ_FLAG_REPLACE);
  }

  if (cfg_respect_http && has_existing) {
    if (!existing_record.etag.empty()) {
      const std::wstring hdr =
          L"If-None-Match: " + Utf8ToWide(SanitizeHeaderValue(existing_record.etag));
      WinHttpAddRequestHeaders(hRequest, hdr.c_str(),
                               static_cast<DWORD>(hdr.size()),
                               WINHTTP_ADDREQ_FLAG_ADD |
                                   WINHTTP_ADDREQ_FLAG_REPLACE);
    }
    if (!existing_record.last_modified.empty()) {
      const std::wstring hdr =
          L"If-Modified-Since: " +
          Utf8ToWide(SanitizeHeaderValue(existing_record.last_modified));
      WinHttpAddRequestHeaders(hRequest, hdr.c_str(),
                               static_cast<DWORD>(hdr.size()),
                               WINHTTP_ADDREQ_FLAG_ADD |
                                   WINHTTP_ADDREQ_FLAG_REPLACE);
    }
  }

  if (cancel_flag->load()) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                 "Download canceled");
    outcome.ok = false;
    outcome.error_code = "CANCELED";
    outcome.error_msg = "Download canceled";
    return outcome;
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
    if (cancel_flag->load()) {
      EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                   "Download canceled");
      outcome.ok = false;
      outcome.error_code = "CANCELED";
      outcome.error_msg = "Download canceled";
      return outcome;
    }
    if (fallback_on_error && has_existing) {
      const WireCacheEntry existing_wire = existing_record.ToWireEntry();
      outcome.ok = true;
      outcome.result = WireCacheFetchResult(
          &existing_wire,
          WireCacheResultSource::kStaleCacheFallback, nullptr,
          CurrentTimeMs() - start_ms);
      return outcome;
    }
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "WinHttpSendRequest/ReceiveResponse failed");
    outcome.ok = false;
    outcome.error_code = "NETWORK_ERROR";
    outcome.error_msg = "WinHttpSendRequest/ReceiveResponse failed";
    return outcome;
  }

  DWORD status_code = 0;
  DWORD dwSize = sizeof(status_code);
  WinHttpQueryHeaders(hRequest,
                      WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                      WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &dwSize,
                      WINHTTP_NO_HEADER_INDEX);

  if (status_code == 304 && has_existing) {
    const std::string new_etag =
        WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_ETAG));
    const std::string new_last_mod =
        WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_LAST_MODIFIED));
    const std::string cache_control =
        WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_CACHE_CONTROL));
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);

    const int64_t now = CurrentTimeMs();
    const auto header_ttl =
        cfg_respect_http ? ParseMaxAgeSeconds(cache_control) : std::nullopt;
    const int64_t ttl_sec =
        has_ttl ? ttl_override : (header_ttl ? *header_ttl : cfg_default_ttl);

    WireCacheEntry wire_entry(existing_record.ToWireEntry());
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      CacheRecord refreshed =
          (it != entries_.end()) ? it->second : existing_record;
      refreshed.last_accessed_at_ms = now;
      refreshed.expires_at_ms = now + ttl_sec * 1000LL;
      refreshed.hit_count += 1;
      if (!new_etag.empty()) refreshed.etag = new_etag;
      if (!new_last_mod.empty()) refreshed.last_modified = new_last_mod;
      if (!tag.empty()) refreshed.tag = tag;
      if (pinned) refreshed.pinned = true;
      entries_[key] = refreshed;
      hit_count_++;
      PersistIndexLocked();
      wire_entry = refreshed.ToWireEntry();
    }

    EmitProgress(key, url, WireCacheTransferState::kCacheHit,
                 wire_entry.size_bytes(), wire_entry.size_bytes(),
                 wire_entry.file_path());
    const int64_t status_val = 304;
    outcome.ok = true;
    outcome.result = WireCacheFetchResult(
        &wire_entry, WireCacheResultSource::kRevalidated, &status_val,
        now - start_ms);
    return outcome;
  }

  if (status_code < 200 || status_code >= 300) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    if (fallback_on_error && has_existing) {
      const int64_t status_val = static_cast<int64_t>(status_code);
      const WireCacheEntry existing_wire = existing_record.ToWireEntry();
      outcome.ok = true;
      outcome.result = WireCacheFetchResult(
          &existing_wire,
          WireCacheResultSource::kStaleCacheFallback, &status_val,
          CurrentTimeMs() - start_ms);
      return outcome;
    }
    const std::string err = "HTTP status " + std::to_string(status_code);
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "", err);
    outcome.ok = false;
    outcome.error_code = "HTTP_ERROR";
    outcome.error_msg = err;
    return outcome;
  }

  const std::string content_type =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_CONTENT_TYPE));
  const std::string etag =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_ETAG));
  const std::string last_modified =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_LAST_MODIFIED));
  const std::string cache_control =
      WideToUtf8(QueryWinHttpHeader(hRequest, WINHTTP_QUERY_CACHE_CONTROL));
  const int64_t expected_total = QueryContentLength(hRequest);

  std::vector<uint8_t> buffer;
  if (expected_total > 0 && expected_total <= 64LL * 1024LL * 1024LL) {
    buffer.reserve(static_cast<size_t>(expected_total));
  }
  bool read_failed = false;
  int64_t last_progress_emit_ms = 0;

  for (;;) {
    if (cancel_flag->load()) {
      WinHttpCloseHandle(hRequest);
      WinHttpCloseHandle(hConnect);
      WinHttpCloseHandle(hSession);
      EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                   "Download canceled");
      outcome.ok = false;
      outcome.error_code = "CANCELED";
      outcome.error_msg = "Download canceled";
      return outcome;
    }
    DWORD dwAvailable = 0;
    if (!WinHttpQueryDataAvailable(hRequest, &dwAvailable)) {
      read_failed = true;
      break;
    }
    if (dwAvailable == 0) {
      break;
    }
    if (cancel_flag->load()) {
      WinHttpCloseHandle(hRequest);
      WinHttpCloseHandle(hConnect);
      WinHttpCloseHandle(hSession);
      EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                   "Download canceled");
      outcome.ok = false;
      outcome.error_code = "CANCELED";
      outcome.error_msg = "Download canceled";
      return outcome;
    }
    const size_t cur_size = buffer.size();
    buffer.resize(cur_size + dwAvailable);
    DWORD dwDownloaded = 0;
    if (WinHttpReadData(hRequest, buffer.data() + cur_size, dwAvailable,
                        &dwDownloaded)) {
      buffer.resize(cur_size + dwDownloaded);
      if (dwDownloaded == 0) {
        break;
      }
      const int64_t now_ms = CurrentTimeMs();
      if (last_progress_emit_ms == 0 ||
          now_ms - last_progress_emit_ms >= 50 ||
          (expected_total > 0 &&
           static_cast<int64_t>(buffer.size()) >= expected_total)) {
        last_progress_emit_ms = now_ms;
        EmitProgress(key, url, WireCacheTransferState::kInProgress,
                     static_cast<int64_t>(buffer.size()), expected_total);
      }
    } else {
      buffer.resize(cur_size);
      read_failed = true;
      break;
    }
  }

  WinHttpCloseHandle(hRequest);
  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);

  if (cancel_flag->load()) {
    EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                 "Download canceled");
    outcome.ok = false;
    outcome.error_code = "CANCELED";
    outcome.error_msg = "Download canceled";
    return outcome;
  }

  if (read_failed) {
    if (fallback_on_error && has_existing) {
      const WireCacheEntry existing_wire = existing_record.ToWireEntry();
      outcome.ok = true;
      outcome.result = WireCacheFetchResult(
          &existing_wire,
          WireCacheResultSource::kStaleCacheFallback, nullptr,
          CurrentTimeMs() - start_ms);
      return outcome;
    }
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "Failed reading response body");
    outcome.ok = false;
    outcome.error_code = "NETWORK_ERROR";
    outcome.error_msg = "Failed reading response body";
    return outcome;
  }

  std::string computed_hash;
  if (checksum_alg != WireCacheChecksumAlgorithm::kNone) {
    computed_hash =
        ComputeBCryptHash(buffer.data(), buffer.size(), checksum_alg_str);
    if (!expected_checksum.empty() &&
        AsciiLower(computed_hash) != expected_checksum) {
      EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                   "Checksum mismatch");
      outcome.ok = false;
      outcome.error_code = "CHECKSUM_MISMATCH";
      outcome.error_msg = "Checksum mismatch";
      return outcome;
    }
  }

  const std::string ext = InferExtension(url, content_type, file_extension);
  const fs::path root_dir_fs(Utf8ToWide(GetCacheRootDir(true)));
  const fs::path dest_path = root_dir_fs / Utf8ToWide(key + "." + ext);
  const fs::path tmp_path = root_dir_fs / Utf8ToWide(key + ".download.tmp");
  bool wrote_file = false;
  {
    std::ofstream ofs(tmp_path, std::ios::binary | std::ios::trunc);
    if (ofs.is_open()) {
      if (!buffer.empty()) {
        ofs.write(reinterpret_cast<const char*>(buffer.data()),
                  static_cast<std::streamsize>(buffer.size()));
      }
      ofs.flush();
      wrote_file = static_cast<bool>(ofs);
    }
  }
  if (!wrote_file ||
      !MoveFileExW(tmp_path.wstring().c_str(), dest_path.wstring().c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(tmp_path.wstring().c_str());
    EmitProgress(key, url, WireCacheTransferState::kFailed, 0, -1, "",
                 "Failed writing cached file");
    outcome.ok = false;
    outcome.error_code = "DISK_WRITE_ERROR";
    outcome.error_msg = "Failed writing cached file";
    return outcome;
  }

  const int64_t now = CurrentTimeMs();
  const auto header_ttl =
      cfg_respect_http ? ParseMaxAgeSeconds(cache_control) : std::nullopt;
  const int64_t ttl_sec =
      has_ttl ? ttl_override : (header_ttl ? *header_ttl : cfg_default_ttl);

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
  record.checksum_algorithm = checksum_alg_str;
  record.pinned = pinned;

  WireCacheEntry wire_entry(record.ToWireEntry());
  {
    std::lock_guard<std::mutex> lock(index_mutex_);
    auto prev = entries_.find(key);
    if (prev != entries_.end()) {
      total_cached_bytes_ =
          std::max<int64_t>(0, total_cached_bytes_ - prev->second.size_bytes);
      if (prev->second.file_path != record.file_path) {
        std::error_code ec;
        fs::remove(fs::path(Utf8ToWide(prev->second.file_path)), ec);
      }
    }
    entries_[key] = record;
    total_cached_bytes_ += record.size_bytes;
    if (cfg_auto_trim) {
      EnforceQuotaLocked(cfg_max_disk_bytes, cfg_max_entries,
                         cfg_eviction_policy, key);
    }
    PersistIndexLocked();
  }

  EmitProgress(key, url, WireCacheTransferState::kCompleted, record.size_bytes,
               record.size_bytes, record.file_path);

  const int64_t status_val = static_cast<int64_t>(status_code);
  outcome.ok = true;
  outcome.result = WireCacheFetchResult(
      &wire_entry, WireCacheResultSource::kNetworkDownload, &status_val,
      CurrentTimeMs() - start_ms);
  return outcome;
}

void XueHuaNaviteCacheManagerPlugin::FinishInFlight(
    const std::string& key,
    const std::shared_ptr<InFlightDownload>& state,
    const DownloadOutcome& outcome) {
  std::vector<std::function<void(const DownloadOutcome&)>> waiters;
  {
    std::lock_guard<std::mutex> lock(flight_mutex_);
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

void XueHuaNaviteCacheManagerPlugin::ScheduleDownload(
    const WireCacheRequest& request,
    const std::function<void(const DownloadOutcome&)>& callback) {
  const int64_t start_ms = CurrentTimeMs();
  const std::string url = TrimAscii(request.url());
  if (url.empty()) {
    DownloadOutcome outcome;
    outcome.ok = false;
    outcome.error_code = "INVALID_URL";
    outcome.error_msg = "URL is required";
    callback(outcome);
    return;
  }

  const std::string custom_key =
      request.custom_key() ? *request.custom_key() : "";
  const std::string tag = request.tag() ? *request.tag() : "";
  const bool force_refresh = request.force_refresh();
  const bool pinned = request.pinned();
  const std::string key = ResolveKey(url, custom_key);

  if (!force_refresh) {
    WireCacheFetchResult cached(WireCacheResultSource::kCacheHit, 0);
    bool hit = false;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      hit = TryServeFreshCacheLocked(key, tag, pinned, start_ms, &cached);
    }
    if (hit) {
      const auto* entry_copy = cached.entry();
      if (entry_copy != nullptr) {
        EmitProgress(key, url, WireCacheTransferState::kCacheHit,
                     entry_copy->size_bytes(), entry_copy->size_bytes(),
                     entry_copy->file_path());
      }
      DownloadOutcome early;
      early.ok = true;
      early.result = std::move(cached);
      callback(early);
      return;
    }
  }

  std::shared_ptr<InFlightDownload> state;
  {
    std::lock_guard<std::mutex> lock(flight_mutex_);
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

  PostDownloadJob([this, request, url, key, state]() {
    DownloadOutcome outcome;
    try {
      if (state->cancel_flag->load()) {
        outcome.ok = false;
        outcome.error_code = "CANCELED";
        outcome.error_msg = "Download canceled";
        EmitProgress(key, url, WireCacheTransferState::kCanceled, 0, -1, "",
                     "Download canceled");
      } else {
        outcome = ExecuteDownload(request, state->cancel_flag);
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

// MARK: - CacheHostApi

void XueHuaNaviteCacheManagerPlugin::Configure(
    const WireCacheManagerConfig& config,
    std::function<void(std::optional<FlutterError> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(std::optional<FlutterError>)>>(
          std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, config, shared_reply, dispatch]() {
    std::string prev_subdir;
    std::string next_subdir;
    int new_conc = 4;
    int64_t target_max_bytes = 0;
    int target_max_entries = 20000;
    std::string target_policy = "lru";
    bool should_auto_trim = true;

    std::map<std::string, std::string> next_headers =
        ExtractStringMap(config.default_headers());

    {
      std::lock_guard<std::mutex> lock(config_mutex_);
      prev_subdir = cache_subdirectory_;
      max_disk_cache_bytes_ = std::max<int64_t>(1, config.max_disk_cache_bytes());
      max_entries_ = std::max(1, static_cast<int>(config.max_entries()));
      default_ttl_seconds_ = std::max<int64_t>(0, config.default_ttl_seconds());
      eviction_policy_ = EvictionPolicyToString(config.eviction_policy());
      const std::string trimmed_subdir = TrimAscii(config.cache_subdirectory());
      next_subdir = trimmed_subdir.empty() ? prev_subdir : trimmed_subdir;
      new_conc = std::max(1, static_cast<int>(config.max_concurrent_downloads()));
      connect_timeout_ms_ = std::max(1, static_cast<int>(config.connect_timeout_ms()));
      read_timeout_ms_ = std::max(1, static_cast<int>(config.read_timeout_ms()));
      default_headers_ = std::move(next_headers);
      respect_http_cache_headers_ = config.respect_http_cache_headers();
      auto_trim_on_write_ = config.auto_trim_on_write();

      target_max_bytes = max_disk_cache_bytes_;
      target_max_entries = max_entries_;
      target_policy = eviction_policy_;
      should_auto_trim = auto_trim_on_write_;
    }

    EnsureDownloadWorkers(new_conc);

    if (prev_subdir != next_subdir) {
      FlushIndexSnapshot(prev_subdir);
      {
        std::lock_guard<std::mutex> lock(index_mutex_);
        index_dirty_.store(false, std::memory_order_release);
        index_loaded_ = false;
        entries_.clear();
        total_cached_bytes_ = 0;
        hit_count_ = 0;
        miss_count_ = 0;
        eviction_count_ = 0;
      }
      {
        std::lock_guard<std::mutex> lock(config_mutex_);
        cache_subdirectory_ = next_subdir;
      }
    }

    EnsureIndexLoaded();

    if (should_auto_trim) {
      std::lock_guard<std::mutex> lock(index_mutex_);
      const int evicted = EnforceQuotaLocked(
          target_max_bytes, target_max_entries, target_policy, "");
      if (evicted > 0) {
        PersistIndexLocked();
      }
    }

    PostToPlatformThread([dispatch, shared_reply]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(std::nullopt);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::DownloadFile(
    const WireCacheRequest& request,
    std::function<void(ErrorOr<WireCacheFetchResult> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<WireCacheFetchResult>)>>(
          std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, request, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    ScheduleDownload(request, [this, shared_reply,
                               dispatch](const DownloadOutcome& outcome) {
      PostToPlatformThread([dispatch, shared_reply, outcome]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        if (outcome.ok && outcome.result.has_value()) {
          (*shared_reply)(*outcome.result);
        } else {
          (*shared_reply)(
              FlutterError(outcome.error_code, outcome.error_msg));
        }
      });
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::PrefetchAll(
    const ::flutter::EncodableList& requests,
    std::function<void(ErrorOr<::flutter::EncodableList> reply)> result) {
  std::vector<WireCacheRequest> parsed = UnpackPrefetchRequests(requests);
  if (parsed.empty()) {
    result(::flutter::EncodableList());
    return;
  }

  auto shared_reply = std::make_shared<
      std::function<void(ErrorOr<::flutter::EncodableList>)>>(
      std::move(result));
  auto dispatch = CopyEventState();

  PostIoJob([this, parsed = std::move(parsed), shared_reply, dispatch]() {
    EnsureIndexLoaded();

    struct PrefetchState {
      std::mutex mu;
      size_t remaining = 0;
      std::vector<std::optional<WireCacheEntry>> slots;
    };
    auto prefetch_state = std::make_shared<PrefetchState>();
    prefetch_state->remaining = parsed.size();
    prefetch_state->slots.resize(parsed.size());

    for (size_t index = 0; index < parsed.size(); ++index) {
      ScheduleDownload(
          parsed[index], [this, shared_reply, dispatch, prefetch_state,
                          index](const DownloadOutcome& outcome) {
            ::flutter::EncodableList list_out;
            bool done = false;
            {
              std::lock_guard<std::mutex> lock(prefetch_state->mu);
              if (outcome.ok && outcome.result.has_value() &&
                  outcome.result->entry() != nullptr) {
                prefetch_state->slots[index] = *outcome.result->entry();
              }
              prefetch_state->remaining -= 1;
              if (prefetch_state->remaining == 0) {
                done = true;
                for (const auto& slot : prefetch_state->slots) {
                  if (slot.has_value()) {
                    list_out.push_back(
                        ::flutter::CustomEncodableValue(*slot));
                  }
                }
              }
            }
            if (done) {
              PostToPlatformThread(
                  [dispatch, shared_reply, list_out = std::move(list_out)]() {
                    if (!dispatch) return;
                    {
                      std::lock_guard<std::mutex> lock(dispatch->mu);
                      if (!dispatch->alive) return;
                    }
                    (*shared_reply)(list_out);
                  });
            }
          });
    }
  });
}

ErrorOr<bool> XueHuaNaviteCacheManagerPlugin::CancelDownload(
    const std::string& key_or_url) {
  // Never touch index_mutex_ or disk I/O so synchronous cancellation cannot
  // block behind background index operations.
  const std::string sha_key = ComputeBCryptHash(
      reinterpret_cast<const uint8_t*>(key_or_url.data()), key_or_url.size(),
      "sha256");

  std::lock_guard<std::mutex> lock(flight_mutex_);
  auto cancel_it = active_cancels_.find(key_or_url);
  if (cancel_it == active_cancels_.end()) {
    cancel_it = active_cancels_.find(sha_key);
  }
  if (cancel_it != active_cancels_.end() && cancel_it->second) {
    cancel_it->second->store(true);
    return true;
  }

  auto flight_it = in_flight_.find(key_or_url);
  if (flight_it == in_flight_.end()) {
    flight_it = in_flight_.find(sha_key);
  }
  if (flight_it != in_flight_.end() && flight_it->second &&
      flight_it->second->cancel_flag) {
    flight_it->second->cancel_flag->store(true);
    return true;
  }
  return false;
}

void XueHuaNaviteCacheManagerPlugin::GetFileFromCache(
    const std::string& key_or_url,
    bool ignore_expired,
    std::function<void(ErrorOr<std::optional<WireCacheEntry>> reply)> result) {
  auto shared_reply = std::make_shared<
      std::function<void(ErrorOr<std::optional<WireCacheEntry>>)>>(
      std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, key_or_url, ignore_expired, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(key_or_url);

    std::optional<WireCacheEntry> out_entry;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      if (it == entries_.end()) {
        miss_count_++;
      } else {
        std::error_code ec;
        if (!fs::exists(fs::path(Utf8ToWide(it->second.file_path)), ec)) {
          total_cached_bytes_ = std::max<int64_t>(
              0, total_cached_bytes_ - it->second.size_bytes);
          entries_.erase(it);
          miss_count_++;
          PersistIndexLocked();
        } else {
          const int64_t now = CurrentTimeMs();
          if (ignore_expired && it->second.IsExpired(now)) {
            miss_count_++;
          } else {
            it->second.last_accessed_at_ms = now;
            it->second.hit_count++;
            hit_count_++;
            PersistIndexLocked();
            out_entry = it->second.ToWireEntry();
          }
        }
      }
    }

    if (out_entry.has_value()) {
      EmitProgress(out_entry->key(), out_entry->url(),
                   WireCacheTransferState::kCacheHit, out_entry->size_bytes(),
                   out_entry->size_bytes(), out_entry->file_path());
    }

    PostToPlatformThread([dispatch, shared_reply, out_entry]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(out_entry);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::ReadCacheBytes(
    const std::string& key_or_url,
    bool ignore_expired,
    std::function<void(ErrorOr<std::optional<std::vector<uint8_t>>> reply)>
        result) {
  auto shared_reply = std::make_shared<
      std::function<void(ErrorOr<std::optional<std::vector<uint8_t>>>)>>(
      std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, key_or_url, ignore_expired, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(key_or_url);

    std::string file_path;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      const int64_t now = CurrentTimeMs();
      std::error_code ec;
      if (it == entries_.end()) {
        miss_count_++;
      } else if (!fs::exists(fs::path(Utf8ToWide(it->second.file_path)), ec)) {
        total_cached_bytes_ = std::max<int64_t>(
            0, total_cached_bytes_ - it->second.size_bytes);
        entries_.erase(it);
        miss_count_++;
        PersistIndexLocked();
      } else if (!ignore_expired || !it->second.IsExpired(now)) {
        it->second.last_accessed_at_ms = now;
        it->second.hit_count++;
        hit_count_++;
        PersistIndexLocked();
        file_path = it->second.file_path;
      } else {
        miss_count_++;
      }
    }

    std::optional<std::vector<uint8_t>> bytes_out;
    if (!file_path.empty()) {
      std::ifstream ifs(fs::path(Utf8ToWide(file_path)),
                        std::ios::binary | std::ios::ate);
      if (ifs.is_open()) {
        const std::streamsize size = ifs.tellg();
        if (size >= 0) {
          ifs.seekg(0, std::ios::beg);
          std::vector<uint8_t> bytes(static_cast<size_t>(size));
          if (size == 0 ||
              ifs.read(reinterpret_cast<char*>(bytes.data()), size)) {
            bytes_out = std::move(bytes);
          }
        }
      }
    }

    PostToPlatformThread(
        [dispatch, shared_reply, bytes_out = std::move(bytes_out)]() {
          if (!dispatch) return;
          {
            std::lock_guard<std::mutex> lock(dispatch->mu);
            if (!dispatch->alive) return;
          }
          (*shared_reply)(bytes_out);
        });
  });
}

void XueHuaNaviteCacheManagerPlugin::ContainsKey(
    const std::string& key_or_url,
    bool ignore_expired,
    std::function<void(ErrorOr<bool> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<bool>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, key_or_url, ignore_expired, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(key_or_url);

    bool exists = false;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      std::error_code ec;
      if (it != entries_.end() &&
          fs::exists(fs::path(Utf8ToWide(it->second.file_path)), ec)) {
        exists = !ignore_expired || !it->second.IsExpired(CurrentTimeMs());
      }
    }

    PostToPlatformThread([dispatch, shared_reply, exists]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(exists);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::PutBytes(
    const std::string& key,
    const std::vector<uint8_t>& bytes,
    const std::string* url,
    const std::string* file_extension,
    const std::string* mime_type,
    const std::string* tag,
    const int64_t* ttl_seconds,
    bool pinned,
    std::function<void(ErrorOr<WireCacheEntry> reply)> result) {
  const std::string clean_key = TrimAscii(key);
  if (clean_key.empty()) {
    result(FlutterError("INVALID_ARGS", "key and bytes are required"));
    return;
  }

  const std::string url_str = url ? *url : ("local://" + clean_key);
  const std::string ext_str = file_extension ? *file_extension : "";
  const std::string mime_str =
      (mime_type && !mime_type->empty()) ? *mime_type
                                         : "application/octet-stream";
  const std::string tag_str = tag ? *tag : "";
  const std::optional<int64_t> ttl_opt =
      ttl_seconds ? std::optional<int64_t>(*ttl_seconds) : std::nullopt;

  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<WireCacheEntry>)>>(
          std::move(result));
  auto dispatch = CopyEventState();

  PostIoJob([this, clean_key, bytes, url_str, ext_str, mime_str, tag_str,
             ttl_opt, pinned, shared_reply, dispatch]() {
    EnsureIndexLoaded();

    int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
    int64_t cfg_max_disk_bytes = 500LL * 1024LL * 1024LL;
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    bool cfg_auto_trim = true;
    {
      std::lock_guard<std::mutex> lock(config_mutex_);
      cfg_default_ttl = default_ttl_seconds_;
      cfg_max_disk_bytes = max_disk_cache_bytes_;
      cfg_max_entries = max_entries_;
      cfg_policy = eviction_policy_;
      cfg_auto_trim = auto_trim_on_write_;
    }

    const std::string ext = InferExtension(url_str, mime_str, ext_str);
    const fs::path root_dir_fs(Utf8ToWide(GetCacheRootDir(true)));
    const fs::path dest_path = root_dir_fs / Utf8ToWide(clean_key + "." + ext);
    const fs::path tmp_path =
        root_dir_fs / Utf8ToWide(clean_key + ".put.tmp");

    bool wrote_ok = false;
    {
      std::ofstream ofs(tmp_path, std::ios::binary | std::ios::trunc);
      if (ofs.is_open()) {
        if (!bytes.empty()) {
          ofs.write(reinterpret_cast<const char*>(bytes.data()),
                    static_cast<std::streamsize>(bytes.size()));
        }
        ofs.flush();
        wrote_ok = static_cast<bool>(ofs);
      }
    }
    if (!wrote_ok ||
        !MoveFileExW(tmp_path.wstring().c_str(), dest_path.wstring().c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      DeleteFileW(tmp_path.wstring().c_str());
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("PUT_BYTES_FAILED", "Failed writing cache file"));
      });
      return;
    }

    const int64_t now = CurrentTimeMs();
    const int64_t ttl_sec = ttl_opt ? *ttl_opt : cfg_default_ttl;
    CacheRecord rec;
    rec.key = clean_key;
    rec.url = url_str;
    rec.file_path = WideToUtf8(dest_path.wstring());
    rec.size_bytes = static_cast<int64_t>(bytes.size());
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag_str;
    rec.mime_type = mime_str;
    rec.checksum = ComputeBCryptHash(bytes.data(), bytes.size(), "sha256");
    rec.checksum_algorithm = "sha256";
    rec.pinned = pinned;

    WireCacheEntry wire_entry(rec.ToWireEntry());
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto prev = entries_.find(clean_key);
      if (prev != entries_.end()) {
        total_cached_bytes_ =
            std::max<int64_t>(0, total_cached_bytes_ - prev->second.size_bytes);
        if (prev->second.file_path != rec.file_path) {
          std::error_code ec;
          fs::remove(fs::path(Utf8ToWide(prev->second.file_path)), ec);
        }
      }
      entries_[clean_key] = rec;
      total_cached_bytes_ += rec.size_bytes;
      if (cfg_auto_trim) {
        EnforceQuotaLocked(cfg_max_disk_bytes, cfg_max_entries, cfg_policy,
                           clean_key);
      }
      PersistIndexLocked();
    }

    PostToPlatformThread([dispatch, shared_reply, wire_entry]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(wire_entry);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::PutFile(
    const std::string& key,
    const std::string& source_file_path,
    const std::string* url,
    const std::string* file_extension,
    const std::string* mime_type,
    const std::string* tag,
    const int64_t* ttl_seconds,
    bool pinned,
    std::function<void(ErrorOr<WireCacheEntry> reply)> result) {
  const std::string clean_key = TrimAscii(key);
  const std::string clean_source = TrimAscii(source_file_path);
  if (clean_key.empty() || clean_source.empty()) {
    result(FlutterError("INVALID_SOURCE", "Source file does not exist"));
    return;
  }

  const std::string url_str = url ? *url : ("file://" + clean_source);
  const std::string source_ext =
      WideToUtf8(fs::path(Utf8ToWide(clean_source)).extension().wstring());
  const std::string ext_str =
      (file_extension && !file_extension->empty()) ? *file_extension
                                                   : source_ext;
  const std::string mime_str =
      (mime_type && !mime_type->empty()) ? *mime_type
                                         : "application/octet-stream";
  const std::string tag_str = tag ? *tag : "";
  const std::optional<int64_t> ttl_opt =
      ttl_seconds ? std::optional<int64_t>(*ttl_seconds) : std::nullopt;

  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<WireCacheEntry>)>>(
          std::move(result));
  auto dispatch = CopyEventState();

  PostIoJob([this, clean_key, clean_source, url_str, ext_str, mime_str, tag_str,
             ttl_opt, pinned, shared_reply, dispatch]() {
    EnsureIndexLoaded();

    std::error_code ec;
    const fs::path src_fs_path(Utf8ToWide(clean_source));
    if (!fs::exists(src_fs_path, ec)) {
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("INVALID_SOURCE", "Source file does not exist"));
      });
      return;
    }

    std::ifstream ifs(src_fs_path, std::ios::binary | std::ios::ate);
    if (!ifs.is_open()) {
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("INVALID_SOURCE", "Unable to open source file"));
      });
      return;
    }
    const std::streamsize size = ifs.tellg();
    if (size < 0) {
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("INVALID_SOURCE", "Unable to read source file size"));
      });
      return;
    }
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    if (size > 0 && !ifs.read(reinterpret_cast<char*>(bytes.data()), size)) {
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("INVALID_SOURCE", "Failed reading source file"));
      });
      return;
    }
    ifs.close();

    int64_t cfg_default_ttl = 7LL * 24LL * 3600LL;
    int64_t cfg_max_disk_bytes = 500LL * 1024LL * 1024LL;
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    bool cfg_auto_trim = true;
    {
      std::lock_guard<std::mutex> lock(config_mutex_);
      cfg_default_ttl = default_ttl_seconds_;
      cfg_max_disk_bytes = max_disk_cache_bytes_;
      cfg_max_entries = max_entries_;
      cfg_policy = eviction_policy_;
      cfg_auto_trim = auto_trim_on_write_;
    }

    const std::string ext = InferExtension(url_str, mime_str, ext_str);
    const fs::path dest_path =
        fs::path(Utf8ToWide(GetCacheRootDir(true))) /
        Utf8ToWide(clean_key + "." + ext);
    fs::copy_file(src_fs_path, dest_path, fs::copy_options::overwrite_existing,
                  ec);
    if (ec) {
      PostToPlatformThread([dispatch, shared_reply]() {
        if (!dispatch) return;
        {
          std::lock_guard<std::mutex> lock(dispatch->mu);
          if (!dispatch->alive) return;
        }
        (*shared_reply)(
            FlutterError("PUT_FILE_FAILED", "Failed copying source file"));
      });
      return;
    }

    const int64_t now = CurrentTimeMs();
    const int64_t ttl_sec = ttl_opt ? *ttl_opt : cfg_default_ttl;
    CacheRecord rec;
    rec.key = clean_key;
    rec.url = url_str;
    rec.file_path = WideToUtf8(dest_path.wstring());
    rec.size_bytes = static_cast<int64_t>(bytes.size());
    rec.created_at_ms = now;
    rec.last_accessed_at_ms = now;
    rec.expires_at_ms = now + ttl_sec * 1000LL;
    rec.hit_count = 1;
    rec.tag = tag_str;
    rec.mime_type = mime_str;
    rec.checksum = ComputeBCryptHash(bytes.data(), bytes.size(), "sha256");
    rec.checksum_algorithm = "sha256";
    rec.pinned = pinned;

    WireCacheEntry wire_entry(rec.ToWireEntry());
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto prev = entries_.find(clean_key);
      if (prev != entries_.end()) {
        total_cached_bytes_ =
            std::max<int64_t>(0, total_cached_bytes_ - prev->second.size_bytes);
        if (prev->second.file_path != rec.file_path) {
          std::error_code rm_ec;
          fs::remove(fs::path(Utf8ToWide(prev->second.file_path)), rm_ec);
        }
      }
      entries_[clean_key] = rec;
      total_cached_bytes_ += rec.size_bytes;
      if (cfg_auto_trim) {
        EnforceQuotaLocked(cfg_max_disk_bytes, cfg_max_entries, cfg_policy,
                           clean_key);
      }
      PersistIndexLocked();
    }

    PostToPlatformThread([dispatch, shared_reply, wire_entry]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(wire_entry);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::SetPinned(
    const std::string& key_or_url,
    bool pinned,
    std::function<void(ErrorOr<bool> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<bool>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, key_or_url, pinned, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(key_or_url);
    bool updated = false;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      if (it != entries_.end()) {
        it->second.pinned = pinned;
        PersistIndexLocked();
        updated = true;
      }
    }
    PostToPlatformThread([dispatch, shared_reply, updated]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(updated);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::RemoveFile(
    const std::string& key_or_url,
    std::function<void(ErrorOr<bool> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<bool>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, key_or_url, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const std::string key = ResolveKey(key_or_url);
    std::string path_to_delete;
    bool removed = false;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      auto it = entries_.find(key);
      if (it != entries_.end()) {
        path_to_delete = it->second.file_path;
        total_cached_bytes_ = std::max<int64_t>(
            0, total_cached_bytes_ - it->second.size_bytes);
        entries_.erase(it);
        PersistIndexLocked();
        removed = true;
      }
    }
    if (!path_to_delete.empty()) {
      std::error_code ec;
      fs::remove(fs::path(Utf8ToWide(path_to_delete)), ec);
    }
    PostToPlatformThread([dispatch, shared_reply, removed]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(removed);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::RemoveByTag(
    const std::string& tag,
    std::function<void(ErrorOr<int64_t> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<int64_t>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, tag, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    std::vector<std::string> paths;
    int64_t removed_count = 0;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      std::vector<std::string> keys;
      for (const auto& kv : entries_) {
        if (kv.second.tag == tag) keys.push_back(kv.first);
      }
      paths.reserve(keys.size());
      for (const auto& k : keys) {
        auto it = entries_.find(k);
        if (it != entries_.end()) {
          paths.push_back(it->second.file_path);
          total_cached_bytes_ = std::max<int64_t>(
              0, total_cached_bytes_ - it->second.size_bytes);
          entries_.erase(it);
        }
      }
      removed_count = static_cast<int64_t>(keys.size());
      if (removed_count > 0) {
        PersistIndexLocked();
      }
    }
    std::error_code ec;
    for (const auto& path : paths) {
      fs::remove(fs::path(Utf8ToWide(path)), ec);
    }
    PostToPlatformThread([dispatch, shared_reply, removed_count]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(removed_count);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::RemoveExpired(
    std::function<void(ErrorOr<int64_t> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<int64_t>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    int64_t removed = 0;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      removed = static_cast<int64_t>(RemoveExpiredLocked());
      if (removed > 0) {
        PersistIndexLocked();
      }
    }
    PostToPlatformThread([dispatch, shared_reply, removed]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(removed);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::TrimToSize(
    int64_t max_bytes,
    std::function<void(ErrorOr<int64_t> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<int64_t>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, max_bytes, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    int cfg_max_entries = 20000;
    std::string cfg_policy = "lru";
    {
      std::lock_guard<std::mutex> lock(config_mutex_);
      cfg_max_entries = max_entries_;
      cfg_policy = eviction_policy_;
    }

    int64_t evicted = 0;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      evicted = static_cast<int64_t>(
          EnforceQuotaLocked(max_bytes, cfg_max_entries, cfg_policy, ""));
      if (evicted > 0) {
        PersistIndexLocked();
      }
    }
    PostToPlatformThread([dispatch, shared_reply, evicted]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(evicted);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::ClearAll(
    bool include_pinned,
    std::function<void(ErrorOr<int64_t> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<int64_t>)>>(std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, include_pinned, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    std::vector<std::string> paths;
    int64_t cleared = 0;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      std::vector<std::string> keys;
      for (const auto& kv : entries_) {
        if (include_pinned || !kv.second.pinned) keys.push_back(kv.first);
      }
      paths.reserve(keys.size());
      for (const auto& k : keys) {
        auto it = entries_.find(k);
        if (it != entries_.end()) {
          paths.push_back(it->second.file_path);
          total_cached_bytes_ = std::max<int64_t>(
              0, total_cached_bytes_ - it->second.size_bytes);
          entries_.erase(it);
        }
      }
      cleared = static_cast<int64_t>(keys.size());
      PersistIndexLocked();
    }
    std::error_code ec;
    for (const auto& path : paths) {
      fs::remove(fs::path(Utf8ToWide(path)), ec);
    }
    PostToPlatformThread([dispatch, shared_reply, cleared]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(cleared);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::ListEntries(
    const std::string* tag,
    bool include_expired,
    std::function<void(ErrorOr<::flutter::EncodableList> reply)> result) {
  const std::optional<std::string> tag_opt =
      tag ? std::optional<std::string>(*tag) : std::nullopt;
  auto shared_reply = std::make_shared<
      std::function<void(ErrorOr<::flutter::EncodableList>)>>(
      std::move(result));
  auto dispatch = CopyEventState();

  PostIoJob([this, tag_opt, include_expired, shared_reply, dispatch]() {
    EnsureIndexLoaded();
    const int64_t now = CurrentTimeMs();
    std::vector<CacheRecord> filtered;
    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      for (const auto& kv : entries_) {
        if ((!tag_opt.has_value() || kv.second.tag == *tag_opt) &&
            (include_expired || !kv.second.IsExpired(now))) {
          filtered.push_back(kv.second);
        }
      }
    }
    std::sort(filtered.begin(), filtered.end(),
              [](const CacheRecord& a, const CacheRecord& b) {
                return a.last_accessed_at_ms > b.last_accessed_at_ms;
              });

    ::flutter::EncodableList out;
    out.reserve(filtered.size());
    for (const auto& rec : filtered) {
      out.push_back(::flutter::CustomEncodableValue(rec.ToWireEntry()));
    }

    PostToPlatformThread([dispatch, shared_reply, out = std::move(out)]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(out);
    });
  });
}

void XueHuaNaviteCacheManagerPlugin::GetStats(
    std::function<void(ErrorOr<WireCacheStats> reply)> result) {
  auto shared_reply =
      std::make_shared<std::function<void(ErrorOr<WireCacheStats>)>>(
          std::move(result));
  auto dispatch = CopyEventState();
  PostIoJob([this, shared_reply, dispatch]() {
    EnsureIndexLoaded();

    int64_t cfg_max_disk_bytes = 500LL * 1024LL * 1024LL;
    {
      std::lock_guard<std::mutex> lock(config_mutex_);
      cfg_max_disk_bytes = max_disk_cache_bytes_;
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
    ::flutter::EncodableMap bytes_by_tag;

    {
      std::lock_guard<std::mutex> lock(index_mutex_);
      std::map<std::string, int64_t> tag_sums;
      for (const auto& kv : entries_) {
        total_bytes += kv.second.size_bytes;
        if (kv.second.IsExpired(now)) expired_count++;
        if (kv.second.pinned) pinned_count++;
        const std::string t =
            kv.second.tag.empty() ? "untagged" : kv.second.tag;
        tag_sums[t] += kv.second.size_bytes;
      }
      total_cached_bytes_ = total_bytes;
      total_entries = static_cast<int64_t>(entries_.size());
      hits = hit_count_;
      misses = miss_count_;
      evictions = eviction_count_;
      for (const auto& tkv : tag_sums) {
        bytes_by_tag[::flutter::EncodableValue(tkv.first)] =
            ::flutter::EncodableValue(tkv.second);
      }
    }

    WireCacheStats stats(total_entries, total_bytes, expired_count,
                         pinned_count, cfg_max_disk_bytes, cache_dir, hits,
                         misses, evictions, bytes_by_tag);

    PostToPlatformThread([dispatch, shared_reply, stats = std::move(stats)]() {
      if (!dispatch) return;
      {
        std::lock_guard<std::mutex> lock(dispatch->mu);
        if (!dispatch->alive) return;
      }
      (*shared_reply)(stats);
    });
  });
}

ErrorOr<WireCachePlatformCapabilities>
XueHuaNaviteCacheManagerPlugin::GetCapabilities() {
  return WireCachePlatformCapabilities(
      "windows", true, true, true, false,
      "LOCALAPPDATA/Temp + WinHTTP + Windows BCrypt", GetCacheRootDir(false));
}

}  // namespace xue_hua_navite_cache_manager
