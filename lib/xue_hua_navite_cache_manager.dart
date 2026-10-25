import 'dart:async';
import 'dart:typed_data';

import 'src/cache_hash_utils.dart';
import 'src/cache_models.dart';
import 'xue_hua_navite_cache_manager_platform_interface.dart';

export 'src/cache_models.dart';
export 'src/widgets/cached_network_image.dart';
export 'src/widgets/cached_network_image_provider.dart';

/// Cross-platform native network file cache manager for Flutter across
/// Android, iOS, macOS, Windows, Linux, and Web.
///
/// Provides automatic HTTP file caching, conditional ETag/Last-Modified (`304 Not Modified`)
/// revalidation, configurable LRU/LFU/FIFO/TTL disk eviction, MD5/SHA-256 checksum
/// verification, tag-based group invalidation, and real-time download progress streams.
class XueHuaNaviteCacheManager {
  /// Constructs a [XueHuaNaviteCacheManager] delegating to [XueHuaNaviteCacheManagerPlatform.instance].
  XueHuaNaviteCacheManager();

  /// Shared singleton instance of [XueHuaNaviteCacheManager].
  static final XueHuaNaviteCacheManager instance = XueHuaNaviteCacheManager();

  final Map<String, Future<CacheFetchResult>> _inFlightDownloads =
      <String, Future<CacheFetchResult>>{};

  XueHuaNaviteCacheManagerPlatform get _platform =>
      XueHuaNaviteCacheManagerPlatform.instance;

  /// Cache key shared by concurrent [downloadFile] calls.
  ///
  /// Matches the native resolver: a non-empty `customKey`, otherwise the
  /// SHA-256 of the URL. Callers that share this key observe one transfer.
  String _coalesceKey(CacheRequest request) {
    final String? custom = request.customKey?.trim();
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return CacheHashUtils.sha256String(request.url);
  }

  /// Broadcast stream of real-time download progress and cache lifecycle events.
  Stream<CacheProgressEvent> get progressStream => _platform.progressStream;

  /// Returns a filtered stream of [CacheProgressEvent] matching a specific [keyOrUrl].
  Stream<CacheProgressEvent> watchProgress(String keyOrUrl) {
    return progressStream.where(
      (event) => event.key == keyOrUrl || event.url == keyOrUrl,
    );
  }

  /// Configures global cache quotas, eviction policy, HTTP timeouts, and default headers.
  ///
  /// Call this once during application startup before issuing download requests.
  Future<void> configure(CacheManagerConfig config) {
    return _platform.configure(config);
  }

  /// Fetches a network file using [request] and returns a [CacheFetchResult] containing
  /// the resolved [CacheEntry], [CacheResultSource] (`cacheHit`, `revalidated`,
  /// `networkDownload`, or `staleCacheFallback`), HTTP status code, and elapsed duration.
  ///
  /// Concurrent calls that resolve to the same cache key share one in-flight
  /// download. The first request's options drive that transfer; every waiter
  /// receives the same result. Native implementations apply the same coalescing,
  /// so overlapping `prefetchAll` and [CachedNetworkImage] loads do not fetch twice.
  Future<CacheFetchResult> downloadFile(CacheRequest request) {
    final String key = _coalesceKey(request);
    final Future<CacheFetchResult>? existing = _inFlightDownloads[key];
    if (existing != null) {
      return existing;
    }
    late final Future<CacheFetchResult> future;
    future = _platform.downloadFile(request).whenComplete(() {
      if (identical(_inFlightDownloads[key], future)) {
        _inFlightDownloads.remove(key);
      }
    });
    _inFlightDownloads[key] = future;
    return future;
  }

  /// Convenience method that fetches or retrieves a cached network file from [url]
  /// and returns its [CacheEntry].
  ///
  /// Equivalent to calling [downloadFile] and extracting `result.entry`.
  Future<CacheEntry> getSingleFile(
    String url, {
    String? customKey,
    String? tag,
    String? fileExtension,
    Map<String, String> headers = const <String, String>{},
    int? ttlSeconds,
    bool forceRefresh = false,
    bool fallbackToCacheOnError = true,
    bool pinned = false,
    CacheChecksumAlgorithm checksumAlgorithm = CacheChecksumAlgorithm.none,
    String? expectedChecksum,
  }) async {
    final result = await downloadFile(
      CacheRequest(
        url: url,
        customKey: customKey,
        tag: tag,
        fileExtension: fileExtension,
        headers: headers,
        ttlSeconds: ttlSeconds,
        forceRefresh: forceRefresh,
        fallbackToCacheOnError: fallbackToCacheOnError,
        pinned: pinned,
        checksumAlgorithm: checksumAlgorithm,
        expectedChecksum: expectedChecksum,
      ),
    );
    return result.entry;
  }

