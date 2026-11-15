// ignore_for_file: depend_on_referenced_packages

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    appDirectory: 'example',
    configDirectory: '.',
    dartOut: 'lib/src/pigeon/cache_messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/kurban/xue_hua_navite_cache_manager/CacheMessages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.kurban.xue_hua_navite_cache_manager',
      useJni: true,
    ),
    swiftOut: 'ios/xue_hua_navite_cache_manager/Sources/xue_hua_navite_cache_manager/CacheMessages.g.swift',
    swiftOptions: SwiftOptions(
      useFfi: true,
      ffiModuleName: 'xue_hua_navite_cache_manager',
    ),
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'xue_hua_navite_cache_manager'),
    gobjectHeaderOut: 'linux/messages.g.h',
    gobjectSourceOut: 'linux/messages.g.cc',
    gobjectOptions: GObjectOptions(module: 'XueHuaCache'),
  ),
)
enum WireCacheChecksumAlgorithm { none, md5, sha256 }

enum WireCacheEvictionPolicy { lru, lfu, fifo, ttlOnly }

enum WireCacheResultSource {
  cacheHit,
  revalidated,
  networkDownload,
  staleCacheFallback,
}

enum WireCacheTransferState {
  started,
  inProgress,
  cacheHit,
  completed,
  canceled,
  failed,
}

class WireCacheManagerConfig {
  WireCacheManagerConfig({
    required this.maxDiskCacheBytes,
    required this.maxEntries,
    required this.defaultTtlSeconds,
    required this.evictionPolicy,
    required this.cacheSubdirectory,
    required this.maxConcurrentDownloads,
    required this.connectTimeoutMs,
    required this.readTimeoutMs,
    required this.defaultHeaders,
    required this.respectHttpCacheHeaders,
    required this.autoTrimOnWrite,
  });

  int maxDiskCacheBytes;
  int maxEntries;
  int defaultTtlSeconds;
  WireCacheEvictionPolicy evictionPolicy;
  String cacheSubdirectory;
  int maxConcurrentDownloads;
  int connectTimeoutMs;
  int readTimeoutMs;
  Map<String, String> defaultHeaders;
  bool respectHttpCacheHeaders;
  bool autoTrimOnWrite;
}

class WireCacheRequest {
  WireCacheRequest({
    required this.url,
    this.customKey,
    this.tag,
    this.fileExtension,
    required this.headers,
    this.ttlSeconds,
    required this.forceRefresh,
    required this.fallbackToCacheOnError,
    required this.pinned,
    required this.checksumAlgorithm,
    this.expectedChecksum,
  });

  String url;
  String? customKey;
  String? tag;
  String? fileExtension;
  Map<String, String> headers;
  int? ttlSeconds;
  bool forceRefresh;
  bool fallbackToCacheOnError;
  bool pinned;
  WireCacheChecksumAlgorithm checksumAlgorithm;
  String? expectedChecksum;
}

class WireCacheEntry {
  WireCacheEntry({
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
    required this.checksumAlgorithm,
    required this.pinned,
  });

  String key;
  String url;
  String filePath;
  int sizeBytes;
  int createdAtMs;
  int lastAccessedAtMs;
  int expiresAtMs;
  int hitCount;
  String? tag;
  String? mimeType;
  String? eTag;
  String? lastModified;
  String? checksum;
  WireCacheChecksumAlgorithm checksumAlgorithm;
  bool pinned;
}

class WireCacheFetchResult {
  WireCacheFetchResult({
    this.entry,
    required this.source,
    this.httpStatusCode,
    required this.elapsedMs,
  });

  // Nullable on the wire schema only so Pigeon 30.0.2 C++ codegen emits
  // `if (obj.entry_) { os << *obj.entry_; }` instead of invalid `os << obj.entry_;`
  // on a non-nullable `std::unique_ptr<WireCacheEntry>`.
  WireCacheEntry? entry;
  WireCacheResultSource source;
  int? httpStatusCode;
  int elapsedMs;
}

class WireCacheProgressEvent {
  WireCacheProgressEvent({
    required this.key,
    required this.url,
    required this.state,
    required this.bytesReceived,
    required this.totalBytes,
    this.filePath,
    this.errorMessage,
  });

  String key;
  String url;
  WireCacheTransferState state;
  int bytesReceived;
  int totalBytes;
  String? filePath;
  String? errorMessage;
}

class WireCacheStats {
  WireCacheStats({
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

  int totalEntries;
  int totalBytes;
  int expiredEntries;
  int pinnedEntries;
  int maxDiskCacheBytes;
  String cacheDirectoryPath;
  int hitCount;
  int missCount;
  int evictionCount;
  Map<String, int> bytesByTag;
}

class WireCachePlatformCapabilities {
  WireCachePlatformCapabilities({
    required this.platformName,
    required this.supportsFileSystemPaths,
    required this.supportsConditionalHttpRevalidation,
    required this.supportsNativeCryptoHash,
    required this.supportsLowDiskSpaceNotifications,
    required this.storageMechanism,
    required this.defaultCacheRootPath,
  });

  String platformName;
  bool supportsFileSystemPaths;
  bool supportsConditionalHttpRevalidation;
  bool supportsNativeCryptoHash;
  bool supportsLowDiskSpaceNotifications;
  String storageMechanism;
  String defaultCacheRootPath;
}

@HostApi()
abstract class CacheHostApi {
  @async
  void configure(WireCacheManagerConfig config);

  @async
  WireCacheFetchResult downloadFile(WireCacheRequest request);

  @async
  List<WireCacheEntry> prefetchAll(List<WireCacheRequest> requests);

  bool cancelDownload(String keyOrUrl);

  @async
  WireCacheEntry? getFileFromCache(String keyOrUrl, bool ignoreExpired);

  @async
  Uint8List? readCacheBytes(String keyOrUrl, bool ignoreExpired);

  @async
  bool containsKey(String keyOrUrl, bool ignoreExpired);

  @async
  WireCacheEntry putBytes(
    String key,
    Uint8List bytes,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned,
  );

  @async
  WireCacheEntry putFile(
    String key,
    String sourceFilePath,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned,
  );

  @async
  bool setPinned(String keyOrUrl, bool pinned);

  @async
  bool removeFile(String keyOrUrl);

  @async
  int removeByTag(String tag);

  @async
  int removeExpired();

  @async
  int trimToSize(int maxBytes);

  @async
  int clearAll(bool includePinned);

  @async
  List<WireCacheEntry> listEntries(String? tag, bool includeExpired);

  @async
  WireCacheStats getStats();

  WireCachePlatformCapabilities getCapabilities();
}

@FlutterApi()
abstract class CacheProgressFlutterApi {
  @async
  void onProgress(WireCacheProgressEvent event);
}
