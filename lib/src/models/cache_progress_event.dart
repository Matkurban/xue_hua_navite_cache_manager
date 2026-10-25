import 'cache_transfer_state.dart';

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
