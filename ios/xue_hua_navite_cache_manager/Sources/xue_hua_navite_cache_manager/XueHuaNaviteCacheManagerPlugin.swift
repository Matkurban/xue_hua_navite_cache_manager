import CryptoKit
import Flutter
import Foundation
import UIKit

/// Native iOS implementation of `xue_hua_navite_cache_manager` using Pigeon Native Interop (FFI).
///
/// Uses `URLSession`, `CryptoKit` (`Insecure.MD5`, `SHA256`), and `FileManager` under
/// `.cachesDirectory` with `NSURLIsExcludedFromBackupKey`, O(1) running byte tracking,
/// and debounced background index persistence for 10,000+ cache entries.
///
/// Threading model:
/// - `cancelDownload` and `getCapabilities` are synchronous on the Pigeon FFI platform thread
///   and never touch `indexLock` or perform disk I/O.
/// - All other `CacheHostApi` methods are `@async`: Swift Concurrency suspends on
///   `withCheckedThrowingContinuation` while work runs on `queue` / `downloadScheduleQueue`.
/// - `CacheProgressFlutterApi.onProgress` events are dispatched FIFO through a bounded-free
///   serial `AsyncStream` consumer task so progress ordering is preserved across threads.
public class XueHuaNaviteCacheManagerPlugin:
  NSObject,
  FlutterPlugin,
  CacheHostApi,
  URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private weak var registrar: FlutterPluginRegistrar?
  private let queue = DispatchQueue(
    label: "com.kurban.xue_hua_navite_cache_manager.queue",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let persistQueue = DispatchQueue(
    label: "com.kurban.xue_hua_navite_cache_manager.persist",
    qos: .utility
  )
  /// Serial scheduler so download bookkeeping never blocks a GCD worker on the network.
  private let downloadScheduleQueue = DispatchQueue(
    label: "com.kurban.xue_hua_navite_cache_manager.download",
    qos: .userInitiated
  )

  /// Protects config scalars shared with synchronous `getCapabilities()` and session creation.
  private let configLock = NSLock()
  /// Protects `entries`, metrics, `indexLoaded`, and debounced index persistence.
  private let indexLock = NSLock()
  /// Protects only in-memory download coordination (tasks, permits, waiters, session).
  private let downloadLock = NSLock()

  private var pendingPersistWorkItem: DispatchWorkItem?
  private var progressContinuation: AsyncStream<WireCacheProgressEvent>.Continuation?
  private var progressTask: Task<Void, Never>?

  // Configuration
  private var maxDiskCacheBytes: Int64 = 500 * 1024 * 1024
  private var maxEntries: Int = 20000
  private var defaultTtlSeconds: Int64 = 7 * 24 * 3600
  private var evictionPolicy: String = "lru"
  private var cacheSubdirectory: String = "xue_hua_network_cache"
  private var maxConcurrentDownloads: Int = 4
  private var connectTimeoutMs: Int = 15000
  private var readTimeoutMs: Int = 30000
  private var defaultHeaders: [String: String] = [:]
  private var respectHttpCacheHeaders: Bool = true
  private var autoTrimOnWrite: Bool = true

  private struct CacheRecord: Codable {
    let key: String
    let url: String
    var filePath: String
    let sizeBytes: Int64
    let createdAtMs: Int64
    var lastAccessedAtMs: Int64
    var expiresAtMs: Int64
    var hitCount: Int64
    var tag: String?
    var mimeType: String?
    var eTag: String?
    var lastModified: String?
    var checksum: String?
    var checksumAlgorithm: String
    var pinned: Bool

    func isExpired(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
      return expiresAtMs > 0 && nowMs > expiresAtMs
    }

    func toWire() -> WireCacheEntry {
      return WireCacheEntry(
        key: key,
        url: url,
        filePath: filePath,
        sizeBytes: sizeBytes,
        createdAtMs: createdAtMs,
        lastAccessedAtMs: lastAccessedAtMs,
        expiresAtMs: expiresAtMs,
        hitCount: hitCount,
        tag: tag,
        mimeType: mimeType,
        eTag: eTag,
        lastModified: lastModified,
        checksum: checksum,
        checksumAlgorithm: WireCacheChecksumAlgorithm.fromString(checksumAlgorithm),
        pinned: pinned
      )
    }
  }

  private struct IndexContainer: Codable {
    var hitCount: Int64
    var missCount: Int64
    var evictionCount: Int64
    var entries: [CacheRecord]
  }

  private var entries: [String: CacheRecord] = [:]
  private var totalCachedBytes: Int64 = 0
  private var hitCount: Int64 = 0
  private var missCount: Int64 = 0
  private var evictionCount: Int64 = 0
  private var indexLoaded: Bool = false

  /// Same-key downloads share one URLSession task; every waiter is completed together.
  private final class InFlightDownload {
    var waiters: [(Result<WireCacheFetchResult, Error>) -> Void] = []
    var task: URLSessionTask?
    var canceled = false
    var watchdog: DispatchWorkItem?
    /// Temp file moved out of URLSession's download location before that callback returns.
    var partialFilePath: String?
    var httpResponse: HTTPURLResponse?
    var lastProgressEmitMs: Int64 = 0
  }

  private struct NetworkDownloadContext: @unchecked Sendable {
    let startMs: Int64
    let urlString: String
    let key: String
    let tag: String?
    let fileExtension: String?
    let ttlOverride: Int64?
    let fallbackToCacheOnError: Bool
    let pinned: Bool
    let checksumAlgorithm: WireCacheChecksumAlgorithm
    let expectedChecksum: String?
    let existingRecord: CacheRecord?
    let urlRequest: URLRequest
  }

  private var inFlightDownloads: [String: InFlightDownload] = [:]
  private var downloadContexts: [String: NetworkDownloadContext] = [:]
  private var taskKeys: [Int: String] = [:]
  /// Keys that currently hold a download-pool permit, so completion is exactly-once.
  private var permitKeys: Set<String> = []
  private var inUseDownloadPermits: Int = 0
  private var pendingDownloadStarts: [() -> Void] = []
  private var downloadSessionStorage: URLSession?

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
    startProgressConsumer()
  }

  deinit {
    progressTask?.cancel()
    progressContinuation?.finish()
    downloadSessionStorage?.invalidateAndCancel()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = XueHuaNaviteCacheManagerPlugin(registrar: registrar)
    registrar.publish(instance)
    CacheHostApiSetup.register(api: instance, registrar: registrar)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    CacheHostApiSetup.unregister(api: self, registrar: registrar)
    progressTask?.cancel()
    progressContinuation?.finish()
    self.registrar = nil
  }

  private func startProgressConsumer() {
    var capturedContinuation: AsyncStream<WireCacheProgressEvent>.Continuation?
    let stream = AsyncStream<WireCacheProgressEvent>(bufferingPolicy: .unbounded) { continuation in
      capturedContinuation = continuation
    }
    self.progressContinuation = capturedContinuation
    self.progressTask = Task.detached(priority: .utility) { [weak self] in
      for await event in stream {
        if Task.isCancelled { break }
        guard let self, let registrar = self.registrar,
              let flutterApi = CacheProgressFlutterApiRegistrar.getInstance(registrar: registrar) else {
          continue
        }
        try? await flutterApi.onProgress(event: event)
      }
    }
  }

  private func emitProgress(
    key: String,
    url: String,
    state: WireCacheTransferState,
    bytesReceived: Int64,
    totalBytes: Int64,
    filePath: String? = nil,
    errorMessage: String? = nil
  ) {
    let event = WireCacheProgressEvent(
      key: key,
      url: url,
      state: state,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      filePath: filePath,
      errorMessage: errorMessage
    )
    progressContinuation?.yield(event)
  }

  private func resolveCacheRootURL(subdirectory: String? = nil) -> URL {
    let sub: String
    if let subdirectory {
      sub = subdirectory
    } else {
      configLock.lock()
      sub = cacheSubdirectory
      configLock.unlock()
    }
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent(sub, isDirectory: true)
  }

  private func getCacheRootURL() -> URL {
    var dir = resolveCacheRootURL()
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try? dir.setResourceValues(resourceValues)
    }
    return dir
  }

  private func getIndexURL(subdirectory: String? = nil) -> URL {
    return resolveCacheRootURL(subdirectory: subdirectory).appendingPathComponent("cache_index_v1.json")
  }

  private func ensureIndexLoaded() {
    _ = getCacheRootURL()
    indexLock.lock()
    defer { indexLock.unlock() }
    if indexLoaded { return }
    indexLoaded = true
    entries.removeAll()
    totalCachedBytes = 0
    let indexURL = getIndexURL()
    if let data = try? Data(contentsOf: indexURL),
       let container = try? JSONDecoder().decode(IndexContainer.self, from: data) {
      hitCount = container.hitCount
      missCount = container.missCount
      evictionCount = container.evictionCount
      for record in container.entries {
        if let validPath = resolveExistingFilePath(record) {
          var updated = record
          updated.filePath = validPath
          entries[updated.key] = updated
          totalCachedBytes += updated.sizeBytes
        }
      }
    }
    recoverOrphanedFilesOnDiskLocked()
  }

  private func resolveExistingFilePath(_ record: CacheRecord) -> String? {
    if FileManager.default.fileExists(atPath: record.filePath) {
      return record.filePath
    }
    let fileName = URL(fileURLWithPath: record.filePath).lastPathComponent
    if !fileName.isEmpty {
      let candidate = getCacheRootURL().appendingPathComponent(fileName).path
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func recoverOrphanedFilesOnDiskLocked() {
    let rootURL = getCacheRootURL()
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    var recoveredAny = false
    for fileURL in fileURLs {
      let fileName = fileURL.lastPathComponent
      if fileName == "cache_index_v1.json" || fileName.hasSuffix(".tmp") || fileName.hasSuffix(".partial") || fileName.hasSuffix(".json") {
        continue
      }
      let key = fileURL.deletingPathExtension().lastPathComponent
      if key.isEmpty || entries[key] != nil {
        continue
      }
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
      let size = Int64(values?.fileSize ?? 0)
      if size <= 0 { continue }
      let createdMs = Int64((values?.creationDate ?? Date()).timeIntervalSince1970 * 1000)
      let modifiedMs = Int64((values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000)
      let record = CacheRecord(
        key: key,
        url: "cached://\(key)",
        filePath: fileURL.path,
        sizeBytes: size,
        createdAtMs: createdMs,
        lastAccessedAtMs: modifiedMs,
        expiresAtMs: modifiedMs + defaultTtlSeconds * 1000,
        hitCount: 1,
        tag: "recovered",
        mimeType: "application/octet-stream",
        eTag: nil,
        lastModified: nil,
        checksum: nil,
        checksumAlgorithm: "none",
        pinned: false
      )
      entries[key] = record
      totalCachedBytes += size
      recoveredAny = true
    }
    if recoveredAny {
      schedulePersistIndexLocked(immediate: true)
    }
  }

  private func schedulePersistIndexLocked(immediate: Bool = false) {
    pendingPersistWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.flushIndexNow()
    }
    pendingPersistWorkItem = work
    if immediate {
      persistQueue.async(execute: work)
    } else {
      persistQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
  }

  private func flushIndexNow(subdirectory: String? = nil) {
    indexLock.lock()
    let container = IndexContainer(
      hitCount: hitCount,
      missCount: missCount,
      evictionCount: evictionCount,
      entries: Array(entries.values)
    )
    let targetSubdir = subdirectory
    indexLock.unlock()

    let rootURL = resolveCacheRootURL(subdirectory: targetSubdir)
    if !FileManager.default.fileExists(atPath: rootURL.path) {
      try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    let indexURL = getIndexURL(subdirectory: targetSubdir)
    if let data = try? JSONEncoder().encode(container) {
      try? data.write(to: indexURL, options: .atomic)
    }
  }

  private func computeHash(data: Data, algorithm: String) -> String {
    if algorithm.lowercased() == "md5" {
      let digest = Insecure.MD5.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    } else {
      let digest = SHA256.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  private func resolveKey(_ keyOrUrl: String, customKey: String? = nil) -> String {
    if let custom = customKey?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
      return custom
    }
    indexLock.lock()
    let exists = entries[keyOrUrl] != nil
    indexLock.unlock()
    if exists {
      return keyOrUrl
    }
    return computeHash(data: Data(keyOrUrl.utf8), algorithm: "sha256")
  }

  private func inferExtension(url: String, mimeType: String?, explicitExtension: String?) -> String {
    if let ext = explicitExtension?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")),
       !ext.isEmpty {
      return ext.lowercased()
    }
    if let parsed = URL(string: url) {
      let pathExt = parsed.pathExtension.lowercased()
      if !pathExt.isEmpty && pathExt.count <= 8 {
        return pathExt
      }
    }
    let cleanMime = mimeType?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch cleanMime {
    case "image/png": return "png"
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/webp": return "webp"
    case "image/gif": return "gif"
    case "image/svg+xml": return "svg"
    case "application/pdf": return "pdf"
    case "application/json": return "json"
    case "audio/mpeg", "audio/mp3": return "mp3"
    case "video/mp4": return "mp4"
    case "text/plain": return "txt"
    default: return "bin"
    }
  }

  private func parseMaxAgeSeconds(_ cacheControl: String?) -> Int64? {
    guard let cc = cacheControl else { return nil }
    let pattern = "max-age=(\\d+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let nsString = cc as NSString
    if let match = regex.firstMatch(in: cc, options: [], range: NSRange(location: 0, length: nsString.length)),
       match.numberOfRanges > 1 {
      let numStr = nsString.substring(with: match.range(at: 1))
      return Int64(numStr)
    }
    return nil
  }

  // MARK: - CacheHostApi

  func configure(config: WireCacheManagerConfig) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        self.ensureIndexLoaded()

        self.configLock.lock()
        let prevSubdir = self.cacheSubdirectory
        let trimmedSubdir = config.cacheSubdirectory.trimmingCharacters(in: .whitespaces)
        let nextSubdir = trimmedSubdir.isEmpty ? prevSubdir : trimmedSubdir
        let newConnectTimeout = max(1, Int(config.connectTimeoutMs))
        let newReadTimeout = max(1, Int(config.readTimeoutMs))
        self.connectTimeoutMs = newConnectTimeout
        self.readTimeoutMs = newReadTimeout
        self.configLock.unlock()

        if prevSubdir != nextSubdir {
          self.flushIndexNow(subdirectory: prevSubdir)
          self.configLock.lock()
          self.cacheSubdirectory = nextSubdir
          self.configLock.unlock()
        }

        self.indexLock.lock()
        self.maxDiskCacheBytes = config.maxDiskCacheBytes
        self.maxEntries = max(1, Int(config.maxEntries))
        self.defaultTtlSeconds = config.defaultTtlSeconds
        self.evictionPolicy = config.evictionPolicy.wireString
        self.defaultHeaders = config.defaultHeaders
        self.respectHttpCacheHeaders = config.respectHttpCacheHeaders
        self.autoTrimOnWrite = config.autoTrimOnWrite
        if prevSubdir != nextSubdir {
          self.indexLoaded = false
        }
        self.indexLock.unlock()

        self.updateMaxConcurrentDownloads(Int(config.maxConcurrentDownloads))

        if prevSubdir != nextSubdir {
          self.ensureIndexLoaded()
        }
        if config.autoTrimOnWrite {
          self.indexLock.lock()
          _ = self.enforceQuotaLocked(
            targetMaxBytes: self.maxDiskCacheBytes,
            protectedKey: nil,
            checkOnlyFastPath: false
          )
          self.schedulePersistIndexLocked()
          self.indexLock.unlock()
        }
        continuation.resume()
      }
    }
  }

  func downloadFile(request: WireCacheRequest) async throws -> WireCacheFetchResult {
    return try await withCheckedThrowingContinuation { continuation in
      downloadScheduleQueue.async {
        self.ensureIndexLoaded()
        self.executeDownload(request: request) { outcome in
          continuation.resume(with: outcome)
        }
      }
    }
  }

  func prefetchAll(requests: [WireCacheRequest]) async throws -> [WireCacheEntry] {
    if requests.isEmpty { return [] }
    return await withTaskGroup(of: (Int, WireCacheEntry?).self) { group in
      for (index, request) in requests.enumerated() {
        group.addTask {
          do {
            let result = try await self.downloadFile(request: request)
            return (index, result.entry)
          } catch {
            return (index, nil)
          }
        }
      }
      var slots: [WireCacheEntry?] = Array(repeating: nil, count: requests.count)
      for await (index, entry) in group {
        slots[index] = entry
      }
      return slots.compactMap { $0 }
    }
  }

  func cancelDownload(keyOrUrl: String) throws -> Bool {
    // Compute candidate hashed key without touching `indexLock` or disk I/O so sync calls
    // from the platform thread never stall behind background index loading or trimming.
    let hashedKey = computeHash(data: Data(keyOrUrl.utf8), algorithm: "sha256")
    downloadLock.lock()
    let flight = inFlightDownloads[hashedKey] ?? inFlightDownloads[keyOrUrl]
    if let flight {
      flight.canceled = true
      let task = flight.task
      downloadLock.unlock()
      task?.cancel()
      return true
    } else {
      downloadLock.unlock()
      return false
    }
  }

  func getFileFromCache(keyOrUrl: String, ignoreExpired: Bool) async throws -> WireCacheEntry? {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let key = self.resolveKey(keyOrUrl)

        self.indexLock.lock()
        guard var record = self.entries[key] else {
          self.missCount += 1
          self.indexLock.unlock()
          continuation.resume(returning: nil)
          return
        }
        guard FileManager.default.fileExists(atPath: record.filePath) else {
          self.entries.removeValue(forKey: key)
          self.totalCachedBytes = max(0, self.totalCachedBytes - record.sizeBytes)
          self.missCount += 1
          self.schedulePersistIndexLocked()
          self.indexLock.unlock()
          continuation.resume(returning: nil)
          return
        }
        if ignoreExpired && record.isExpired() {
          self.missCount += 1
          self.indexLock.unlock()
          continuation.resume(returning: nil)
          return
        }
        record.lastAccessedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        record.hitCount += 1
        self.entries[key] = record
        self.hitCount += 1
        self.schedulePersistIndexLocked()
        let wireEntry = record.toWire()
        self.indexLock.unlock()

        self.emitProgress(
          key: key,
          url: record.url,
          state: .cacheHit,
          bytesReceived: record.sizeBytes,
          totalBytes: record.sizeBytes,
          filePath: record.filePath
        )
        continuation.resume(returning: wireEntry)
      }
    }
  }

  func readCacheBytes(keyOrUrl: String, ignoreExpired: Bool) async throws -> [UInt8]? {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let key = self.resolveKey(keyOrUrl)

        var filePath: String?
        self.indexLock.lock()
        if var record = self.entries[key], (!ignoreExpired || !record.isExpired()),
           FileManager.default.fileExists(atPath: record.filePath) {
          record.lastAccessedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
          record.hitCount += 1
          self.entries[key] = record
          self.hitCount += 1
          self.schedulePersistIndexLocked()
          filePath = record.filePath
        } else {
          self.missCount += 1
        }
        self.indexLock.unlock()

        guard let path = filePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: Array(data))
      }
    }
  }

  func containsKey(keyOrUrl: String, ignoreExpired: Bool) async throws -> Bool {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let key = self.resolveKey(keyOrUrl)

        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        guard let record = self.entries[key], FileManager.default.fileExists(atPath: record.filePath) else {
          continuation.resume(returning: false)
          return
        }
        if ignoreExpired && record.isExpired() {
          continuation.resume(returning: false)
          return
        }
        continuation.resume(returning: true)
      }
    }
  }

  func putBytes(
    key: String,
    bytes: [UInt8],
    url: String?,
    fileExtension: String?,
    mimeType: String?,
    tag: String?,
    ttlSeconds: Int64?,
    pinned: Bool
  ) async throws -> WireCacheEntry {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
          continuation.resume(throwing: PigeonError(
            code: "INVALID_ARGS",
            message: "key and bytes are required",
            details: nil
          ))
          return
        }

        let data = Data(bytes)
        let resolvedUrl = url ?? "local://\(trimmedKey)"
        let resolvedMime = mimeType ?? "application/octet-stream"

        self.indexLock.lock()
        let effectiveTtl = ttlSeconds ?? self.defaultTtlSeconds
        let shouldAutoTrim = self.autoTrimOnWrite
        let targetMaxBytes = self.maxDiskCacheBytes
        self.indexLock.unlock()

        let ext = self.inferExtension(url: resolvedUrl, mimeType: resolvedMime, explicitExtension: fileExtension)
        let destURL = self.getCacheRootURL().appendingPathComponent("\(trimmedKey).\(ext)")
        do {
          try data.write(to: destURL, options: .atomic)
          let checksum = self.computeHash(data: data, algorithm: "sha256")
          let now = Int64(Date().timeIntervalSince1970 * 1000)
          let record = CacheRecord(
            key: trimmedKey,
            url: resolvedUrl,
            filePath: destURL.path,
            sizeBytes: Int64(data.count),
            createdAtMs: now,
            lastAccessedAtMs: now,
            expiresAtMs: now + effectiveTtl * 1000,
            hitCount: 1,
            tag: tag,
            mimeType: resolvedMime,
            eTag: nil,
            lastModified: nil,
            checksum: checksum,
            checksumAlgorithm: "sha256",
            pinned: pinned
          )
          self.indexLock.lock()
          if let previous = self.entries[trimmedKey] {
            self.totalCachedBytes = max(0, self.totalCachedBytes - previous.sizeBytes)
            if previous.filePath != destURL.path {
              try? FileManager.default.removeItem(atPath: previous.filePath)
            }
          }
          self.entries[trimmedKey] = record
          self.totalCachedBytes += record.sizeBytes
          if shouldAutoTrim {
            _ = self.enforceQuotaLocked(targetMaxBytes: targetMaxBytes, protectedKey: trimmedKey, checkOnlyFastPath: true)
          }
          self.schedulePersistIndexLocked()
          let wireEntry = record.toWire()
          self.indexLock.unlock()
          continuation.resume(returning: wireEntry)
        } catch {
          continuation.resume(throwing: PigeonError(
            code: "PUT_BYTES_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  func putFile(
    key: String,
    sourceFilePath: String,
    url: String?,
    fileExtension: String?,
    mimeType: String?,
    tag: String?,
    ttlSeconds: Int64?,
    pinned: Bool
  ) async throws -> WireCacheEntry {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath = sourceFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              FileManager.default.fileExists(atPath: sourcePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) else {
          continuation.resume(throwing: PigeonError(
            code: "INVALID_SOURCE",
            message: "Source file does not exist",
            details: nil
          ))
          return
        }

        let resolvedUrl = url ?? "file://\(sourcePath)"
        let resolvedExt = fileExtension ?? URL(fileURLWithPath: sourcePath).pathExtension
        let resolvedMime = mimeType ?? "application/octet-stream"

        self.indexLock.lock()
        let effectiveTtl = ttlSeconds ?? self.defaultTtlSeconds
        let shouldAutoTrim = self.autoTrimOnWrite
        let targetMaxBytes = self.maxDiskCacheBytes
        self.indexLock.unlock()

        let ext = self.inferExtension(url: resolvedUrl, mimeType: resolvedMime, explicitExtension: resolvedExt)
        let destURL = self.getCacheRootURL().appendingPathComponent("\(trimmedKey).\(ext)")
        do {
          try data.write(to: destURL, options: .atomic)
          let checksum = self.computeHash(data: data, algorithm: "sha256")
          let now = Int64(Date().timeIntervalSince1970 * 1000)
          let record = CacheRecord(
            key: trimmedKey,
            url: resolvedUrl,
            filePath: destURL.path,
            sizeBytes: Int64(data.count),
            createdAtMs: now,
            lastAccessedAtMs: now,
            expiresAtMs: now + effectiveTtl * 1000,
            hitCount: 1,
            tag: tag,
            mimeType: resolvedMime,
            eTag: nil,
            lastModified: nil,
            checksum: checksum,
            checksumAlgorithm: "sha256",
            pinned: pinned
          )
          self.indexLock.lock()
          if let previous = self.entries[trimmedKey] {
            self.totalCachedBytes = max(0, self.totalCachedBytes - previous.sizeBytes)
            if previous.filePath != destURL.path {
              try? FileManager.default.removeItem(atPath: previous.filePath)
            }
          }
          self.entries[trimmedKey] = record
          self.totalCachedBytes += record.sizeBytes
          if shouldAutoTrim {
            _ = self.enforceQuotaLocked(targetMaxBytes: targetMaxBytes, protectedKey: trimmedKey, checkOnlyFastPath: true)
          }
          self.schedulePersistIndexLocked()
          let wireEntry = record.toWire()
          self.indexLock.unlock()
          continuation.resume(returning: wireEntry)
        } catch {
          continuation.resume(throwing: PigeonError(
            code: "PUT_FILE_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  func setPinned(keyOrUrl: String, pinned: Bool) async throws -> Bool {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let key = self.resolveKey(keyOrUrl)

        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        guard var record = self.entries[key] else {
          continuation.resume(returning: false)
          return
        }
        record.pinned = pinned
        self.entries[key] = record
        self.schedulePersistIndexLocked()
        continuation.resume(returning: true)
      }
    }
  }

  func removeFile(keyOrUrl: String) async throws -> Bool {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let key = self.resolveKey(keyOrUrl)

        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        guard let removed = self.entries.removeValue(forKey: key) else {
          continuation.resume(returning: false)
          return
        }
        self.totalCachedBytes = max(0, self.totalCachedBytes - removed.sizeBytes)
        try? FileManager.default.removeItem(atPath: removed.filePath)
        self.schedulePersistIndexLocked()
        continuation.resume(returning: true)
      }
    }
  }

  func removeByTag(tag: String) async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        let matchingKeys = self.entries.values.filter { $0.tag == tag }.map { $0.key }
        for k in matchingKeys {
          if let removed = self.entries.removeValue(forKey: k) {
            self.totalCachedBytes = max(0, self.totalCachedBytes - removed.sizeBytes)
            try? FileManager.default.removeItem(atPath: removed.filePath)
          }
        }
        if !matchingKeys.isEmpty {
          self.schedulePersistIndexLocked()
        }
        continuation.resume(returning: Int64(matchingKeys.count))
      }
    }
  }

  func removeExpired() async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        let count = self.removeExpiredLocked()
        if count > 0 {
          self.schedulePersistIndexLocked()
        }
        continuation.resume(returning: Int64(count))
      }
    }
  }

  func trimToSize(maxBytes: Int64) async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        let evicted = self.enforceQuotaLocked(
          targetMaxBytes: maxBytes,
          protectedKey: nil,
          checkOnlyFastPath: false
        )
        if evicted > 0 {
          self.schedulePersistIndexLocked()
        }
        continuation.resume(returning: Int64(evicted))
      }
    }
  }

  func clearAll(includePinned: Bool) async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        let keys = self.entries.values.filter { includePinned || !$0.pinned }.map { $0.key }
        for k in keys {
          if let removed = self.entries.removeValue(forKey: k) {
            self.totalCachedBytes = max(0, self.totalCachedBytes - removed.sizeBytes)
            try? FileManager.default.removeItem(atPath: removed.filePath)
          }
        }
        self.schedulePersistIndexLocked(immediate: true)
        continuation.resume(returning: Int64(keys.count))
      }
    }
  }

  func listEntries(tag: String?, includeExpired: Bool) async throws -> [WireCacheEntry] {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        self.indexLock.lock()
        defer { self.indexLock.unlock() }
        let list = self.entries.values
          .filter { record in
            (tag == nil || record.tag == tag) && (includeExpired || !record.isExpired(nowMs: now))
          }
          .sorted { $0.lastAccessedAtMs > $1.lastAccessedAtMs }
          .map { $0.toWire() }
        continuation.resume(returning: list)
      }
    }
  }

  func getStats() async throws -> WireCacheStats {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.ensureIndexLoaded()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        self.indexLock.lock()
        var totalBytes: Int64 = 0
        var expiredCount: Int64 = 0
        var pinnedCount: Int64 = 0
        var bytesByTag: [String: Int64] = [:]

        for record in self.entries.values {
          totalBytes += record.sizeBytes
          if record.isExpired(nowMs: now) { expiredCount += 1 }
          if record.pinned { pinnedCount += 1 }
          let tagKey = (record.tag?.isEmpty == false) ? record.tag! : "untagged"
          bytesByTag[tagKey] = (bytesByTag[tagKey] ?? 0) + record.sizeBytes
        }
        self.totalCachedBytes = totalBytes

        let stats = WireCacheStats(
          totalEntries: Int64(self.entries.count),
          totalBytes: totalBytes,
          expiredEntries: expiredCount,
          pinnedEntries: pinnedCount,
          maxDiskCacheBytes: self.maxDiskCacheBytes,
          cacheDirectoryPath: self.resolveCacheRootURL().path,
          hitCount: self.hitCount,
          missCount: self.missCount,
          evictionCount: self.evictionCount,
          bytesByTag: bytesByTag
        )
        self.indexLock.unlock()
        continuation.resume(returning: stats)
      }
    }
  }

  func getCapabilities() throws -> WireCachePlatformCapabilities {
    return WireCachePlatformCapabilities(
      platformName: "ios",
      supportsFileSystemPaths: true,
      supportsConditionalHttpRevalidation: true,
      supportsNativeCryptoHash: true,
      supportsLowDiskSpaceNotifications: true,
      storageMechanism: "NSCachesDirectory (ExcludedFromBackup) + URLSession + Debounced Index",
      defaultCacheRootPath: resolveCacheRootURL().path
    )
  }

  // MARK: - Download Engine

  private func canceledDownloadError() -> PigeonError {
    return PigeonError(code: "CANCELED", message: "Download canceled", details: "-2")
  }

  /// Dedicated session. The first one is created on the main thread
  /// asynchronously: iOS `URLSession` init can `dispatch_sync` to main, so
  /// creating it with `DispatchQueue.main.sync` from the download queue
  /// deadlocks, and creating it on a bare GCD worker can abort CFNetwork.
  ///
  /// On device, delegate callbacks run on a serial background OperationQueue.
  /// On the simulator there is no session delegate: `dataTask` completion
  /// handlers are what call [finishNetworkDownload]. `httpMaximumConnectionsPerHost`
  /// is only a ceiling; [acquireDownloadPermit] enforces `maxConcurrentDownloads`.
  private func downloadSession() -> URLSession {
    downloadLock.lock()
    if let existing = downloadSessionStorage {
      downloadLock.unlock()
      return existing
    }
    downloadLock.unlock()
    let session = makeDownloadSession()
    downloadLock.lock()
    if let existing = downloadSessionStorage {
      downloadLock.unlock()
      session.invalidateAndCancel()
      return existing
    }
    downloadSessionStorage = session
    downloadLock.unlock()
    return session
  }

  private func makeDownloadSession() -> URLSession {
    configLock.lock()
    let connectMs = connectTimeoutMs
    let readMs = readTimeoutMs
    configLock.unlock()

    #if targetEnvironment(simulator)
    let config = URLSessionConfiguration.ephemeral
    config.tlsMaximumSupportedProtocolVersion = .TLSv12
    #else
    let config = URLSessionConfiguration.default
    #endif
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpMaximumConnectionsPerHost = 32
    config.waitsForConnectivity = false
    let requestSeconds = TimeInterval(max(1, connectMs)) / 1000.0
    let resourceSeconds = TimeInterval(max(1, connectMs + readMs)) / 1000.0
    config.timeoutIntervalForRequest = requestSeconds
    config.timeoutIntervalForResource = resourceSeconds
    #if targetEnvironment(simulator)
    return URLSession(configuration: config)
    #else
    let delegateQueue = OperationQueue()
    delegateQueue.name = "com.kurban.xue_hua_navite_cache_manager.download-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    #endif
  }

  private func updateMaxConcurrentDownloads(_ newValue: Int) {
    let value = max(1, newValue)
    downloadLock.lock()
    maxConcurrentDownloads = value
    var starters: [() -> Void] = []
    while inUseDownloadPermits < maxConcurrentDownloads && !pendingDownloadStarts.isEmpty {
      inUseDownloadPermits += 1
      starters.append(pendingDownloadStarts.removeFirst())
    }
    downloadLock.unlock()
    starters.forEach { $0() }
  }

  private func acquireDownloadPermit(_ body: @escaping () -> Void) {
    downloadLock.lock()
    if inUseDownloadPermits < maxConcurrentDownloads {
      inUseDownloadPermits += 1
      downloadLock.unlock()
      body()
    } else {
      pendingDownloadStarts.append(body)
      downloadLock.unlock()
    }
  }

  private func releaseDownloadPermit() {
    downloadLock.lock()
    inUseDownloadPermits = max(0, inUseDownloadPermits - 1)
    var next: (() -> Void)?
    if inUseDownloadPermits < maxConcurrentDownloads && !pendingDownloadStarts.isEmpty {
      inUseDownloadPermits += 1
      next = pendingDownloadStarts.removeFirst()
    }
    downloadLock.unlock()
    next?()
  }

  private func finishInFlight(key: String, outcome: Result<WireCacheFetchResult, Error>) {
    downloadLock.lock()
    let flight = inFlightDownloads.removeValue(forKey: key)
    downloadContexts.removeValue(forKey: key)
    let heldPermit = permitKeys.remove(key) != nil
    if let taskId = flight?.task?.taskIdentifier {
      taskKeys.removeValue(forKey: taskId)
    }
    let watchdog = flight?.watchdog
    downloadLock.unlock()

    watchdog?.cancel()
    flight?.waiters.forEach { $0(outcome) }
    if heldPermit {
      releaseDownloadPermit()
    }
  }

  private func executeDownload(
    request: WireCacheRequest,
    completion: @escaping (Result<WireCacheFetchResult, Error>) -> Void
  ) {
    let startMs = Int64(Date().timeIntervalSince1970 * 1000)
    let urlString = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !urlString.isEmpty, let requestURL = URL(string: urlString) else {
      completion(.failure(PigeonError(code: "INVALID_URL", message: "Invalid URL", details: "-1")))
      return
    }

    let expectedChecksum = request.expectedChecksum?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let key = resolveKey(urlString, customKey: request.customKey)

    indexLock.lock()
    if var found = entries[key], FileManager.default.fileExists(atPath: found.filePath),
       !request.forceRefresh && !found.isExpired(nowMs: startMs) {
      found.lastAccessedAtMs = startMs
      found.hitCount += 1
      if let tag = request.tag { found.tag = tag }
      if request.pinned { found.pinned = true }
      entries[key] = found
      hitCount += 1
      schedulePersistIndexLocked()
      let wireEntry = found.toWire()
      indexLock.unlock()

      emitProgress(
        key: key,
        url: urlString,
        state: .cacheHit,
        bytesReceived: found.sizeBytes,
        totalBytes: found.sizeBytes,
        filePath: found.filePath
      )
      completion(.success(WireCacheFetchResult(
        entry: wireEntry,
        source: .cacheHit,
        httpStatusCode: nil,
        elapsedMs: Int64(Date().timeIntervalSince1970 * 1000) - startMs
      )))
      return
    }

    var existingRecord: CacheRecord?
    if let found = entries[key], FileManager.default.fileExists(atPath: found.filePath) {
      existingRecord = found
    }
    let headersSnapshot = defaultHeaders
    let respectHttp = respectHttpCacheHeaders
    indexLock.unlock()

    downloadLock.lock()
    if let flight = inFlightDownloads[key] {
      flight.waiters.append(completion)
      downloadLock.unlock()
      return
    }
    let flight = InFlightDownload()
    flight.waiters.append(completion)
    inFlightDownloads[key] = flight
    downloadLock.unlock()

    indexLock.lock()
    missCount += 1
    indexLock.unlock()

    emitProgress(key: key, url: urlString, state: .started, bytesReceived: 0, totalBytes: -1)

    configLock.lock()
    let totalTimeoutSec = TimeInterval(connectTimeoutMs + readTimeoutMs) / 1000.0
    configLock.unlock()

    var urlRequest = URLRequest(url: requestURL)
    urlRequest.httpMethod = "GET"
    urlRequest.timeoutInterval = max(1, totalTimeoutSec)
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    #if targetEnvironment(simulator)
    urlRequest.assumesHTTP3Capable = false
    #endif
    for (headerName, headerValue) in headersSnapshot {
      urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
    }
    for (headerName, headerValue) in request.headers {
      urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
    }
    if respectHttp, let existing = existingRecord {
      if let eTag = existing.eTag, !eTag.isEmpty {
        urlRequest.setValue(eTag, forHTTPHeaderField: "If-None-Match")
      }
      if let lastMod = existing.lastModified, !lastMod.isEmpty {
        urlRequest.setValue(lastMod, forHTTPHeaderField: "If-Modified-Since")
      }
    }

    let context = NetworkDownloadContext(
      startMs: startMs,
      urlString: urlString,
      key: key,
      tag: request.tag,
      fileExtension: request.fileExtension,
      ttlOverride: request.ttlSeconds,
      fallbackToCacheOnError: request.fallbackToCacheOnError,
      pinned: request.pinned,
      checksumAlgorithm: request.checksumAlgorithm,
      expectedChecksum: expectedChecksum,
      existingRecord: existingRecord,
      urlRequest: urlRequest
    )
    acquireDownloadPermit { [weak self] in
      self?.startPermittedDownload(context)
    }
  }

  private func startPermittedDownload(_ context: NetworkDownloadContext) {
    configLock.lock()
    let timeoutSec = TimeInterval(max(1, connectTimeoutMs + readTimeoutMs)) / 1000.0 + 1
    configLock.unlock()

    let watchdog = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.downloadLock.lock()
      let task = self.inFlightDownloads[context.key]?.task
      let stillWaiting = self.inFlightDownloads[context.key] != nil
      self.downloadLock.unlock()
      guard stillWaiting else { return }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self else { return }
        self.downloadLock.lock()
        let waiting = self.inFlightDownloads[context.key] != nil
        self.downloadLock.unlock()
        guard waiting else { return }
        self.discardPartialFile(forKey: context.key)
        self.emitProgress(
          key: context.key,
          url: context.urlString,
          state: .failed,
          bytesReceived: 0,
          totalBytes: -1,
          errorMessage: "Download timed out"
        )
        self.finishInFlight(
          key: context.key,
          outcome: .failure(PigeonError(
            code: "NETWORK_ERROR",
            message: "Download timed out",
            details: "\(NSURLErrorTimedOut)"
          ))
        )
      }
      task?.cancel()
    }

    downloadLock.lock()
    permitKeys.insert(context.key)
    guard let flight = inFlightDownloads[context.key], !flight.canceled else {
      downloadLock.unlock()
      finishInFlight(key: context.key, outcome: .failure(canceledDownloadError()))
      return
    }
    downloadContexts[context.key] = context
    flight.watchdog = watchdog
    let sessionReady = downloadSessionStorage != nil
    downloadLock.unlock()

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSec, execute: watchdog)

    // First URLSession must be created on the main thread asynchronously (CFNetwork aborts
    // otherwise; DispatchQueue.main.sync from downloadScheduleQueue would deadlock).
    if Thread.isMainThread || sessionReady {
      resumeDownloadTask(context)
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.resumeDownloadTask(context)
      }
    }
  }

  private func resumeDownloadTask(_ context: NetworkDownloadContext) {
    #if targetEnvironment(simulator)
    resumeSimulatorDataDownload(context)
    #else
    resumeDelegateDownload(context)
    #endif
  }

