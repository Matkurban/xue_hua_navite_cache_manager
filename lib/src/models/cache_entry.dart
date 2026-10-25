import 'cache_checksum_algorithm.dart';

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
      DateTime.fromMillisecondsSinceEpoch(
        lastAccessedAtMs,
        isUtc: true,
      ).toLocal();

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
