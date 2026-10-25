/// Eviction strategy used when the cache exceeds its maximum disk byte quota.
enum CacheEvictionPolicy {
  /// Least Recently Used: evicts entries with the oldest `lastAccessedAt` timestamp first.
  lru('lru'),

  /// Least Frequently Used: evicts entries with the lowest `hitCount` first, breaking ties by `lastAccessedAt`.
  lfu('lfu'),

  /// First In, First Out: evicts entries with the oldest `createdAt` timestamp first.
  fifo('fifo'),

  /// Evicts only expired entries (where `expiresAt` is in the past).
  ttlOnly('ttlOnly');

  const CacheEvictionPolicy(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheEvictionPolicy] from its [wireValue], defaulting to [CacheEvictionPolicy.lru].
  static CacheEvictionPolicy fromWire(String? value) {
    for (final policy in CacheEvictionPolicy.values) {
      if (policy.wireValue == value) {
        return policy;
      }
    }
    return CacheEvictionPolicy.lru;
  }
}

/// Checksum algorithm used to verify downloaded or cached file integrity.
enum CacheChecksumAlgorithm {
  /// No checksum verification.
  none('none'),

  /// 128-bit MD5 digest (hex-encoded).
  md5('md5'),

  /// 256-bit SHA-256 digest (hex-encoded).
  sha256('sha256');

  const CacheChecksumAlgorithm(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheChecksumAlgorithm] from its [wireValue].
  static CacheChecksumAlgorithm fromWire(String? value) {
    for (final algorithm in CacheChecksumAlgorithm.values) {
      if (algorithm.wireValue == value) {
        return algorithm;
      }
    }
    return CacheChecksumAlgorithm.none;
  }
}

/// Origin of a returned [CacheFetchResult].
enum CacheResultSource {
  /// Loaded directly from local cache without network transfer.
  cacheHit('cacheHit'),

  /// Conditional HTTP request (`If-None-Match` / `If-Modified-Since`) returned `304 Not Modified`
  /// and refreshed the local entry's expiration timestamp.
  revalidated('revalidated'),

  /// Downloaded fresh content from the remote server and stored it in the cache.
  networkDownload('networkDownload'),

  /// Returned from existing local cache because a network revalidation attempt failed
  /// while `fallbackToCacheOnError` was enabled.
  staleCacheFallback('staleCacheFallback');

  const CacheResultSource(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheResultSource] from its [wireValue].
  static CacheResultSource fromWire(String? value) {
    for (final source in CacheResultSource.values) {
      if (source.wireValue == value) {
        return source;
      }
    }
    return CacheResultSource.networkDownload;
  }
}

/// Lifecycle status of a real-time [CacheProgressEvent].
enum CacheTransferState {
  /// Download or cache operation is queued or starting.
  started('started'),

  /// Bytes are actively being received and written to temporary storage.
  inProgress('inProgress'),

  /// File was already valid in cache or revalidated via HTTP 304.
  cacheHit('cacheHit'),

  /// Download finished, passed optional checksum verification, and was committed to cache.
  completed('completed'),

  /// Download was canceled by calling `cancelDownload`.
  canceled('canceled'),

  /// Download or verification failed.
  failed('failed');

  const CacheTransferState(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheTransferState] from its [wireValue].
  static CacheTransferState fromWire(String? value) {
    for (final state in CacheTransferState.values) {
      if (state.wireValue == value) {
        return state;
      }
    }
    return CacheTransferState.inProgress;
  }
}

/// Global configuration for [XueHuaNaviteCacheManager].
class CacheManagerConfig {
  /// Creates a [CacheManagerConfig].
  const CacheManagerConfig({
    this.maxDiskCacheBytes = 500 * 1024 * 1024, // 500 MB default
    this.maxEntries = 2000,
    this.defaultTtlSeconds = 7 * 24 * 3600, // 7 days default
    this.evictionPolicy = CacheEvictionPolicy.lru,
    this.cacheSubdirectory = 'xue_hua_network_cache',
    this.maxConcurrentDownloads = 4,
    this.connectTimeoutMs = 15000,
    this.readTimeoutMs = 30000,
    this.defaultHeaders = const <String, String>{},
    this.respectHttpCacheHeaders = true,
    this.autoTrimOnWrite = true,
  }) : assert(maxDiskCacheBytes > 0, 'maxDiskCacheBytes must be positive'),
       assert(maxEntries > 0, 'maxEntries must be positive'),
       assert(defaultTtlSeconds >= 0, 'defaultTtlSeconds must be non-negative'),
       assert(maxConcurrentDownloads > 0, 'maxConcurrentDownloads must be positive');

