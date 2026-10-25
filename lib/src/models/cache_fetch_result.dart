import 'cache_entry.dart';
import 'cache_result_source.dart';

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
