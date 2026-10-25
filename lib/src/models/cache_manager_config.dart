import 'cache_eviction_policy.dart';

/// Global configuration for `XueHuaNaviteCacheManager`.
class CacheManagerConfig {
  /// Creates a [CacheManagerConfig].
  const CacheManagerConfig({
    this.maxDiskCacheBytes = 500 * 1024 * 1024, // 500 MB default
    this.maxEntries = 20000, // Supports 10,000+ entries out of the box
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
       assert(
         maxConcurrentDownloads > 0,
         'maxConcurrentDownloads must be positive',
       );

  /// Maximum total bytes stored on disk before automatic eviction is triggered.
  /// Defaults to 500 MB (`524,288,000` bytes).
  final int maxDiskCacheBytes;

  /// Maximum number of cached file entries before eviction is triggered.
  /// Defaults to `20000` to seamlessly support 10,000+ cached entries.
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