  /// Maximum total bytes stored on disk before automatic eviction is triggered.
  /// Defaults to 500 MB (`524,288,000` bytes).
  final int maxDiskCacheBytes;

  /// Maximum number of cached file entries before eviction is triggered.
  /// Defaults to `2000`.
  final int maxEntries;

  /// Default Time-To-Live (TTL) in seconds when a request does not specify a custom `ttl`
  /// and HTTP headers do not provide `Cache-Control: max-age`.
  /// Defaults to 7 days (`604,800` seconds).
  final int defaultTtlSeconds;

  /// Eviction algorithm used when the cache exceeds [maxDiskCacheBytes] or [maxEntries].
  final CacheEvictionPolicy evictionPolicy;

  /// Subdirectory inside the OS platform cache directory (or CacheStorage bucket name on Web).
  final String cacheSubdirectory;

  /// Maximum simultaneous network downloads allowed.
  final int maxConcurrentDownloads;

  /// HTTP connection timeout in milliseconds.
  final int connectTimeoutMs;

  /// HTTP socket read timeout in milliseconds.
  final int readTimeoutMs;

  /// Default HTTP headers attached to every network download request.
  final Map<String, String> defaultHeaders;

  /// Whether to parse `ETag`, `Last-Modified`, and `Cache-Control: max-age` headers
  /// from HTTP responses and perform conditional `304 Not Modified` revalidation.
  final bool respectHttpCacheHeaders;

  /// Whether to automatically run eviction ([evictionPolicy]) after storing a new file.
  final bool autoTrimOnWrite;

  /// Serializes this configuration to a map for platform channel transport.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'maxDiskCacheBytes': maxDiskCacheBytes,
      'maxEntries': maxEntries,
      'defaultTtlSeconds': defaultTtlSeconds,
      'evictionPolicy': evictionPolicy.wireValue,
      'cacheSubdirectory': cacheSubdirectory,
      'maxConcurrentDownloads': maxConcurrentDownloads,
      'connectTimeoutMs': connectTimeoutMs,
      'readTimeoutMs': readTimeoutMs,
      'defaultHeaders': defaultHeaders,
      'respectHttpCacheHeaders': respectHttpCacheHeaders,
      'autoTrimOnWrite': autoTrimOnWrite,
    };
  }

  /// Creates a copy of this configuration with selected fields replaced.
  CacheManagerConfig copyWith({
    int? maxDiskCacheBytes,
    int? maxEntries,
    int? defaultTtlSeconds,
    CacheEvictionPolicy? evictionPolicy,
    String? cacheSubdirectory,
    int? maxConcurrentDownloads,
    int? connectTimeoutMs,
    int? readTimeoutMs,
    Map<String, String>? defaultHeaders,
    bool? respectHttpCacheHeaders,
    bool? autoTrimOnWrite,
  }) {
    return CacheManagerConfig(
      maxDiskCacheBytes: maxDiskCacheBytes ?? this.maxDiskCacheBytes,
      maxEntries: maxEntries ?? this.maxEntries,
      defaultTtlSeconds: defaultTtlSeconds ?? this.defaultTtlSeconds,
      evictionPolicy: evictionPolicy ?? this.evictionPolicy,
      cacheSubdirectory: cacheSubdirectory ?? this.cacheSubdirectory,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      connectTimeoutMs: connectTimeoutMs ?? this.connectTimeoutMs,
      readTimeoutMs: readTimeoutMs ?? this.readTimeoutMs,
      defaultHeaders: defaultHeaders ?? this.defaultHeaders,
      respectHttpCacheHeaders:
          respectHttpCacheHeaders ?? this.respectHttpCacheHeaders,
      autoTrimOnWrite: autoTrimOnWrite ?? this.autoTrimOnWrite,
    );
  }
}

