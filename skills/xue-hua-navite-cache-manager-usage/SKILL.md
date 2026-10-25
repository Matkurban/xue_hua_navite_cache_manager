---
name: xue-hua-navite-cache-manager-usage
description: Use when the user is working with xue_hua_navite_cache_manager APIs to display cached network images (CachedNetworkImage, CachedNetworkImageProvider), implement cross-platform network file caching, conditional HTTP 304 ETag/Last-Modified revalidation, 10,000+ entry LRU/LFU/FIFO/TTL disk eviction, MD5/SHA-256 checksum verification, tag-based cache invalidation, and real-time download progress tracking across Android, iOS, macOS, Windows, Linux, and Web.
---
# xue-hua-navite-cache-manager

Provide idiomatic integration patterns, zero-jank image rendering guidelines, platform setup rules, and best practices for the `xue_hua_navite_cache_manager` Flutter plugin (`v1.1.0+`) across Android, iOS, macOS, Windows, Linux, and Web.

## When to Use

- Displaying and caching network images with zero UI jank (`CachedNetworkImage`, `CachedNetworkImageProvider`)
- Downsampling high-resolution images in the C++ codec (`memCacheWidth`, `memCacheHeight`, `maxWidth`, `maxHeight`)
- Configuring global disk cache quotas, high-volume entry limits (`maxEntries = 20000` for 10,000+ entries), eviction policies (`LRU`, `LFU`, `FIFO`, `ttlOnly`), HTTP timeouts, and default headers (`CacheManagerConfig`)
- Fetching and caching remote images, audio, video, PDFs, or arbitrary files (`downloadFile`, `getSingleFile`, `prefetch`, `prefetchAll`, `cancelDownload`)
- Validating downloaded files with native `MD5` or `SHA-256` checksums (`CacheChecksumAlgorithm`)
- Storing in-memory bytes or existing local files directly into the managed cache (`putBytes`, `putFile`)
- Querying cached entries offline without triggering network requests (`getFileFromCache`, `readCacheBytes`, `containsKey`)
- Protecting critical assets from quota eviction (`setPinned`) or purging entries by tag, expiration, or byte limit (`removeFile`, `removeByTag`, `removeExpired`, `trimToSize`, `clearAll`)
- Inspecting live cache telemetry and platform storage capabilities (`getStats`, `listEntries`, `getCapabilities`, `progressStream`, `watchProgress`)

## Guidelines

1. Access `XueHuaNaviteCacheManager.instance` and call `configure(CacheManagerConfig(...))` during application startup before issuing download requests.
2. Use `CachedNetworkImage` for widget rendering or `CachedNetworkImageProvider` for `CircleAvatar` / `DecorationImage` integration. Always set `memCacheWidth` or `memCacheHeight` when rendering high-resolution remote photos inside list/grid thumbnails so the C++ image codec downsamples before uploading textures to the GPU.
3. Subscribe to `XueHuaNaviteCacheManager.instance.progressStream` (or `watchProgress(keyOrUrl)`) to render real-time transfer progress and cancel the `StreamSubscription` in `dispose()`.
4. Prefer `downloadFile(CacheRequest(...))` when you need to inspect `result.source` (`cacheHit`, `revalidated`, `networkDownload`, `staleCacheFallback`) and `result.httpStatusCode`; use `getSingleFile(url)` when you only need the `CacheEntry`.
5. Group related assets using the `tag` parameter (for example, `'avatars'`, `'course_audio'`, `'banners'`) so you can invalidate an entire category in one call with `removeByTag(tag)`.
6. Set `pinned: true` (or call `setPinned(keyOrUrl, pinned: true)`) on essential offline resources so automatic `LRU`/`LFU`/`FIFO` quota trimming skips them.
7. On Web targets, `entry.filePath` is a browser `Blob` object URL or `CacheStorage` URI rather than a POSIX filesystem path (`capabilities.supportsFileSystemPaths` is `false`). Use `CachedNetworkImage` or `readCacheBytes(keyOrUrl)` on Web instead of `dart:io` `File(entry.filePath)`.
8. On macOS, ensure `com.apple.security.network.client` is enabled in both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`.

## Examples

### Zero-jank CachedNetworkImage and CachedNetworkImageProvider

```dart
import 'package:flutter/material.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

class UserAvatarCard extends StatelessWidget {
  const UserAvatarCard({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      tag: 'avatars',
      width: 120,
      height: 120,
      memCacheWidth: 240, // Downsample in C++ codec to prevent UI jank
      fit: BoxFit.cover,
      progressIndicatorBuilder: (context, url, progress) {
        final double? value = progress?.expectedTotalBytes != null &&
                progress!.expectedTotalBytes! > 0
            ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
            : null;
        return Center(child: CircularProgressIndicator(value: value));
      },
      errorWidget: (context, url, error, stackTrace) =>
          const Icon(Icons.broken_image_outlined),
    );
  }
}
```

### Global initialization and network file caching (10,000+ entries ready)

```dart
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

final cacheManager = XueHuaNaviteCacheManager.instance;

Future<void> initCache() async {
  await cacheManager.configure(
    const CacheManagerConfig(
      maxDiskCacheBytes: 500 * 1024 * 1024, // 500 MB
      maxEntries: 20000, // Supports 10,000+ cached entries with O(1) quota checks
      defaultTtlSeconds: 7 * 24 * 3600, // 7 days
      evictionPolicy: CacheEvictionPolicy.lru,
      cacheSubdirectory: 'app_media_cache',
      respectHttpCacheHeaders: true,
      autoTrimOnWrite: true,
    ),
  );

  final result = await cacheManager.downloadFile(
    const CacheRequest(
      url: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
      tag: 'animals',
      fallbackToCacheOnError: true,
      checksumAlgorithm: CacheChecksumAlgorithm.sha256,
    ),
  );

  // Inspect cache source: cacheHit, revalidated (HTTP 304), networkDownload, or staleCacheFallback
  print('Source: ${result.source.wireValue}, Path: ${result.filePath}');
}
```

## Gotchas

- **High-Resolution Image Jank**: Omitting `memCacheWidth` / `memCacheHeight` when displaying 4K images inside small list items decodes full-size bitmaps in GPU memory. Always set `memCacheWidth` or `memCacheHeight` for list/grid thumbnails.
- **Web (`CacheStorage` & CORS)**: `window.caches` and `fetch()` require remote servers to return valid CORS headers when fetching cross-origin resources in browsers. Always use `CachedNetworkImage` or `readCacheBytes()` across all 6 platforms.
- **macOS App Sandbox**: Outbound downloads fail with `NSURLErrorNotConnectedToInternet` (`-1009`) or `Operation not permitted` if `com.apple.security.network.client` is missing from `DebugProfile.entitlements` or `Release.entitlements`.
- **Linux Runtime Dependencies**: Uses GLib `GChecksum` for native hashing and `curl` for HTTP transfers; ensure `curl` and standard CA certificates (`ca-certificates`) are installed on minimal Linux containers.