#if targetEnvironment(simulator)
  private func resumeSimulatorDataDownload(_ context: NetworkDownloadContext) {
    let session = downloadSession()
    let task = session.dataTask(with: context.urlRequest) { [weak self] data, response, error in
      guard let self else { return }
      let body = data
      let received = response
      let failure = error
      self.downloadScheduleQueue.async {
        self.completeSimulatorDataDownload(
          context,
          data: body,
          response: received,
          error: failure
        )
      }
    }
    downloadLock.lock()
    guard let flight = inFlightDownloads[context.key], !flight.canceled else {
      downloadLock.unlock()
      task.cancel()
      finishInFlight(key: context.key, outcome: .failure(canceledDownloadError()))
      return
    }
    flight.task = task
    taskKeys[task.taskIdentifier] = context.key
    downloadLock.unlock()
    task.resume()
  }

  private func completeSimulatorDataDownload(
    _ context: NetworkDownloadContext,
    data: Data?,
    response: URLResponse?,
    error: Error?
  ) {
    downloadLock.lock()
    let waiting = inFlightDownloads[context.key] != nil
    downloadLock.unlock()
    guard waiting else { return }

    if let error {
      finishNetworkDownload(context, fileURL: nil, response: response, error: error)
      return
    }
    guard let data else {
      finishNetworkDownload(
        context,
        fileURL: nil,
        response: response,
        error: NSError(
          domain: "NETWORK_ERROR",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Empty response body"]
        )
      )
      return
    }

    let partial = getCacheRootURL().appendingPathComponent("\(context.key).partial")
    do {
      try? FileManager.default.removeItem(at: partial)
      try data.write(to: partial, options: .atomic)
    } catch {
      finishInFlight(
        key: context.key,
        outcome: .failure(PigeonError(
          code: "DISK_WRITE_ERROR",
          message: error.localizedDescription,
          details: "-4"
        ))
      )
      return
    }

    downloadLock.lock()
    let stillWaiting = inFlightDownloads[context.key] != nil
    if stillWaiting {
      inFlightDownloads[context.key]?.partialFilePath = partial.path
    }
    downloadLock.unlock()
    guard stillWaiting else {
      try? FileManager.default.removeItem(at: partial)
      return
    }
    finishNetworkDownload(context, fileURL: partial, response: response, error: nil)
    if FileManager.default.fileExists(atPath: partial.path) {
      try? FileManager.default.removeItem(atPath: partial.path)
    }
  }
