/// Eviction strategy used when the cache exceeds its maximum disk byte quota.
enum CacheEvictionPolicy {
  /// Least Recently Used: evicts entries with the oldest `lastAccessedAt` timestamp first.
  lru('lru'),

  /// Least Frequently Used: evicts entries with the lowest `hitCount` first, breaking ties by `lastAccessedAt`.
  lfu('lfu'),

  /// First In, First Out: evicts entries with the oldest `createdAt` timestamp first.
  fifo('fifo'),

  /// Evicts only expired entries (where `expiresAt` is in the past).
  ttlOnly('ttlOnly');

  const CacheEvictionPolicy(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheEvictionPolicy] from its [wireValue], defaulting to [CacheEvictionPolicy.lru].
  static CacheEvictionPolicy fromWire(String? value) {
    for (final policy in CacheEvictionPolicy.values) {
      if (policy.wireValue == value) {
        return policy;
      }
    }
    return CacheEvictionPolicy.lru;
  }
}
