import Cocoa
import CryptoKit
import FlutterMacOS
import Foundation

/// Native macOS implementation of `xue_hua_navite_cache_manager`.
///
/// Uses `URLSession`, Apple `CryptoKit` (`Insecure.MD5`, `SHA256`), and `FileManager` under
/// `~/Library/Caches/<BundleID>/` with atomic writes, O(1) running byte tracking,
/// immediate persistence on new downloads, container path recovery, and debounced background
/// index persistence for 10,000+ cache entries.
public class XueHuaNaviteCacheManagerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, URLSessionDownloadDelegate {
  private var eventSink: FlutterEventSink?
  private let queue = DispatchQueue(label: "com.kurban.xue_hua_navite_cache_manager.macos.queue", qos: .userInitiated, attributes: .concurrent)
  private let persistQueue = DispatchQueue(label: "com.kurban.xue_hua_navite_cache_manager.macos.persist", qos: .utility)
  /// Serial scheduler so download bookkeeping never blocks a GCD worker on the network.
  private let downloadScheduleQueue = DispatchQueue(label: "com.kurban.xue_hua_navite_cache_manager.macos.download", qos: .userInitiated)
  private let lock = NSLock()
  private var pendingPersistWorkItem: DispatchWorkItem?

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

    func toMap() -> [String: Any?] {
      return [
        "key": key,
        "url": url,
        "filePath": filePath,
        "sizeBytes": sizeBytes,
        "createdAtMs": createdAtMs,
        "lastAccessedAtMs": lastAccessedAtMs,
        "expiresAtMs": expiresAtMs,
        "hitCount": hitCount,
        "tag": tag,
        "mimeType": mimeType,
        "eTag": eTag,
        "lastModified": lastModified,
        "checksum": checksum,
        "checksumAlgorithm": checksumAlgorithm,
        "pinned": pinned,
      ]
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
    var waiters: [(Result<[String: Any?], Error>) -> Void] = []
    var task: URLSessionTask?
    var canceled = false
    var watchdog: DispatchWorkItem?
    /// Temp file moved out of URLSession's download location before that callback returns.
    var partialFilePath: String?
    var httpResponse: HTTPURLResponse?
    var lastProgressEmitMs: Int64 = 0
  }