/// Request options for fetching and caching a network file.
class CacheRequest {
  /// Creates a [CacheRequest] for the given [url].
  const CacheRequest({
    required this.url,
    this.customKey,
    this.tag,
    this.fileExtension,
    this.headers = const <String, String>{},
    this.ttlSeconds,
    this.forceRefresh = false,
    this.fallbackToCacheOnError = true,
    this.pinned = false,
    this.checksumAlgorithm = CacheChecksumAlgorithm.none,
    this.expectedChecksum,
  });

  /// Remote HTTP or HTTPS URL of the file to download and cache.
  final String url;

  /// Optional custom cache key. If omitted, a deterministic SHA-256 key is derived from [url].
  final String? customKey;

  /// Optional logical group or category tag (e.g. `'avatars'`, `'audio'`, `'course_101'`)
  /// used for batch eviction via `removeByTag`.
  final String? tag;

  /// Optional file extension override (without leading dot, e.g. `'png'`, `'mp4'`, `'pdf'`).
  /// If omitted, inferred from the URL path or HTTP `Content-Type` header.
  final String? fileExtension;

  /// Request-specific HTTP headers merged on top of `CacheManagerConfig.defaultHeaders`.
  final Map<String, String> headers;

  /// Optional TTL override in seconds for this specific file.
  final int? ttlSeconds;

  /// When `true`, bypasses fresh cache lookup and forces a network download (or conditional
  /// revalidation if an ETag/Last-Modified token exists).
  final bool forceRefresh;

  /// When `true` (default), returns an expired cached file if the network download fails,
  /// enabling resilient offline-first behavior.
  final bool fallbackToCacheOnError;

  /// When `true`, marks the entry as pinned so automatic LRU/LFU/FIFO eviction skips it
  /// unless explicitly removed via `removeFile` or `clearAll(includePinned: true)`.
  final bool pinned;

  /// Optional checksum algorithm to verify the downloaded file before committing to cache.
  final CacheChecksumAlgorithm checksumAlgorithm;

  /// Expected lowercase hex digest matching [checksumAlgorithm].
  final String? expectedChecksum;

  /// Serializes this request to a map for platform channel transport.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'url': url,
      'customKey': customKey,
      'tag': tag,
      'fileExtension': fileExtension,
      'headers': headers,
      'ttlSeconds': ttlSeconds,
      'forceRefresh': forceRefresh,
      'fallbackToCacheOnError': fallbackToCacheOnError,
      'pinned': pinned,
      'checksumAlgorithm': checksumAlgorithm.wireValue,
      'expectedChecksum': expectedChecksum,
    };
  }
}

/// Metadata and local storage information for a cached file entry.
class CacheEntry {
  /// Constructs a [CacheEntry].
  const CacheEntry({
    required this.key,
    required this.url,
    required this.filePath,
    required this.sizeBytes,
    required this.createdAtMs,
    required this.lastAccessedAtMs,
    required this.expiresAtMs,
    required this.hitCount,
    this.tag,
    this.mimeType,
    this.eTag,
    this.lastModified,
    this.checksum,
    this.checksumAlgorithm = CacheChecksumAlgorithm.none,
    this.pinned = false,
  });

  /// Deserializes a [CacheEntry] from a platform channel map.
  factory CacheEntry.fromMap(Map<Object?, Object?> map) {
    return CacheEntry(
      key: (map['key'] as String?) ?? '',
      url: (map['url'] as String?) ?? '',
      filePath: (map['filePath'] as String?) ?? '',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ?? 0,
      lastAccessedAtMs: (map['lastAccessedAtMs'] as num?)?.toInt() ?? 0,
      expiresAtMs: (map['expiresAtMs'] as num?)?.toInt() ?? 0,
      hitCount: (map['hitCount'] as num?)?.toInt() ?? 0,
      tag: map['tag'] as String?,
      mimeType: map['mimeType'] as String?,
      eTag: map['eTag'] as String?,
      lastModified: map['lastModified'] as String?,
      checksum: map['checksum'] as String?,
      checksumAlgorithm: CacheChecksumAlgorithm.fromWire(
        map['checksumAlgorithm'] as String?,
      ),
      pinned: (map['pinned'] as bool?) ?? false,
    );
  }

  /// Unique cache key identifying this entry.
  final String key;