  /// Prefetches a single [request] in the background and returns its [CacheEntry].
  Future<CacheEntry> prefetch(CacheRequest request) async {
    final result = await downloadFile(request);
    return result.entry;
  }

  /// Prefetches multiple [requests] concurrently in the background.
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) {
    if (requests.isEmpty) {
      return Future<List<CacheEntry>>.value(const <CacheEntry>[]);
    }
    return _platform.prefetchAll(requests);
  }

  /// Cancels an active in-flight network download by its [keyOrUrl].
  ///
  /// Returns `true` if an active download was found and canceled.
  Future<bool> cancelDownload(String keyOrUrl) {
    return _platform.cancelDownload(keyOrUrl);
  }

  /// Looks up a cached entry by [keyOrUrl] without making a network request.
  ///
  /// When [ignoreExpired] is `true` (default), returns `null` if the cached entry
  /// has passed its expiration timestamp.
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) {
    return _platform.getFileFromCache(keyOrUrl, ignoreExpired: ignoreExpired);
  }

  /// Reads the raw binary [Uint8List] of a cached entry by [keyOrUrl], or fetches
  /// it from the network first if [downloadIfMissing] is `true`.
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) {
    return _platform.readCacheBytes(keyOrUrl, ignoreExpired: ignoreExpired);
  }

  /// Checks whether a valid cached entry currently exists for [keyOrUrl].
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) {
    return _platform.containsKey(keyOrUrl, ignoreExpired: ignoreExpired);
  }

  /// Stores in-memory [bytes] directly into the cache under [key].
  Future<CacheEntry> putBytes({
    required String key,
    required Uint8List bytes,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) {
    return _platform.putBytes(
      key: key,
      bytes: bytes,
      url: url,
      fileExtension: fileExtension,
      mimeType: mimeType,
      tag: tag,
      ttlSeconds: ttlSeconds,
      pinned: pinned,
    );
  }

  /// Copies an existing local file at [sourceFilePath] into the managed cache under [key].
  Future<CacheEntry> putFile({
    required String key,
    required String sourceFilePath,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) {
    return _platform.putFile(
      key: key,
      sourceFilePath: sourceFilePath,
      url: url,
      fileExtension: fileExtension,
      mimeType: mimeType,
      tag: tag,
      ttlSeconds: ttlSeconds,
      pinned: pinned,
    );
  }

  /// Sets or clears the `pinned` flag on an existing cache entry identified by [keyOrUrl].
  ///
  /// Pinned entries are skipped during automatic quota eviction (`LRU`, `LFU`, `FIFO`).
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) {
    return _platform.setPinned(keyOrUrl, pinned: pinned);
  }

  /// Removes a single cached file and its metadata entry by [keyOrUrl].
  Future<bool> removeFile(String keyOrUrl) {
    return _platform.removeFile(keyOrUrl);
  }

  /// Removes all cached entries assigned to [tag] and returns the number of removed files.
  Future<int> removeByTag(String tag) {
    return _platform.removeByTag(tag);
  }

  /// Purges all expired entries from the cache and returns the count of removed files.
  Future<int> removeExpired() {
    return _platform.removeExpired();
  }

  /// Trims the cache using the configured eviction policy until total size is at or below [maxBytes].
  ///
  /// Returns the number of evicted entries.
  Future<int> trimToSize(int maxBytes) {
    return _platform.trimToSize(maxBytes);
  }

  /// Clears all entries in the cache.
  ///
  /// Set [includePinned] to `false` to preserve pinned entries.
  Future<int> clearAll({bool includePinned = true}) {
    return _platform.clearAll(includePinned: includePinned);
  }

  /// Lists all entries currently tracked in the cache index.
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) {
    return _platform.listEntries(tag: tag, includeExpired: includeExpired);
  }

  /// Retrieves live cache metrics including total bytes, hit/miss ratios, and per-tag breakdown.
  Future<CacheStats> getStats() {
    return _platform.getStats();
  }

  /// Queries platform-specific caching capabilities and underlying storage details.
  Future<CachePlatformCapabilities> getCapabilities() {
    return _platform.getCapabilities();
  }
}