#endif

#if !targetEnvironment(simulator)
  private func resumeDelegateDownload(_ context: NetworkDownloadContext) {
    let session = downloadSession()
    let task = session.downloadTask(with: context.urlRequest)
    downloadLock.lock()
    guard let flight = inFlightDownloads[context.key], !flight.canceled else {
      downloadLock.unlock()
      task.cancel()
      finishInFlight(key: context.key, outcome: .failure(canceledDownloadError()))
      return
    }
    flight.task = task
    taskKeys[task.taskIdentifier] = context.key
    downloadLock.unlock()
    task.resume()
  }
#endif

  private func lookupTaskKey(_ task: URLSessionTask) -> String? {
    downloadLock.lock()
    defer { downloadLock.unlock() }
    return taskKeys[task.taskIdentifier]
  }

  private func discardPartialFile(forKey key: String) {
    downloadLock.lock()
    let path = inFlightDownloads[key]?.partialFilePath
    downloadLock.unlock()
    if let path {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  private func finishNetworkDownload(
    _ context: NetworkDownloadContext,
    fileURL: URL?,
    response: URLResponse?,
    error: Error?
  ) {
    let key = context.key
    let urlString = context.urlString
    let existingRecord = context.existingRecord
    let httpResponse = response as? HTTPURLResponse

    if let err = error as NSError? {
      if err.code == NSURLErrorCancelled {
        emitProgress(
          key: key,
          url: urlString,
          state: .canceled,
          bytesReceived: 0,
          totalBytes: -1,
          errorMessage: "Download canceled"
        )
        finishInFlight(key: key, outcome: .failure(canceledDownloadError()))
        return
      }
      if context.fallbackToCacheOnError, let existing = existingRecord,
         FileManager.default.fileExists(atPath: existing.filePath) {
        finishInFlight(key: key, outcome: .success(WireCacheFetchResult(
          entry: existing.toWire(),
          source: .staleCacheFallback,
          httpStatusCode: nil,
          elapsedMs: Int64(Date().timeIntervalSince1970 * 1000) - context.startMs
        )))
        return
      }
      emitProgress(
        key: key,
        url: urlString,
        state: .failed,
        bytesReceived: 0,
        totalBytes: -1,
        errorMessage: err.localizedDescription
      )
      finishInFlight(
        key: key,
        outcome: .failure(PigeonError(
          code: "NETWORK_ERROR",
          message: err.localizedDescription,
          details: "\(err.code)"
        ))
      )
      return
    }

    let statusCode = httpResponse?.statusCode ?? 200
    if statusCode == 304, var existing = existingRecord {
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let cacheControl = httpResponse?.value(forHTTPHeaderField: "Cache-Control")

      indexLock.lock()
      let respectHttp = respectHttpCacheHeaders
      let fallbackTtl = defaultTtlSeconds
      let ttlSec = context.ttlOverride ?? (respectHttp ? parseMaxAgeSeconds(cacheControl) : nil) ?? fallbackTtl
      existing.lastAccessedAtMs = now
      existing.expiresAtMs = now + ttlSec * 1000
      existing.hitCount += 1
      if let newEtag = httpResponse?.value(forHTTPHeaderField: "ETag") { existing.eTag = newEtag }
      if let newLastMod = httpResponse?.value(forHTTPHeaderField: "Last-Modified") { existing.lastModified = newLastMod }
      if let tag = context.tag { existing.tag = tag }
      if context.pinned { existing.pinned = true }
      entries[key] = existing
      schedulePersistIndexLocked(immediate: true)
      let wireEntry = existing.toWire()
      indexLock.unlock()

      emitProgress(
        key: key,
        url: urlString,
        state: .cacheHit,
        bytesReceived: existing.sizeBytes,
        totalBytes: existing.sizeBytes,
        filePath: existing.filePath
      )
      finishInFlight(key: key, outcome: .success(WireCacheFetchResult(
        entry: wireEntry,
        source: .revalidated,
        httpStatusCode: 304,
        elapsedMs: now - context.startMs
      )))
      return
    }

    guard (200...299).contains(statusCode), let fileURL,
          FileManager.default.fileExists(atPath: fileURL.path) else {
      if context.fallbackToCacheOnError, let existing = existingRecord,
         FileManager.default.fileExists(atPath: existing.filePath) {
        finishInFlight(key: key, outcome: .success(WireCacheFetchResult(
          entry: existing.toWire(),
          source: .staleCacheFallback,
          httpStatusCode: Int64(statusCode),
          elapsedMs: Int64(Date().timeIntervalSince1970 * 1000) - context.startMs
        )))
        return
      }
      emitProgress(
        key: key,
        url: urlString,
        state: .failed,
        bytesReceived: 0,
        totalBytes: -1,
        errorMessage: "HTTP \(statusCode)"
      )
      finishInFlight(
        key: key,
        outcome: .failure(PigeonError(
          code: "HTTP_ERROR",
          message: "HTTP \(statusCode) for \(urlString)",
          details: "\(statusCode)"
        ))
      )
      return
    }

    let byteCount: Int64 = {
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? NSNumber else {
        return 0
      }
      return size.int64Value
    }()
    emitProgress(key: key, url: urlString, state: .inProgress, bytesReceived: byteCount, totalBytes: byteCount)

    var computedHash: String?
    if context.checksumAlgorithm != .none {
      let payloadData = (try? Data(contentsOf: fileURL)) ?? Data()
      let hash = computeHash(data: payloadData, algorithm: context.checksumAlgorithm.wireString)
      computedHash = hash
      if let expected = context.expectedChecksum, !expected.isEmpty, hash.lowercased() != expected {
        emitProgress(
          key: key,
          url: urlString,
          state: .failed,
          bytesReceived: byteCount,
          totalBytes: byteCount,
          errorMessage: "Checksum mismatch"
        )
        finishInFlight(
          key: key,
          outcome: .failure(PigeonError(
            code: "CHECKSUM_MISMATCH",
            message: "Checksum mismatch: expected \(expected), got \(hash)",
            details: "-3"
          ))
        )
        return
      }
    }

    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
    let ext = inferExtension(url: urlString, mimeType: contentType, explicitExtension: context.fileExtension)
    let destURL = getCacheRootURL().appendingPathComponent("\(key).\(ext)")
    do {
      if FileManager.default.fileExists(atPath: destURL.path) {
        try FileManager.default.removeItem(at: destURL)
      }
      try FileManager.default.moveItem(at: fileURL, to: destURL)
    } catch {
      finishInFlight(
        key: key,
        outcome: .failure(PigeonError(
          code: "DISK_WRITE_ERROR",
          message: error.localizedDescription,
          details: "-4"
        ))
      )
      return
    }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let cacheControl = httpResponse?.value(forHTTPHeaderField: "Cache-Control")

    indexLock.lock()
    let ttlSec = context.ttlOverride ?? (respectHttpCacheHeaders ? parseMaxAgeSeconds(cacheControl) : nil) ?? defaultTtlSeconds
    let record = CacheRecord(
      key: key,
      url: urlString,
      filePath: destURL.path,
      sizeBytes: byteCount,
      createdAtMs: now,
      lastAccessedAtMs: now,
      expiresAtMs: now + ttlSec * 1000,
      hitCount: 1,
      tag: context.tag,
      mimeType: contentType ?? "application/octet-stream",
      eTag: httpResponse?.value(forHTTPHeaderField: "ETag"),
      lastModified: httpResponse?.value(forHTTPHeaderField: "Last-Modified"),
      checksum: computedHash,
      checksumAlgorithm: context.checksumAlgorithm.wireString,
      pinned: context.pinned
    )
    if let old = entries[key] {
      totalCachedBytes = max(0, totalCachedBytes - old.sizeBytes)
      if old.filePath != destURL.path {
        try? FileManager.default.removeItem(atPath: old.filePath)
      }
    }
    entries[key] = record
    totalCachedBytes += record.sizeBytes
    if autoTrimOnWrite {
      _ = enforceQuotaLocked(targetMaxBytes: maxDiskCacheBytes, protectedKey: key, checkOnlyFastPath: true)
    }
    schedulePersistIndexLocked(immediate: true)
    let wireEntry = record.toWire()
    indexLock.unlock()

    emitProgress(
      key: key,
      url: urlString,
      state: .completed,
      bytesReceived: byteCount,
      totalBytes: byteCount,
      filePath: destURL.path
    )
    finishInFlight(key: key, outcome: .success(WireCacheFetchResult(
      entry: wireEntry,
      source: .networkDownload,
      httpStatusCode: Int64(statusCode),
      elapsedMs: Int64(Date().timeIntervalSince1970 * 1000) - context.startMs
    )))
  }

  private func removeExpiredLocked() -> Int {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let expiredKeys = entries.values.filter { !$0.pinned && $0.isExpired(nowMs: now) }.map { $0.key }
    for k in expiredKeys {
      if let removed = entries.removeValue(forKey: k) {
        totalCachedBytes = max(0, totalCachedBytes - removed.sizeBytes)
        try? FileManager.default.removeItem(atPath: removed.filePath)
      }
    }
    evictionCount += Int64(expiredKeys.count)
    return expiredKeys.count
  }

  private func enforceQuotaLocked(targetMaxBytes: Int64, protectedKey: String?, checkOnlyFastPath: Bool) -> Int {
    if checkOnlyFastPath && totalCachedBytes <= targetMaxBytes && entries.count <= maxEntries {
      return 0
    }

    var evicted = removeExpiredLocked()
    if evictionPolicy == "ttlOnly" {
      return evicted
    }

    if totalCachedBytes <= targetMaxBytes && entries.count <= maxEntries {
      return evicted
    }

    let candidates = entries.values
      .filter { !$0.pinned && $0.key != protectedKey }
      .sorted { a, b in
        switch evictionPolicy {
        case "lfu":
          if a.hitCount != b.hitCount { return a.hitCount < b.hitCount }
          return a.lastAccessedAtMs < b.lastAccessedAtMs
        case "fifo":
          return a.createdAtMs < b.createdAtMs
        default:
          return a.lastAccessedAtMs < b.lastAccessedAtMs
        }
      }

    for candidate in candidates {
      if totalCachedBytes <= targetMaxBytes && entries.count <= maxEntries {
        break
      }
      if let removed = entries.removeValue(forKey: candidate.key) {
        try? FileManager.default.removeItem(atPath: removed.filePath)
        totalCachedBytes = max(0, totalCachedBytes - removed.sizeBytes)
        evicted += 1
        evictionCount += 1
      }
    }
    return evicted
  }

  // MARK: - URLSessionDownloadDelegate

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let key = lookupTaskKey(downloadTask) else { return }
    let partial = getCacheRootURL().appendingPathComponent("\(key).partial")
    try? FileManager.default.removeItem(at: partial)
    do {
      // URLSession deletes `location` when this method returns.
      try FileManager.default.moveItem(at: location, to: partial)
    } catch {
      return
    }
    downloadLock.lock()
    if let flight = inFlightDownloads[key] {
      flight.partialFilePath = partial.path
      flight.httpResponse = downloadTask.response as? HTTPURLResponse
      downloadLock.unlock()
    } else {
      downloadLock.unlock()
      try? FileManager.default.removeItem(at: partial)
    }
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let key = lookupTaskKey(downloadTask) else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    downloadLock.lock()
    guard let flight = inFlightDownloads[key] else {
      downloadLock.unlock()
      return
    }
    let due = flight.lastProgressEmitMs == 0 || now - flight.lastProgressEmitMs >= 50
    if due {
      flight.lastProgressEmitMs = now
    }
    let url = downloadContexts[key]?.urlString
    downloadLock.unlock()
    guard due, let url else { return }
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1
    emitProgress(
      key: key,
      url: url,
      state: .inProgress,
      bytesReceived: totalBytesWritten,
      totalBytes: total
    )
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let key = lookupTaskKey(task) else { return }
    downloadLock.lock()
    let context = downloadContexts[key]
    let partialPath = inFlightDownloads[key]?.partialFilePath
    let storedResponse = inFlightDownloads[key]?.httpResponse
    let waiting = inFlightDownloads[key] != nil
    downloadLock.unlock()
    guard waiting else { return }
    let response = storedResponse ?? (task.response as? HTTPURLResponse)
    if let context {
      let fileURL = partialPath.map { URL(fileURLWithPath: $0) }
      finishNetworkDownload(context, fileURL: fileURL, response: response, error: error)
    } else {
      let nsError = error as NSError?
      finishInFlight(
        key: key,
        outcome: .failure(PigeonError(
          code: "NETWORK_ERROR",
          message: error?.localizedDescription ?? "Download failed",
          details: "\(nsError?.code ?? -1)"
        ))
      )
    }
    if let partialPath, FileManager.default.fileExists(atPath: partialPath) {
      try? FileManager.default.removeItem(atPath: partialPath)
    }
  }
}

private extension WireCacheChecksumAlgorithm {
  var wireString: String {
    switch self {
    case .none: return "none"
    case .md5: return "md5"
    case .sha256: return "sha256"
    }
  }

  static func fromString(_ raw: String) -> WireCacheChecksumAlgorithm {
    switch raw.lowercased() {
    case "md5": return .md5
    case "sha256": return .sha256
    default: return .none
    }
  }
}

private extension WireCacheEvictionPolicy {
  var wireString: String {
    switch self {
    case .lru: return "lru"
    case .lfu: return "lfu"
    case .fifo: return "fifo"
    case .ttlOnly: return "ttlOnly"
    }
  }
}