  /// Original source URL (or `'local://<key>'` for manually inserted entries).
  final String url;

  /// Absolute local filesystem path on native platforms, or a virtual/Blob URL on Web.
  final String filePath;

  /// File size in bytes.
  final int sizeBytes;

  /// Creation timestamp in milliseconds since Unix epoch.
  final int createdAtMs;

  /// Last access timestamp in milliseconds since Unix epoch.
  final int lastAccessedAtMs;

  /// Expiration timestamp in milliseconds since Unix epoch.
  final int expiresAtMs;

  /// Number of times this entry has been accessed from cache.
  final int hitCount;

  /// Optional logical category tag.
  final String? tag;

  /// Detected or HTTP-provided MIME type (e.g. `'image/png'`, `'application/pdf'`).
  final String? mimeType;

  /// HTTP `ETag` header stored for conditional `If-None-Match` revalidation.
  final String? eTag;

  /// HTTP `Last-Modified` header stored for conditional `If-Modified-Since` revalidation.
  final String? lastModified;

  /// Computed hex checksum of the stored file, if requested or calculated.
  final String? checksum;

  /// Checksum algorithm used to compute [checksum].
  final CacheChecksumAlgorithm checksumAlgorithm;

  /// Whether this entry is protected from automatic quota eviction.
  final bool pinned;

  /// Creation timestamp as a [DateTime].
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true).toLocal();

  /// Last access timestamp as a [DateTime].
  DateTime get lastAccessedAt =>
      DateTime.fromMillisecondsSinceEpoch(lastAccessedAtMs, isUtc: true).toLocal();

  /// Expiration timestamp as a [DateTime].
  DateTime get expiresAt =>
      DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true).toLocal();

  /// Returns `true` if the current time is past [expiresAtMs].
  bool get isExpired =>
      expiresAtMs > 0 && DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  /// Serializes this [CacheEntry] to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'key': key,
      'url': url,
      'filePath': filePath,
      'sizeBytes': sizeBytes,
      'createdAtMs': createdAtMs,
      'lastAccessedAtMs': lastAccessedAtMs,
      'expiresAtMs': expiresAtMs,
      'hitCount': hitCount,
      'tag': tag,
      'mimeType': mimeType,
      'eTag': eTag,
      'lastModified': lastModified,
      'checksum': checksum,
      'checksumAlgorithm': checksumAlgorithm.wireValue,
      'pinned': pinned,
    };
  }
}

/// Result of a `downloadFile` or `getSingleFile` operation.
class CacheFetchResult {
  /// Constructs a [CacheFetchResult].
  const CacheFetchResult({
    required this.entry,
    required this.source,
    this.httpStatusCode,
    this.elapsedMs = 0,
  });