  private var inFlightDownloads: [String: InFlightDownload] = [:]
  private var taskKeys: [Int: String] = [:]
  /// Keys that currently hold a download-pool permit, so completion is exactly-once.
  private var permitKeys: Set<String> = []
  private var inUseDownloadPermits: Int = 0
  private var pendingDownloadStarts: [() -> Void] = []
  private var downloadSessionStorage: URLSession?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "xue_hua_navite_cache_manager",
      binaryMessenger: registrar.messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "xue_hua_navite_cache_manager/events",
      binaryMessenger: registrar.messenger
    )
    let instance = XueHuaNaviteCacheManagerPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func emitProgress(
    key: String,
    url: String,
    state: String,
    bytesReceived: Int64,
    totalBytes: Int64,
    filePath: String? = nil,
    errorMessage: String? = nil
  ) {
    // Omit nil fields. A `[String: Any?]` payload bridges as NSNull and the iOS
    // event codec can throw an uncaught exception on the first progress event.
    var payload: [String: Any] = [
      "key": key,
      "url": url,
      "state": state,
      "bytesReceived": bytesReceived,
      "totalBytes": totalBytes,
    ]
    if let filePath {
      payload["filePath"] = filePath
    }
    if let errorMessage {
      payload["errorMessage"] = errorMessage
    }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  /// Drops nil values so method-channel maps stay in the standard codec's value set.
  private func flutterPayload(_ map: [String: Any?]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in map {
      guard let value else { continue }
      if let nested = value as? [String: Any?] {
        out[key] = flutterPayload(nested)
      } else {
        out[key] = value
      }
    }
    return out
  }

  private func getCacheRootURL() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let bundleId = Bundle.main.bundleIdentifier ?? "com.kurban.xue_hua_navite_cache_manager"
    let dir = base
      .appendingPathComponent(bundleId, isDirectory: true)
      .appendingPathComponent(cacheSubdirectory, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  private func getIndexURL() -> URL {
    return getCacheRootURL().appendingPathComponent("cache_index_v1.json")
  }

  private func ensureIndexLoaded() {
    lock.lock()
    defer { lock.unlock() }
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

  private func flushIndexNow() {
    lock.lock()
    let container = IndexContainer(
      hitCount: hitCount,
      missCount: missCount,
      evictionCount: evictionCount,
      entries: Array(entries.values)
    )
    let indexURL = getIndexURL()
    lock.unlock()
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
    lock.lock()
    let exists = entries[keyOrUrl] != nil
    lock.unlock()
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

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    ensureIndexLoaded()
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "configure":
      handleConfigure(args: args, result: result)
    case "downloadFile":
      downloadScheduleQueue.async { self.handleDownloadFile(args: args, result: result) }
    case "prefetchAll":
      downloadScheduleQueue.async { self.handlePrefetchAll(args: args, result: result) }
    case "cancelDownload":
      handleCancelDownload(args: args, result: result)
    case "getFileFromCache":
      handleGetFileFromCache(args: args, result: result)
    case "readCacheBytes":
      queue.async { self.handleReadCacheBytes(args: args, result: result) }
    case "containsKey":
      handleContainsKey(args: args, result: result)
    case "putBytes":
      queue.async { self.handlePutBytes(args: args, result: result) }
    case "putFile":
      queue.async { self.handlePutFile(args: args, result: result) }
    case "setPinned":
      handleSetPinned(args: args, result: result)
    case "removeFile":
      handleRemoveFile(args: args, result: result)
    case "removeByTag":
      handleRemoveByTag(args: args, result: result)
    case "removeExpired":
      handleRemoveExpired(result: result)
    case "trimToSize":
      handleTrimToSize(args: args, result: result)
    case "clearAll":
      handleClearAll(args: args, result: result)
    case "listEntries":
      handleListEntries(args: args, result: result)
    case "getStats":
      handleGetStats(result: result)
    case "getCapabilities":
      handleGetCapabilities(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleConfigure(args: [String: Any], result: @escaping FlutterResult) {
    let prevSubdir = cacheSubdirectory
    if let v = (args["maxDiskCacheBytes"] as? NSNumber)?.int64Value { maxDiskCacheBytes = v }
    if let v = (args["maxEntries"] as? NSNumber)?.intValue { maxEntries = v }
    if let v = (args["defaultTtlSeconds"] as? NSNumber)?.int64Value { defaultTtlSeconds = v }
    if let v = args["evictionPolicy"] as? String { evictionPolicy = v }
    if let v = args["cacheSubdirectory"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
      cacheSubdirectory = v
    }
    if let v = (args["maxConcurrentDownloads"] as? NSNumber)?.intValue {
      updateMaxConcurrentDownloads(v)
    }
    if let v = (args["connectTimeoutMs"] as? NSNumber)?.intValue { connectTimeoutMs = v }
    if let v = (args["readTimeoutMs"] as? NSNumber)?.intValue { readTimeoutMs = v }
    if let v = args["respectHttpCacheHeaders"] as? Bool { respectHttpCacheHeaders = v }
    if let v = args["autoTrimOnWrite"] as? Bool { autoTrimOnWrite = v }
    if let headers = args["defaultHeaders"] as? [String: String] { defaultHeaders = headers }

    if prevSubdir != cacheSubdirectory {
      flushIndexNow()
      lock.lock()
      indexLoaded = false
      lock.unlock()
      ensureIndexLoaded()
    }
    if autoTrimOnWrite {
      lock.lock()
      _ = enforceQuotaLocked(targetMaxBytes: maxDiskCacheBytes, protectedKey: nil, checkOnlyFastPath: false)
      schedulePersistIndexLocked()
      lock.unlock()
    }
    result(nil)
  }

  private func handleDownloadFile(args: [String: Any], result: @escaping FlutterResult) {
    executeDownload(args: args) { outcome in
      DispatchQueue.main.async {
        switch outcome {
        case .success(let map):
          result(self.flutterPayload(map))
        case .failure(let error as NSError):
          result(FlutterError(code: error.domain, message: error.localizedDescription, details: error.code))
        }
      }
    }
  }

  private struct NetworkDownloadContext {
    let startMs: Int64
    let urlString: String
    let key: String
    let tag: String?
    let fileExtension: String?
    let ttlOverride: Int64?
    let fallbackToCacheOnError: Bool
    let pinned: Bool
    let checksumAlgorithm: String
    let expectedChecksum: String?
    let existingRecord: CacheRecord?
    let urlRequest: URLRequest
  }

  private var downloadContexts: [String: NetworkDownloadContext] = [:]

  private func canceledDownloadError() -> NSError {
    NSError(domain: "CANCELED", code: -2, userInfo: [NSLocalizedDescriptionKey: "Download canceled"])
  }

  /// Dedicated session. Created on the main thread: iOS CFNetwork can abort if
  /// `URLSession` is first initialized on a GCD worker. The delegate queue is
  /// a background serial queue so file moves never block the UI isolate.
  /// `httpMaximumConnectionsPerHost` is only a ceiling; [acquireDownloadPermit]
  /// enforces `maxConcurrentDownloads`.
  private func downloadSession() -> URLSession {
    lock.lock()
    let existing = downloadSessionStorage
    lock.unlock()
    if let existing {
      return existing
    }
    let create = { () -> URLSession in
      self.lock.lock()
      if let existing = self.downloadSessionStorage {
        self.lock.unlock()
        return existing
      }
      self.lock.unlock()
      let session = self.makeDownloadSession()
      self.lock.lock()
      if let existing = self.downloadSessionStorage {
        self.lock.unlock()
        session.invalidateAndCancel()
        return existing
      }
      self.downloadSessionStorage = session
      self.lock.unlock()
      return session
    }
    if Thread.isMainThread {
      return create()
    }
    return DispatchQueue.main.sync(execute: create)
  }

  private func makeDownloadSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpMaximumConnectionsPerHost = 32
    config.waitsForConnectivity = false
    let requestSeconds = TimeInterval(max(1, connectTimeoutMs)) / 1000.0
    let resourceSeconds = TimeInterval(max(1, connectTimeoutMs + readTimeoutMs)) / 1000.0
    config.timeoutIntervalForRequest = requestSeconds
    config.timeoutIntervalForResource = resourceSeconds
    let delegateQueue = OperationQueue()
    delegateQueue.name = "com.kurban.xue_hua_navite_cache_manager.macos.download-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
  }

  private func updateMaxConcurrentDownloads(_ newValue: Int) {
    let value = max(1, newValue)
    lock.lock()
    maxConcurrentDownloads = value
    var starters: [() -> Void] = []
    while inUseDownloadPermits < maxConcurrentDownloads && !pendingDownloadStarts.isEmpty {
      inUseDownloadPermits += 1
      starters.append(pendingDownloadStarts.removeFirst())
    }
    lock.unlock()
    starters.forEach { $0() }
  }

  private func acquireDownloadPermit(_ body: @escaping () -> Void) {
    lock.lock()
    if inUseDownloadPermits < maxConcurrentDownloads {
      inUseDownloadPermits += 1
      lock.unlock()
      body()
    } else {
      pendingDownloadStarts.append(body)
      lock.unlock()
    }
  }

  private func releaseDownloadPermit() {
    lock.lock()
    inUseDownloadPermits = max(0, inUseDownloadPermits - 1)
    var next: (() -> Void)?
    if inUseDownloadPermits < maxConcurrentDownloads && !pendingDownloadStarts.isEmpty {
      inUseDownloadPermits += 1
      next = pendingDownloadStarts.removeFirst()
    }
    lock.unlock()
    next?()
  }

  private func finishInFlight(key: String, outcome: Result<[String: Any?], Error>) {
    lock.lock()
    let flight = inFlightDownloads.removeValue(forKey: key)
    downloadContexts.removeValue(forKey: key)
    let heldPermit = permitKeys.remove(key) != nil
    if let taskId = flight?.task?.taskIdentifier {
      taskKeys.removeValue(forKey: taskId)
    }
    let watchdog = flight?.watchdog
    lock.unlock()
    watchdog?.cancel()
    flight?.waiters.forEach { $0(outcome) }
    if heldPermit {
      releaseDownloadPermit()
    }
  }

  private func executeDownload(
    args: [String: Any],
    completion: @escaping (Result<[String: Any?], Error>) -> Void
  ) {
    let startMs = Int64(Date().timeIntervalSince1970 * 1000)
    guard let urlString = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let requestURL = URL(string: urlString) else {
      completion(.failure(NSError(domain: "INVALID_URL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
      return
    }

    let customKey = args["customKey"] as? String
    let tag = args["tag"] as? String
    let fileExtension = args["fileExtension"] as? String
    let ttlOverride = (args["ttlSeconds"] as? NSNumber)?.int64Value
    let forceRefresh = (args["forceRefresh"] as? Bool) ?? false
    let fallbackToCacheOnError = (args["fallbackToCacheOnError"] as? Bool) ?? true
    let pinned = (args["pinned"] as? Bool) ?? false
    let checksumAlgorithm = (args["checksumAlgorithm"] as? String) ?? "none"
    let expectedChecksum = (args["expectedChecksum"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let key = resolveKey(urlString, customKey: customKey)

    lock.lock()
    if var found = entries[key], FileManager.default.fileExists(atPath: found.filePath),
       !forceRefresh && !found.isExpired(nowMs: startMs) {
      found.lastAccessedAtMs = startMs
      found.hitCount += 1
      if let tag = tag { found.tag = tag }
      if pinned { found.pinned = true }
      entries[key] = found
      hitCount += 1
      schedulePersistIndexLocked()
      lock.unlock()
      emitProgress(key: key, url: urlString, state: "cacheHit", bytesReceived: found.sizeBytes, totalBytes: found.sizeBytes, filePath: found.filePath)
      completion(.success([
        "entry": found.toMap(),
        "source": "cacheHit",
        "httpStatusCode": nil,
        "elapsedMs": Int64(Date().timeIntervalSince1970 * 1000) - startMs,
      ]))
      return
    }

    if let flight = inFlightDownloads[key] {
      flight.waiters.append(completion)
      lock.unlock()
      return
    }

    var existingRecord: CacheRecord?
    if let found = entries[key], FileManager.default.fileExists(atPath: found.filePath) {
      existingRecord = found
    }
    missCount += 1
    let flight = InFlightDownload()
    flight.waiters.append(completion)
    inFlightDownloads[key] = flight
    lock.unlock()

    emitProgress(key: key, url: urlString, state: "started", bytesReceived: 0, totalBytes: -1)

    var urlRequest = URLRequest(url: requestURL)
    urlRequest.httpMethod = "GET"
    urlRequest.timeoutInterval = TimeInterval(connectTimeoutMs + readTimeoutMs) / 1000.0
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    for (headerName, headerValue) in defaultHeaders {
      urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
    }
    if let reqHeaders = args["headers"] as? [String: String] {
      for (headerName, headerValue) in reqHeaders {
        urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
      }
    }
    if respectHttpCacheHeaders, let existing = existingRecord {
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
      tag: tag,
      fileExtension: fileExtension,
      ttlOverride: ttlOverride,
      fallbackToCacheOnError: fallbackToCacheOnError,
      pinned: pinned,
      checksumAlgorithm: checksumAlgorithm,
      expectedChecksum: expectedChecksum,
      existingRecord: existingRecord,
      urlRequest: urlRequest
    )
    acquireDownloadPermit { [weak self] in
      self?.startPermittedDownload(context)
    }
  }

  private func startPermittedDownload(_ context: NetworkDownloadContext) {
    let session = downloadSession()
    lock.lock()
    permitKeys.insert(context.key)
    guard inFlightDownloads[context.key] != nil, inFlightDownloads[context.key]?.canceled == false else {
      lock.unlock()
      finishInFlight(key: context.key, outcome: .failure(canceledDownloadError()))
      return
    }
    downloadContexts[context.key] = context
    lock.unlock()

    // Do not call into URLSession while `lock` is held. Session startup can
    // hop to the main thread, and the main thread also takes `lock`.
    let task = session.downloadTask(with: context.urlRequest)

    lock.lock()
    guard let flight = inFlightDownloads[context.key], !flight.canceled else {
      lock.unlock()
      task.cancel()
      finishInFlight(key: context.key, outcome: .failure(canceledDownloadError()))
      return
    }
    flight.task = task
    taskKeys[task.taskIdentifier] = context.key
    let timeoutSec = TimeInterval(max(1, connectTimeoutMs + readTimeoutMs)) / 1000.0 + 1
    let watchdog = DispatchWorkItem { [weak self, weak task] in
      guard let self else { return }
      task?.cancel()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self else { return }
        self.lock.lock()
        let stillWaiting = self.inFlightDownloads[context.key] != nil
        self.lock.unlock()
        guard stillWaiting else { return }
        self.discardPartialFile(forKey: context.key)
        self.emitProgress(
          key: context.key,
          url: context.urlString,
          state: "failed",
          bytesReceived: 0,
          totalBytes: -1,
          errorMessage: "Download timed out"
        )
        self.finishInFlight(
          key: context.key,
          outcome: .failure(NSError(
            domain: "NETWORK_ERROR",
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Download timed out"]
          ))
        )
      }
    }
    flight.watchdog = watchdog
    lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSec, execute: watchdog)
    task.resume()
  }

  private func lookupTaskKey(_ task: URLSessionTask) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return taskKeys[task.taskIdentifier]
  }

  private func discardPartialFile(forKey key: String) {
    lock.lock()
    let path = inFlightDownloads[key]?.partialFilePath
    lock.unlock()
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
        emitProgress(key: key, url: urlString, state: "canceled", bytesReceived: 0, totalBytes: -1, errorMessage: "Download canceled")
        finishInFlight(key: key, outcome: .failure(canceledDownloadError()))
        return
      }
      if context.fallbackToCacheOnError, let existing = existingRecord, FileManager.default.fileExists(atPath: existing.filePath) {
        finishInFlight(key: key, outcome: .success([
          "entry": existing.toMap(),
          "source": "staleCacheFallback",
          "httpStatusCode": nil,
          "elapsedMs": Int64(Date().timeIntervalSince1970 * 1000) - context.startMs,
        ]))
        return
      }
      emitProgress(key: key, url: urlString, state: "failed", bytesReceived: 0, totalBytes: -1, errorMessage: err.localizedDescription)
      finishInFlight(
        key: key,
        outcome: .failure(NSError(domain: "NETWORK_ERROR", code: err.code, userInfo: [NSLocalizedDescriptionKey: err.localizedDescription]))
      )
      return
    }

    let statusCode = httpResponse?.statusCode ?? 200
    if statusCode == 304, var existing = existingRecord {
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let cacheControl = httpResponse?.value(forHTTPHeaderField: "Cache-Control")
      let ttlSec = context.ttlOverride ?? (respectHttpCacheHeaders ? parseMaxAgeSeconds(cacheControl) : nil) ?? defaultTtlSeconds
      existing.lastAccessedAtMs = now
      existing.expiresAtMs = now + ttlSec * 1000
      existing.hitCount += 1
      if let newEtag = httpResponse?.value(forHTTPHeaderField: "ETag") { existing.eTag = newEtag }
      if let newLastMod = httpResponse?.value(forHTTPHeaderField: "Last-Modified") { existing.lastModified = newLastMod }
      if let tag = context.tag { existing.tag = tag }
      if context.pinned { existing.pinned = true }

      lock.lock()
      entries[key] = existing
      schedulePersistIndexLocked(immediate: true)
      lock.unlock()

      emitProgress(key: key, url: urlString, state: "cacheHit", bytesReceived: existing.sizeBytes, totalBytes: existing.sizeBytes, filePath: existing.filePath)
      finishInFlight(key: key, outcome: .success([
        "entry": existing.toMap(),
        "source": "revalidated",
        "httpStatusCode": 304,
        "elapsedMs": now - context.startMs,
      ]))
      return
    }

    guard (200...299).contains(statusCode), let fileURL,
          FileManager.default.fileExists(atPath: fileURL.path) else {
      if context.fallbackToCacheOnError, let existing = existingRecord, FileManager.default.fileExists(atPath: existing.filePath) {
        finishInFlight(key: key, outcome: .success([
          "entry": existing.toMap(),
          "source": "staleCacheFallback",
          "httpStatusCode": statusCode,
          "elapsedMs": Int64(Date().timeIntervalSince1970 * 1000) - context.startMs,
        ]))
        return
      }
      emitProgress(key: key, url: urlString, state: "failed", bytesReceived: 0, totalBytes: -1, errorMessage: "HTTP \(statusCode)")
      finishInFlight(
        key: key,
        outcome: .failure(NSError(domain: "HTTP_ERROR", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode) for \(urlString)"]))
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
    emitProgress(key: key, url: urlString, state: "inProgress", bytesReceived: byteCount, totalBytes: byteCount)

    var computedHash: String?
    if context.checksumAlgorithm != "none" {
      let payloadData = (try? Data(contentsOf: fileURL)) ?? Data()
      let hash = computeHash(data: payloadData, algorithm: context.checksumAlgorithm)
      computedHash = hash
      if let expected = context.expectedChecksum, !expected.isEmpty, hash.lowercased() != expected {
        emitProgress(key: key, url: urlString, state: "failed", bytesReceived: byteCount, totalBytes: byteCount, errorMessage: "Checksum mismatch")
        finishInFlight(
          key: key,
          outcome: .failure(NSError(domain: "CHECKSUM_MISMATCH", code: -3, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch: expected \(expected), got \(hash)"]))
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
        outcome: .failure(NSError(domain: "DISK_WRITE_ERROR", code: -4, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
      )
      return
    }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let cacheControl = httpResponse?.value(forHTTPHeaderField: "Cache-Control")
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
      checksumAlgorithm: context.checksumAlgorithm,
      pinned: context.pinned
    )

    lock.lock()
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
    lock.unlock()

    emitProgress(key: key, url: urlString, state: "completed", bytesReceived: byteCount, totalBytes: byteCount, filePath: destURL.path)
    finishInFlight(key: key, outcome: .success([
      "entry": record.toMap(),
      "source": "networkDownload",
      "httpStatusCode": statusCode,
      "elapsedMs": Int64(Date().timeIntervalSince1970 * 1000) - context.startMs,
    ]))
  }

  private func handlePrefetchAll(args: [String: Any], result: @escaping FlutterResult) {
    let requests = args["requests"] as? [[String: Any]] ?? []
    if requests.isEmpty {
      DispatchQueue.main.async { result([]) }
      return
    }
    let group = DispatchGroup()
    let listLock = NSLock()
    var slots: [[String: Any]?] = Array(repeating: nil, count: requests.count)
    for (index, req) in requests.enumerated() {
      group.enter()
      executeDownload(args: req) { outcome in
        if case .success(let map) = outcome, let entry = map["entry"] as? [String: Any?] {
          listLock.lock()
          slots[index] = self.flutterPayload(entry)
          listLock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      result(slots.compactMap { $0 })
    }
  }

  private func handleCancelDownload(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let key = resolveKey(keyOrUrl)
    lock.lock()
    let flight = inFlightDownloads[key] ?? inFlightDownloads[keyOrUrl]
    if let flight = flight {
      flight.canceled = true
      let task = flight.task
      lock.unlock()
      task?.cancel()
      result(true)
    } else {
      lock.unlock()
      result(false)
    }
  }

  private func handleGetFileFromCache(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let ignoreExpired = args["ignoreExpired"] as? Bool ?? true
    let key = resolveKey(keyOrUrl)

    lock.lock()
    defer { lock.unlock() }
    guard var record = entries[key] else {
      missCount += 1
      result(nil)
      return
    }
    guard FileManager.default.fileExists(atPath: record.filePath) else {
      entries.removeValue(forKey: key)
      totalCachedBytes = max(0, totalCachedBytes - record.sizeBytes)
      missCount += 1
      schedulePersistIndexLocked()
      result(nil)
      return
    }
    if ignoreExpired && record.isExpired() {
      missCount += 1
      result(nil)
      return
    }
    record.lastAccessedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    record.hitCount += 1
    entries[key] = record
    hitCount += 1
    schedulePersistIndexLocked()
    emitProgress(key: key, url: record.url, state: "cacheHit", bytesReceived: record.sizeBytes, totalBytes: record.sizeBytes, filePath: record.filePath)
    result(flutterPayload(record.toMap()))
  }

  private func handleReadCacheBytes(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let ignoreExpired = args["ignoreExpired"] as? Bool ?? true
    let key = resolveKey(keyOrUrl)

    var filePath: String?
    lock.lock()
    if var record = entries[key], (!ignoreExpired || !record.isExpired()),
       FileManager.default.fileExists(atPath: record.filePath) {
      record.lastAccessedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
      record.hitCount += 1
      entries[key] = record
      hitCount += 1
      schedulePersistIndexLocked()
      filePath = record.filePath
    } else {
      missCount += 1
    }
    lock.unlock()

    guard let path = filePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      DispatchQueue.main.async { result(nil) }
      return
    }
    DispatchQueue.main.async {
      result(FlutterStandardTypedData(bytes: data))
    }
  }

  private func handleContainsKey(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let ignoreExpired = args["ignoreExpired"] as? Bool ?? true
    let key = resolveKey(keyOrUrl)

    lock.lock()
    defer { lock.unlock() }
    guard let record = entries[key], FileManager.default.fileExists(atPath: record.filePath) else {
      result(false)
      return
    }
    if ignoreExpired && record.isExpired() {
      result(false)
      return
    }
    result(true)
  }

  private func handlePutBytes(args: [String: Any], result: @escaping FlutterResult) {
    guard let key = (args["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
          let typedData = args["bytes"] as? FlutterStandardTypedData else {
      DispatchQueue.main.async {
        result(FlutterError(code: "INVALID_ARGS", message: "key and bytes are required", details: nil))
      }
      return
    }
    let data = typedData.data
    let url = (args["url"] as? String) ?? "local://\(key)"
    let fileExtension = args["fileExtension"] as? String
    let mimeType = (args["mimeType"] as? String) ?? "application/octet-stream"
    let tag = args["tag"] as? String
    let ttlSeconds = (args["ttlSeconds"] as? NSNumber)?.int64Value ?? defaultTtlSeconds
    let pinned = (args["pinned"] as? Bool) ?? false

    let ext = inferExtension(url: url, mimeType: mimeType, explicitExtension: fileExtension)
    let destURL = getCacheRootURL().appendingPathComponent("\(key).\(ext)")
    do {
      try data.write(to: destURL, options: .atomic)
      let checksum = computeHash(data: data, algorithm: "sha256")
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let record = CacheRecord(
        key: key,
        url: url,
        filePath: destURL.path,
        sizeBytes: Int64(data.count),
        createdAtMs: now,
        lastAccessedAtMs: now,
        expiresAtMs: now + ttlSeconds * 1000,
        hitCount: 1,
        tag: tag,
        mimeType: mimeType,
        eTag: nil,
        lastModified: nil,
        checksum: checksum,
        checksumAlgorithm: "sha256",
        pinned: pinned
      )
      lock.lock()
      if let previous = entries[key] {
        totalCachedBytes = max(0, totalCachedBytes - previous.sizeBytes)
      }
      entries[key] = record
      totalCachedBytes += record.sizeBytes
      if autoTrimOnWrite {
        _ = enforceQuotaLocked(targetMaxBytes: maxDiskCacheBytes, protectedKey: key, checkOnlyFastPath: true)
      }
      schedulePersistIndexLocked()
      lock.unlock()
      let payload = flutterPayload(record.toMap())
      DispatchQueue.main.async { result(payload) }
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(code: "PUT_BYTES_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func handlePutFile(args: [String: Any], result: @escaping FlutterResult) {
    guard let key = (args["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
          let sourcePath = (args["sourceFilePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          FileManager.default.fileExists(atPath: sourcePath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) else {
      DispatchQueue.main.async {
        result(FlutterError(code: "INVALID_SOURCE", message: "Source file does not exist", details: nil))
      }
      return
    }
    let url = (args["url"] as? String) ?? "file://\(sourcePath)"
    let fileExtension = (args["fileExtension"] as? String) ?? URL(fileURLWithPath: sourcePath).pathExtension
    let mimeType = (args["mimeType"] as? String) ?? "application/octet-stream"
    let tag = args["tag"] as? String
    let ttlSeconds = (args["ttlSeconds"] as? NSNumber)?.int64Value ?? defaultTtlSeconds
    let pinned = (args["pinned"] as? Bool) ?? false

    let ext = inferExtension(url: url, mimeType: mimeType, explicitExtension: fileExtension)
    let destURL = getCacheRootURL().appendingPathComponent("\(key).\(ext)")
    do {
      try data.write(to: destURL, options: .atomic)
      let checksum = computeHash(data: data, algorithm: "sha256")
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let record = CacheRecord(
        key: key,
        url: url,
        filePath: destURL.path,
        sizeBytes: Int64(data.count),
        createdAtMs: now,
        lastAccessedAtMs: now,
        expiresAtMs: now + ttlSeconds * 1000,
        hitCount: 1,
        tag: tag,
        mimeType: mimeType,
        eTag: nil,
        lastModified: nil,
        checksum: checksum,
        checksumAlgorithm: "sha256",
        pinned: pinned
      )
      lock.lock()
      if let previous = entries[key] {
        totalCachedBytes = max(0, totalCachedBytes - previous.sizeBytes)
      }
      entries[key] = record
      totalCachedBytes += record.sizeBytes
      if autoTrimOnWrite {
        _ = enforceQuotaLocked(targetMaxBytes: maxDiskCacheBytes, protectedKey: key, checkOnlyFastPath: true)
      }
      schedulePersistIndexLocked(immediate: true)
      lock.unlock()
      let payload = flutterPayload(record.toMap())
      DispatchQueue.main.async { result(payload) }
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(code: "PUT_FILE_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func handleSetPinned(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let pinned = args["pinned"] as? Bool ?? false
    let key = resolveKey(keyOrUrl)

    lock.lock()
    defer { lock.unlock() }
    guard var record = entries[key] else {
      result(false)
      return
    }
    record.pinned = pinned
    entries[key] = record
    schedulePersistIndexLocked(immediate: true)
    result(true)
  }

  private func handleRemoveFile(args: [String: Any], result: @escaping FlutterResult) {
    let keyOrUrl = args["keyOrUrl"] as? String ?? ""
    let key = resolveKey(keyOrUrl)

    lock.lock()
    defer { lock.unlock() }
    guard let removed = entries.removeValue(forKey: key) else {
      result(false)
      return
    }
    totalCachedBytes = max(0, totalCachedBytes - removed.sizeBytes)
    try? FileManager.default.removeItem(atPath: removed.filePath)
    schedulePersistIndexLocked(immediate: true)
    result(true)
  }

  private func handleRemoveByTag(args: [String: Any], result: @escaping FlutterResult) {
    let tag = args["tag"] as? String ?? ""
    lock.lock()
    defer { lock.unlock() }
    let matchingKeys = entries.values.filter { $0.tag == tag }.map { $0.key }
    for k in matchingKeys {
      if let removed = entries.removeValue(forKey: k) {
        totalCachedBytes = max(0, totalCachedBytes - removed.sizeBytes)
        try? FileManager.default.removeItem(atPath: removed.filePath)
      }
    }
    if !matchingKeys.isEmpty {
      schedulePersistIndexLocked(immediate: true)
    }
    result(matchingKeys.count)
  }

  private func handleRemoveExpired(result: @escaping FlutterResult) {
    lock.lock()
    defer { lock.unlock() }
    let count = removeExpiredLocked()
    if count > 0 {
      schedulePersistIndexLocked(immediate: true)
    }
    result(count)
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

  private func handleTrimToSize(args: [String: Any], result: @escaping FlutterResult) {
    let targetMax = (args["maxBytes"] as? NSNumber)?.int64Value ?? maxDiskCacheBytes
    lock.lock()
    defer { lock.unlock() }
    let evicted = enforceQuotaLocked(targetMaxBytes: targetMax, protectedKey: nil, checkOnlyFastPath: false)
    if evicted > 0 {
      schedulePersistIndexLocked(immediate: true)
    }
    result(evicted)
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

  private func handleClearAll(args: [String: Any], result: @escaping FlutterResult) {
    let includePinned = args["includePinned"] as? Bool ?? true
    lock.lock()
    defer { lock.unlock() }
    let keys = entries.values.filter { includePinned || !$0.pinned }.map { $0.key }
    for k in keys {
      if let removed = entries.removeValue(forKey: k) {
        totalCachedBytes = max(0, totalCachedBytes - removed.sizeBytes)
        try? FileManager.default.removeItem(atPath: removed.filePath)
      }
    }
    schedulePersistIndexLocked(immediate: true)
    result(keys.count)
  }

  private func handleListEntries(args: [String: Any], result: @escaping FlutterResult) {
    let tag = args["tag"] as? String
    let includeExpired = args["includeExpired"] as? Bool ?? true
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    lock.lock()
    defer { lock.unlock() }
    let list = entries.values
      .filter { record in
        (tag == nil || record.tag == tag) && (includeExpired || !record.isExpired(nowMs: now))
      }
      .sorted { $0.lastAccessedAtMs > $1.lastAccessedAtMs }
      .map { $0.toMap() }
    result(list)
  }

  private func handleGetStats(result: @escaping FlutterResult) {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    lock.lock()
    defer { lock.unlock() }

    var totalBytes: Int64 = 0
    var expiredCount = 0
    var pinnedCount = 0
    var bytesByTag: [String: Int64] = [:]

    for record in entries.values {
      totalBytes += record.sizeBytes
      if record.isExpired(nowMs: now) { expiredCount += 1 }
      if record.pinned { pinnedCount += 1 }
      let tagKey = (record.tag?.isEmpty == false) ? record.tag! : "untagged"
      bytesByTag[tagKey] = (bytesByTag[tagKey] ?? 0) + record.sizeBytes
    }
    totalCachedBytes = totalBytes

    result([
      "totalEntries": entries.count,
      "totalBytes": totalBytes,
      "expiredEntries": expiredCount,
      "pinnedEntries": pinnedCount,
      "maxDiskCacheBytes": maxDiskCacheBytes,
      "cacheDirectoryPath": getCacheRootURL().path,
      "hitCount": hitCount,
      "missCount": missCount,
      "evictionCount": evictionCount,
      "bytesByTag": bytesByTag,
    ])
  }

  private func handleGetCapabilities(result: @escaping FlutterResult) {
    result([
      "platformName": "macos",
      "supportsFileSystemPaths": true,
      "supportsConditionalHttpRevalidation": true,
      "supportsNativeCryptoHash": true,
      "supportsLowDiskSpaceNotifications": false,
      "storageMechanism": "~/Library/Caches/<BundleID> + URLSession + Debounced Index",
      "defaultCacheRootPath": getCacheRootURL().path,
    ])
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let key = lookupTaskKey(downloadTask) else { return }
    let partial = getCacheRootURL().appendingPathComponent("\(key).partial")
    try? FileManager.default.removeItem(at: partial)
    do {
      try FileManager.default.moveItem(at: location, to: partial)
    } catch {
      return
    }
    lock.lock()
    if let flight = inFlightDownloads[key] {
      flight.partialFilePath = partial.path
      flight.httpResponse = downloadTask.response as? HTTPURLResponse
      lock.unlock()
    } else {
      lock.unlock()
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
    lock.lock()
    guard let flight = inFlightDownloads[key] else {
      lock.unlock()
      return
    }
    let due = flight.lastProgressEmitMs == 0 || now - flight.lastProgressEmitMs >= 50
    if due {
      flight.lastProgressEmitMs = now
    }
    let url = downloadContexts[key]?.urlString
    lock.unlock()
    guard due, let url else { return }
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1
    emitProgress(
      key: key,
      url: url,
      state: "inProgress",
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
    lock.lock()
    let context = downloadContexts[key]
    let partialPath = inFlightDownloads[key]?.partialFilePath
    let storedResponse = inFlightDownloads[key]?.httpResponse
    lock.unlock()
    let response = storedResponse ?? (task.response as? HTTPURLResponse)
    if let context {
      let fileURL = partialPath.map { URL(fileURLWithPath: $0) }
      finishNetworkDownload(context, fileURL: fileURL, response: response, error: error)
    } else if inFlightStillWaiting(key) {
      finishInFlight(
        key: key,
        outcome: .failure(NSError(
          domain: "NETWORK_ERROR",
          code: (error as NSError?)?.code ?? -1,
          userInfo: [NSLocalizedDescriptionKey: error?.localizedDescription ?? "Download failed"]
        ))
      )
    }
    if let partialPath, FileManager.default.fileExists(atPath: partialPath) {
      try? FileManager.default.removeItem(atPath: partialPath)
    }
  }

  private func inFlightStillWaiting(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return inFlightDownloads[key] != nil
  }
}
