/// Lifecycle status of a real-time `CacheProgressEvent`.
enum CacheTransferState {
  /// Download or cache operation is queued or starting.
  started('started'),

  /// Bytes are actively being received and written to temporary storage.
  inProgress('inProgress'),

  /// File was already valid in cache or revalidated via HTTP 304.
  cacheHit('cacheHit'),

  /// Download finished, passed optional checksum verification, and was committed to cache.
  completed('completed'),

  /// Download was canceled by calling `cancelDownload`.
  canceled('canceled'),

  /// Download or verification failed.
  failed('failed');

  const CacheTransferState(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheTransferState] from its [wireValue].
  static CacheTransferState fromWire(String? value) {
    for (final state in CacheTransferState.values) {
      if (state.wireValue == value) {
        return state;
      }
    }
    return CacheTransferState.inProgress;
  }
}
