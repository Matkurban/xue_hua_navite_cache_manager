/// Describes the runtime caching capabilities and storage characteristics of the host platform.
class CachePlatformCapabilities {
  /// Constructs a [CachePlatformCapabilities].
  const CachePlatformCapabilities({
    required this.platformName,
    required this.supportsFileSystemPaths,
    required this.supportsConditionalHttpRevalidation,
    required this.supportsNativeCryptoHash,
    required this.supportsLowDiskSpaceNotifications,
    required this.storageMechanism,
    required this.defaultCacheRootPath,
  });

  /// Deserializes [CachePlatformCapabilities] from a platform channel map.
  factory CachePlatformCapabilities.fromMap(Map<Object?, Object?> map) {
    return CachePlatformCapabilities(
      platformName: (map['platformName'] as String?) ?? 'unknown',
      supportsFileSystemPaths:
          (map['supportsFileSystemPaths'] as bool?) ?? true,
      supportsConditionalHttpRevalidation:
          (map['supportsConditionalHttpRevalidation'] as bool?) ?? true,
      supportsNativeCryptoHash:
          (map['supportsNativeCryptoHash'] as bool?) ?? true,
      supportsLowDiskSpaceNotifications:
          (map['supportsLowDiskSpaceNotifications'] as bool?) ?? false,
      storageMechanism: (map['storageMechanism'] as String?) ?? '',
      defaultCacheRootPath: (map['defaultCacheRootPath'] as String?) ?? '',
    );
  }

  /// Host operating system or runtime name (`'android'`, `'ios'`, `'macos'`, `'windows'`, `'linux'`, `'web'`).
  final String platformName;

  /// `true` on Android, iOS, macOS, Windows, and Linux where cached entries reside as native OS files;
  /// `false` on Web where entries are stored in browser `CacheStorage` / Blob URLs.
  final bool supportsFileSystemPaths;

  /// Whether `ETag` (`If-None-Match`) and `Last-Modified` (`If-Modified-Since`) HTTP 304 revalidation is supported.
  final bool supportsConditionalHttpRevalidation;

  /// Whether hardware/OS-accelerated MD5 and SHA-256 hashing is available.
  final bool supportsNativeCryptoHash;

  /// Whether the OS automatically purges unpinned cache files under extreme system storage pressure.
  final bool supportsLowDiskSpaceNotifications;

  /// Description of the underlying storage engine (e.g. `'NSCachesDirectory + URLSession'`, `'CacheStorage API + Blob URL'`).
  final String storageMechanism;

  /// Default root directory path or storage namespace used by the platform.
  final String defaultCacheRootPath;

  /// Serializes this [CachePlatformCapabilities] to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'platformName': platformName,
      'supportsFileSystemPaths': supportsFileSystemPaths,
      'supportsConditionalHttpRevalidation':
          supportsConditionalHttpRevalidation,
      'supportsNativeCryptoHash': supportsNativeCryptoHash,
      'supportsLowDiskSpaceNotifications': supportsLowDiskSpaceNotifications,
      'storageMechanism': storageMechanism,
      'defaultCacheRootPath': defaultCacheRootPath,
    };
  }
}
