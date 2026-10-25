import 'cache_checksum_algorithm.dart';

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
