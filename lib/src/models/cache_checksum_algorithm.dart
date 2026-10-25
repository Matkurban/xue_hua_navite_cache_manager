/// Checksum algorithm used to verify downloaded or cached file integrity.
enum CacheChecksumAlgorithm {
  /// No checksum verification.
  none('none'),

  /// 128-bit MD5 digest (hex-encoded).
  md5('md5'),

  /// 256-bit SHA-256 digest (hex-encoded).
  sha256('sha256');

  const CacheChecksumAlgorithm(this.wireValue);

  /// Serialized string value sent over the platform channel.
  final String wireValue;

  /// Parses a [CacheChecksumAlgorithm] from its [wireValue].
  static CacheChecksumAlgorithm fromWire(String? value) {
    for (final algorithm in CacheChecksumAlgorithm.values) {
      if (algorithm.wireValue == value) {
        return algorithm;
      }
    }
    return CacheChecksumAlgorithm.none;
  }
}
