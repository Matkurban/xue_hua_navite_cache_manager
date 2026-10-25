/// Origin of a returned `CacheFetchResult`.
enum CacheResultSource {
  /// Loaded directly from local cache without network transfer.
  cacheHit('cacheHit'),

  /// Conditional HTTP request (`If-None-Match` / `If-Modified-Since`) returned `304 Not Modified`
  /// and refreshed the local entry's expiration timestamp.
  revalidated('revalidated'),

  /// Downloaded fresh content from the remote server and stored it in the cache.
  networkDownload('networkDownload'),

  /// Returned from existing local cache because a network revalidation attempt failed
  /// while `fallbackToCacheOnError` was enabled.
  staleCacheFallback('staleCacheFallback');

  const CacheResultSource(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheResultSource] from its [wireValue].
  static CacheResultSource fromWire(String? value) {
    for (final source in CacheResultSource.values) {
      if (source.wireValue == value) {
        return source;
      }
    }
    return CacheResultSource.networkDownload;
  }
}