  /// Deserializes a [CacheFetchResult] from a platform channel map.
  factory CacheFetchResult.fromMap(Map<Object?, Object?> map) {
    final entryMap =
        (map['entry'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    return CacheFetchResult(
      entry: CacheEntry.fromMap(entryMap),
      source: CacheResultSource.fromWire(map['source'] as String?),
      httpStatusCode: (map['httpStatusCode'] as num?)?.toInt(),
      elapsedMs: (map['elapsedMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// Metadata and file location of the cached entry.
  final CacheEntry entry;

  /// Indicates whether the file was served from cache, revalidated (304), or downloaded.
  final CacheResultSource source;

  /// HTTP status code if a network request was made (e.g. `200`, `304`), or `null` on pure cache hit.
  final int? httpStatusCode;

  /// Total time taken to resolve the request in milliseconds.
  final int elapsedMs;

  /// Convenience getter for the local file path (or Web Blob/Cache URI).
  String get filePath => entry.filePath;

  /// Serializes this result to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'entry': entry.toMap(),
      'source': source.wireValue,
      'httpStatusCode': httpStatusCode,
      'elapsedMs': elapsedMs,
    };
  }
}

/// Real-time download progress and cache lifecycle event emitted on `progressStream`.
class CacheProgressEvent {
  /// Constructs a [CacheProgressEvent].
  const CacheProgressEvent({
    required this.key,
    required this.url,
    required this.state,
    required this.bytesReceived,
    required this.totalBytes,
    this.filePath,
    this.errorMessage,
  });

  /// Deserializes a [CacheProgressEvent] from an event channel payload.
  factory CacheProgressEvent.fromMap(Map<Object?, Object?> map) {
    return CacheProgressEvent(
      key: (map['key'] as String?) ?? '',
      url: (map['url'] as String?) ?? '',
      state: CacheTransferState.fromWire(map['state'] as String?),
      bytesReceived: (map['bytesReceived'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? -1,
      filePath: map['filePath'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  /// Resolved cache key for this download.
  final String key;

  /// Source URL being fetched.
  final String url;

  /// Current transfer state.
  final CacheTransferState state;

  /// Number of bytes received so far.
  final int bytesReceived;

  /// Expected total bytes from `Content-Length`, or `-1` if unknown/chunked.
  final int totalBytes;

  /// Resolved file path once [state] reaches [CacheTransferState.completed] or [CacheTransferState.cacheHit].
  final String? filePath;

  /// Error description if [state] is [CacheTransferState.failed].
  final String? errorMessage;

  /// Normalized progress value between `0.0` and `1.0`, or `null` if [totalBytes] is unknown.
  double? get progress {
    if (state == CacheTransferState.completed ||
        state == CacheTransferState.cacheHit) {
      return 1.0;
    }
    if (totalBytes <= 0) {
      return null;
    }
    final ratio = bytesReceived / totalBytes;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  /// Serializes this event to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'key': key,
      'url': url,
      'state': state.wireValue,
      'bytesReceived': bytesReceived,
      'totalBytes': totalBytes,
      'filePath': filePath,
      'errorMessage': errorMessage,
    };
  }
}

/// Aggregated statistics and telemetry for the cache store.
class CacheStats {
  /// Constructs a [CacheStats].
  const CacheStats({
    required this.totalEntries,
    required this.totalBytes,
    required this.expiredEntries,
    required this.pinnedEntries,
    required this.maxDiskCacheBytes,
    required this.cacheDirectoryPath,
    required this.hitCount,
    required this.missCount,
    required this.evictionCount,
    required this.bytesByTag,
  });

  /// Deserializes [CacheStats] from a platform channel map.
  factory CacheStats.fromMap(Map<Object?, Object?> map) {
    final rawTags = map['bytesByTag'] as Map<Object?, Object?>?;
    final parsedTags = <String, int>{};
    if (rawTags != null) {
      for (final entry in rawTags.entries) {
        final k = entry.key?.toString();
        final v = (entry.value as num?)?.toInt();
        if (k != null && v != null) {
          parsedTags[k] = v;
        }
      }
    }
    return CacheStats(
      totalEntries: (map['totalEntries'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      expiredEntries: (map['expiredEntries'] as num?)?.toInt() ?? 0,
      pinnedEntries: (map['pinnedEntries'] as num?)?.toInt() ?? 0,
      maxDiskCacheBytes: (map['maxDiskCacheBytes'] as num?)?.toInt() ?? 0,
      cacheDirectoryPath: (map['cacheDirectoryPath'] as String?) ?? '',
      hitCount: (map['hitCount'] as num?)?.toInt() ?? 0,
      missCount: (map['missCount'] as num?)?.toInt() ?? 0,
      evictionCount: (map['evictionCount'] as num?)?.toInt() ?? 0,
      bytesByTag: parsedTags,
    );
  }

  /// Total number of cached files currently stored.
  final int totalEntries;

  /// Total disk or storage bytes occupied by cached files.
  final int totalBytes;

  /// Number of entries currently past their expiration timestamp.
  final int expiredEntries;

  /// Number of entries marked as `pinned`.
  final int pinnedEntries;

  /// Configured maximum cache quota in bytes.
  final int maxDiskCacheBytes;

  /// Absolute path to the active cache directory (or virtual storage identifier on Web).
  final String cacheDirectoryPath;

  /// Cumulative cache hits during the current session/index lifetime.
  final int hitCount;

  /// Cumulative cache misses during the current session/index lifetime.
  final int missCount;

  /// Cumulative number of entries evicted due to quota or TTL trimming.
  final int evictionCount;

  /// Breakdown of total bytes grouped by entry `tag` (untagged entries are grouped under `'untagged'`).
  final Map<String, int> bytesByTag;

  /// Fraction of [maxDiskCacheBytes] currently used (`0.0` to `1.0`).
  double get quotaUsageRatio {
    if (maxDiskCacheBytes <= 0) return 0.0;
    final ratio = totalBytes / maxDiskCacheBytes;
    return ratio > 1.0 ? 1.0 : (ratio < 0.0 ? 0.0 : ratio);
  }

  /// Cache hit rate between `0.0` and `1.0`.
  double get hitRate {
    final totalLookups = hitCount + missCount;
    if (totalLookups <= 0) return 0.0;
    return hitCount / totalLookups;
  }

  /// Serializes this [CacheStats] to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'totalEntries': totalEntries,
      'totalBytes': totalBytes,
      'expiredEntries': expiredEntries,
      'pinnedEntries': pinnedEntries,
      'maxDiskCacheBytes': maxDiskCacheBytes,
      'cacheDirectoryPath': cacheDirectoryPath,
      'hitCount': hitCount,
      'missCount': missCount,
      'evictionCount': evictionCount,
      'bytesByTag': bytesByTag,
    };
  }
}

/// Describes the runtime caching capabilities and storage characteristics of the host platform.
class CachePlatformCapabilities {
  /// Constructs a [CachePlatformCapabilities].
  const CachePlatformCapabilities({
    required this.platformName,
    required this.supportsFileSystemPaths,
    required this.supportsConditionalHttpRevalidation,
    required this.supportsNativeCryptoHash,
    required this.supportsLowDiskSpaceNotifications,
    required this.storageMechanism,
    required this.defaultCacheRootPath,
  });

  /// Deserializes [CachePlatformCapabilities] from a platform channel map.
  factory CachePlatformCapabilities.fromMap(Map<Object?, Object?> map) {
    return CachePlatformCapabilities(
      platformName: (map['platformName'] as String?) ?? 'unknown',
      supportsFileSystemPaths:
          (map['supportsFileSystemPaths'] as bool?) ?? true,
      supportsConditionalHttpRevalidation:
          (map['supportsConditionalHttpRevalidation'] as bool?) ?? true,
      supportsNativeCryptoHash:
          (map['supportsNativeCryptoHash'] as bool?) ?? true,
      supportsLowDiskSpaceNotifications:
          (map['supportsLowDiskSpaceNotifications'] as bool?) ?? false,
      storageMechanism: (map['storageMechanism'] as String?) ?? '',
      defaultCacheRootPath: (map['defaultCacheRootPath'] as String?) ?? '',
    );
  }

  /// Host operating system or runtime name (`'android'`, `'ios'`, `'macos'`, `'windows'`, `'linux'`, `'web'`).
  final String platformName;

  /// `true` on Android, iOS, macOS, Windows, and Linux where cached entries reside as native OS files;
  /// `false` on Web where entries are stored in browser `CacheStorage` / Blob URLs.
  final bool supportsFileSystemPaths;

  /// Whether `ETag` (`If-None-Match`) and `Last-Modified` (`If-Modified-Since`) HTTP 304 revalidation is supported.
  final bool supportsConditionalHttpRevalidation;

  /// Whether hardware/OS-accelerated MD5 and SHA-256 hashing is available.
  final bool supportsNativeCryptoHash;

  /// Whether the OS automatically purges unpinned cache files under extreme system storage pressure.
  final bool supportsLowDiskSpaceNotifications;

  /// Description of the underlying storage engine (e.g. `'NSCachesDirectory + URLSession'`, `'CacheStorage API + Blob URL'`).
  final String storageMechanism;

  /// Default root directory path or storage namespace used by the platform.
  final String defaultCacheRootPath;

  /// Serializes this [CachePlatformCapabilities] to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'platformName': platformName,
      'supportsFileSystemPaths': supportsFileSystemPaths,
      'supportsConditionalHttpRevalidation':
          supportsConditionalHttpRevalidation,
      'supportsNativeCryptoHash': supportsNativeCryptoHash,
      'supportsLowDiskSpaceNotifications': supportsLowDiskSpaceNotifications,
      'storageMechanism': storageMechanism,
      'defaultCacheRootPath': defaultCacheRootPath,
    };
  }
}
