import 'dart:async';
import 'dart:typed_data';

import 'cache_models.dart';
import 'pigeon_cache_backend.dart';

/// Internal backend abstraction decoupling [XueHuaNaviteCacheManager] between
/// Pigeon native interop / platform channel hosts and the browser Web backend.
abstract interface class CacheBackend {
  static CacheBackend? _instance;

  /// Active backend instance used by [XueHuaNaviteCacheManager].
  ///
  /// Defaults lazily to [PigeonCacheBackend] on IO platforms; on Web,
  /// `XueHuaNaviteCacheManagerWeb.registerWith` installs the browser backend.
  static CacheBackend get instance => _instance ??= PigeonCacheBackend();

  /// Replaces the active backend instance (used by Web registration and tests).
  static set instance(CacheBackend value) => _instance = value;

  /// Stream of real-time download progress and cache lifecycle events.
  Stream<CacheProgressEvent> get progressStream;

  /// Configures global cache quotas, eviction policy, timeouts, and headers.
  Future<void> configure(CacheManagerConfig config);

  /// Fetches or retrieves a file according to [request].
  Future<CacheFetchResult> downloadFile(CacheRequest request);

  /// Prefetches multiple [requests] concurrently.
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests);

  /// Cancels an active download identified by [keyOrUrl].
  Future<bool> cancelDownload(String keyOrUrl);

  /// Looks up a cached entry by [keyOrUrl] without making a network request.
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  });

  /// Reads raw bytes for a cached entry identified by [keyOrUrl].
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  });

  /// Checks whether a valid cached entry exists for [keyOrUrl].
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true});

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
  });

  /// Copies an existing local file at [sourceFilePath] into the cache under [key].
  Future<CacheEntry> putFile({
    required String key,
    required String sourceFilePath,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  });

  /// Sets or clears the `pinned` flag on an existing entry identified by [keyOrUrl].
  Future<bool> setPinned(String keyOrUrl, {required bool pinned});

  /// Removes a single cached file and its metadata entry by [keyOrUrl].
  Future<bool> removeFile(String keyOrUrl);

  /// Removes all cached entries assigned to [tag].
  Future<int> removeByTag(String tag);

  /// Purges all expired entries from the cache.
  Future<int> removeExpired();

  /// Trims the cache until total size is at or below [maxBytes].
  Future<int> trimToSize(int maxBytes);

  /// Clears all entries in the cache (optionally keeping pinned entries).
  Future<int> clearAll({bool includePinned = true});

  /// Lists entries tracked in the cache index.
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  });

  /// Retrieves live cache metrics and per-tag byte totals.
  Future<CacheStats> getStats();

  /// Queries platform-specific caching capabilities and storage details.
  Future<CachePlatformCapabilities> getCapabilities();
}
