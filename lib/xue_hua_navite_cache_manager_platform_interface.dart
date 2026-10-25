import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/cache_models.dart';
import 'xue_hua_navite_cache_manager_method_channel.dart';

/// The interface that implementations of `xue_hua_navite_cache_manager` must implement.
///
/// Platform implementations should extend this class rather than implement it as
/// `xue_hua_navite_cache_manager` does not consider newly added methods to be breaking changes.
/// Extending this class (using `extends`) ensures that the subclass will get the
/// default implementation, while platform implementations that `implements` this
/// interface will be broken by newly added [XueHuaNaviteCacheManagerPlatform] methods.
abstract class XueHuaNaviteCacheManagerPlatform extends PlatformInterface {
  /// Constructs a [XueHuaNaviteCacheManagerPlatform].
  XueHuaNaviteCacheManagerPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteCacheManagerPlatform _instance =
      MethodChannelXueHuaNaviteCacheManager();

  /// The default instance of [XueHuaNaviteCacheManagerPlatform] to use.
  ///
  /// Defaults to [MethodChannelXueHuaNaviteCacheManager].
  static XueHuaNaviteCacheManagerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [XueHuaNaviteCacheManagerPlatform] when
  /// they register themselves.
  static set instance(XueHuaNaviteCacheManagerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Stream of real-time download progress and cache transfer events.
  Stream<CacheProgressEvent> get progressStream {
    throw UnimplementedError('progressStream has not been implemented.');
  }

  /// Configures global cache quotas, eviction policy, timeouts, and default headers.
  Future<void> configure(CacheManagerConfig config) {
    throw UnimplementedError('configure() has not been implemented.');
  }

  /// Downloads or retrieves a cached file for [request], returning rich [CacheFetchResult] metadata.
  Future<CacheFetchResult> downloadFile(CacheRequest request) {
    throw UnimplementedError('downloadFile() has not been implemented.');
  }

  /// Prefetches a list of [requests] in the background and returns the resolved [CacheEntry] items.
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) {
    throw UnimplementedError('prefetchAll() has not been implemented.');
  }

  /// Cancels an active download identified by its [keyOrUrl].
  /// Returns `true` if an in-flight download was found and canceled.
  Future<bool> cancelDownload(String keyOrUrl) {
    throw UnimplementedError('cancelDownload() has not been implemented.');
  }

  /// Looks up an existing cached entry by [keyOrUrl] without triggering a network download.
  /// If [ignoreExpired] is `true` (default), returns `null` when the entry is expired.
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) {
    throw UnimplementedError('getFileFromCache() has not been implemented.');
  }

  /// Reads the raw binary bytes of a cached entry identified by [keyOrUrl].
  /// Returns `null` if the entry does not exist or is expired.
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) {
    throw UnimplementedError('readCacheBytes() has not been implemented.');
  }

  /// Returns `true` if a valid (non-expired) cached entry exists for [keyOrUrl].
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) {
    throw UnimplementedError('containsKey() has not been implemented.');
  }

  /// Stores raw [bytes] directly into the cache under [key].
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
    throw UnimplementedError('putBytes() has not been implemented.');
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
    throw UnimplementedError('putFile() has not been implemented.');
  }

  /// Updates the `pinned` status of an existing entry identified by [keyOrUrl].
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) {
    throw UnimplementedError('setPinned() has not been implemented.');
  }

  /// Removes a single cached entry and its underlying file by [keyOrUrl].
  /// Returns `true` if an entry was removed.
  Future<bool> removeFile(String keyOrUrl) {
    throw UnimplementedError('removeFile() has not been implemented.');
  }

  /// Removes all cached entries matching [tag].
  /// Returns the number of removed entries.
  Future<int> removeByTag(String tag) {
    throw UnimplementedError('removeByTag() has not been implemented.');
  }

  /// Removes all expired entries from the cache.
  /// Returns the number of removed entries.
  Future<int> removeExpired() {
    throw UnimplementedError('removeExpired() has not been implemented.');
  }

  /// Trims the cache using the active eviction policy until total size is at or below [maxBytes].
  /// Returns the number of evicted entries.
  Future<int> trimToSize(int maxBytes) {
    throw UnimplementedError('trimToSize() has not been implemented.');
  }

  /// Clears all entries in the cache.
  /// When [includePinned] is `false`, pinned entries are preserved.
  /// Returns the number of removed entries.
  Future<int> clearAll({bool includePinned = true}) {
    throw UnimplementedError('clearAll() has not been implemented.');
  }

  /// Lists all cached entries, optionally filtered by [tag] or excluding expired entries.
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) {
    throw UnimplementedError('listEntries() has not been implemented.');
  }

  /// Computes and returns current cache storage statistics ([CacheStats]).
  Future<CacheStats> getStats() {
    throw UnimplementedError('getStats() has not been implemented.');
  }

  /// Queries platform-specific caching capabilities and storage engine details.
  Future<CachePlatformCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }
}
