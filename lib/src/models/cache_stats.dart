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
