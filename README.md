# xue_hua_navite_cache_manager

English | [简体中文](./README_ZH.md)

A production-ready, cross-platform native network file cache manager and zero-jank image caching library for Flutter supporting **Android**, **iOS**, **macOS**, **Windows**, **Linux**, and **Web**.

`xue_hua_navite_cache_manager` provides `CachedNetworkImage` and `CachedNetworkImageProvider` for 60/120 FPS image rendering alongside automatic HTTP/HTTPS file downloading, conditional HTTP revalidation (`ETag` / `Last-Modified` / `304 Not Modified`), `Cache-Control: max-age` parsing, high-volume **10,000+ entry** disk quota eviction (`LRU`, `LFU`, `FIFO`, `TTL-only`), native `MD5` and `SHA-256` checksum verification, category tag management, pinned entry protection, and real-time download progress streams.

## Features

- **Zero-Jank `CachedNetworkImage` & `CachedNetworkImageProvider`**:
  - **Synchronous `ImageCache` Short-Circuit**: Automatically skips fade animations when an image hits Flutter's in-memory `ImageCache` (`wasSynchronouslyLoaded`), preventing list/grid scroll flicker.
  - **Zero-Copy Engine IO Decoding**: Loads cached files directly on the Flutter Engine IO thread via `ui.ImmutableBuffer.fromFilePath` without copying multi-megabyte `Uint8List` arrays across `MethodChannel`.
  - **C++ Codec Target-Size Downsampling**: Supports `memCacheWidth` and `memCacheHeight` (`maxWidth` / `maxHeight` on provider) so 4K photos are downsampled during C++ decoding before GPU texture upload.
- **10,000+ Entries High-Throughput Index Engine**:
  - Defaults to `maxEntries = 20000` with `O(1)` running byte quota tracking (`totalCachedBytes`) and **600ms debounced asynchronous index flushing** so thousands of rapid cache hits/writes coalesce into a single non-blocking background disk write without SQLite FFI overhead.
- **6-Platform Native Engine**:
  - **Android**: `HttpURLConnection` + `MessageDigest` (`MD5` / `SHA-256`) + atomic file persistence under `Context.getCacheDir()`.
  - **iOS**: `URLSession` + Apple `CryptoKit` + `NSCachesDirectory` with `NSURLIsExcludedFromBackupKey` enabled automatically.
  - **macOS**: `URLSession` + Apple `CryptoKit` + `~/Library/Caches/<BundleID>/`.
  - **Windows**: Native `WinHTTP` + Windows `BCrypt` (`MD5` / `SHA-256`) + `%LOCALAPPDATA%\Temp\`.
  - **Linux**: GLib `GChecksum` (`MD5` / `SHA-256`) + `XDG_CACHE_HOME` (`g_get_user_cache_dir()`) + `curl` transfer.
  - **Web**: Browser `CacheStorage` API (`window.caches`) + `fetch()` (`AbortController`) + `Blob` Object URLs + debounced `localStorage` metadata index.
- **Smart HTTP Cache Revalidation**: Automatically stores `ETag` and `Last-Modified` response headers and sends `If-None-Match` / `If-Modified-Since` on subsequent refreshes to save bandwidth via `304 Not Modified`.
- **Resilient Offline Fallback**: When `fallbackToCacheOnError: true` (default), returns existing cached files if the device is offline or the remote server fails.
- **Flexible Quota & Eviction Policies**: Supports `LRU` (Least Recently Used), `LFU` (Least Frequently Used), `FIFO` (First In, First Out), and `ttlOnly` eviction strategies with entry pinning (`pinned: true`).
- **Native Checksum Verification**: Validates downloaded files against expected `MD5` or `SHA-256` hex digests before committing them to cache.
- **Built-in AI Coding Agent Skill**: Ships with a standard package skill in `skills/xue-hua-navite-cache-manager/SKILL.md` compatible with `dart run skills@ get`.

## System Requirements

| Platform | Minimum Version | Native APIs Used |
| :--- | :--- | :--- |
| **Dart SDK** | `^3.13.0` | `plugin_platform_interface`, `web: ^1.0.0` |
| **Flutter** | `>=3.47.0` | `MethodChannel`, `EventChannel`, `flutter_web_plugins` |
| **Android** | API 24+ (Android 7.0+) | `HttpURLConnection`, `MessageDigest`, `Context.cacheDir` |
| **iOS** | iOS 15.0+ | `URLSession`, `CryptoKit`, `FileManager (.cachesDirectory)` |
| **macOS** | macOS 12.0+ | `URLSession`, `CryptoKit`, `FileManager (.cachesDirectory)` |
| **Windows** | Windows 10+ | `WinHTTP`, `BCrypt`, `SHGetKnownFolderPath` |
| **Linux** | GLib 2.56+ / GTK 3 | `GLib`, `GChecksum`, `curl` |
| **Web** | Modern Browsers | `window.caches` (`CacheStorage`), `fetch`, `URL.createObjectURL` |

## Installation & Platform Setup

Add `xue_hua_navite_cache_manager` to your `pubspec.yaml`:

```yaml
dependencies:
  xue_hua_navite_cache_manager: ^1.1.0
```

### Android

The plugin's `AndroidManifest.xml` automatically declares `<uses-permission android:name="android.permission.INTERNET" />`. No extra configuration is required for HTTPS URLs.

### iOS

No additional configuration is required for HTTPS downloads. Cached files are stored inside `Library/Caches` with `isExcludedFromBackup = true` so they do not consume the user's iCloud backup quota.

### macOS

Enable outbound network access in both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

### Windows & Linux

- **Windows**: Links `winhttp.lib`, `bcrypt.lib`, and `shell32.lib` automatically via the plugin's `CMakeLists.txt`.
- **Linux**: Ensure `curl` and `ca-certificates` are installed on the target system.

### Web

Cross-origin downloads use the browser `fetch()` API and require the remote server to include valid CORS headers (`Access-Control-Allow-Origin`).

## Quick Start

### 1. Display Cached Network Images (`CachedNetworkImage` & `CachedNetworkImageProvider`)

```dart
import 'package:flutter/material.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

// 1a. Standard widget with C++ codec downsampling and progress indicator
CachedNetworkImage(
  imageUrl: 'https://httpbin.org/image/jpeg',
  tag: 'wildlife',
  width: 200,
  height: 200,
  memCacheWidth: 400, // Downsamples in C++ codec to prevent UI jank
  fit: BoxFit.cover,
  progressIndicatorBuilder: (context, url, progress) {
    final double? ratio = progress?.expectedTotalBytes != null &&
            progress!.expectedTotalBytes! > 0
        ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
        : null;
    return Center(child: CircularProgressIndicator(value: ratio));
  },
  errorWidget: (context, url, error, stackTrace) =>
      const Center(child: Icon(Icons.broken_image_outlined)),
);

// 1b. Using CachedNetworkImageProvider directly with CircleAvatar / DecorationImage
const CircleAvatar(
  radius: 40,
  backgroundImage: CachedNetworkImageProvider(
    'https://www.gstatic.com/webp/gallery/1.jpg',
    tag: 'avatars',
    maxWidth: 160,
  ),
);
```

### 2. Configure the Global Cache Manager (10,000+ Entries Support)

```dart
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

final cache = XueHuaNaviteCacheManager.instance;

Future<void> initCache() async {
  await cache.configure(
    const CacheManagerConfig(
      maxDiskCacheBytes: 500 * 1024 * 1024, // 500 MB quota
      maxEntries: 20000, // Supports 10,000+ entries with O(1) running byte tracking
      defaultTtlSeconds: 7 * 24 * 3600, // 7 days default TTL
      evictionPolicy: CacheEvictionPolicy.lru,
      cacheSubdirectory: 'app_media_cache',
      maxConcurrentDownloads: 4,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      defaultHeaders: <String, String>{
        'User-Agent': 'MyFlutterApp/1.1.0',
      },
      respectHttpCacheHeaders: true,
      autoTrimOnWrite: true,
    ),
  );
}
```

### 3. Download or Retrieve Any Network File

```dart
final result = await cache.downloadFile(
  const CacheRequest(
    url: 'https://httpbin.org/image/jpeg',
    tag: 'wildlife',
    fallbackToCacheOnError: true,
    checksumAlgorithm: CacheChecksumAlgorithm.sha256,
  ),
);

print('Origin: ${result.source.wireValue}'); // cacheHit, revalidated, networkDownload, or staleCacheFallback
print('Local path / URI: ${result.filePath}');
print('Size: ${result.entry.sizeBytes} bytes, SHA-256: ${result.entry.checksum}');
```

Or use the concise `getSingleFile` helper when you only need the `CacheEntry`:

```dart
final entry = await cache.getSingleFile(
  'https://www.gstatic.com/webp/gallery/1.jpg',
  tag: 'wildlife',
);
```

### 4. Listen to Real-Time Download Progress

```dart
final subscription = cache
    .watchProgress('https://filesamples.com/samples/video/mp4/sample_640x360.mp4')
    .listen((event) {
  final percent = ((event.progress ?? 0) * 100).toStringAsFixed(1);
  print('[${event.state.wireValue}] $percent% (${event.bytesReceived}/${event.totalBytes})');
});

// Remember to cancel in dispose():
// await subscription.cancel();
```

### 5. Batch Prefetching & Offline Lookup

```dart
// Prefetch multiple files
final entries = await cache.prefetchAll(const <CacheRequest>[
  CacheRequest(
    url: 'https://httpbin.org/image/jpeg',
    tag: 'onboarding',
    pinned: true,
  ),
  CacheRequest(
    url: 'https://www.gstatic.com/webp/gallery/1.jpg',
    tag: 'onboarding',
  ),
]);

// Query cache without making a network call
final cachedEntry = await cache.getFileFromCache(
  'https://httpbin.org/image/jpeg',
);
final bytes = await cache.readCacheBytes(
  'https://httpbin.org/image/jpeg',
);
```

### 6. Manual Insertion (`putBytes` / `putFile`) & Cache Eviction

```dart
import 'dart:typed_data';

// Store generated bytes directly into cache
await cache.putBytes(
  key: 'user_theme_config',
  bytes: Uint8List.fromList('{"darkMode":true}'.codeUnits),
  fileExtension: 'json',
  mimeType: 'application/json',
  tag: 'settings',
  pinned: true,
);

// Selective cleanup
await cache.removeByTag('onboarding');
await cache.removeExpired();
await cache.trimToSize(50 * 1024 * 1024); // Trim to 50 MB
await cache.clearAll(includePinned: false); // Clear all except pinned entries
```

### 7. Inspect Telemetry & Platform Capabilities

```dart
final stats = await cache.getStats();
print('Total files: ${stats.totalEntries}, Hit rate: ${(stats.hitRate * 100).toStringAsFixed(1)}%');

final capabilities = await cache.getCapabilities();
print('Platform: ${capabilities.platformName}, Engine: ${capabilities.storageMechanism}');
```

## Important Notes & Platform Gotchas

1. **Preventing High-Resolution Image Jank**:
   - Always pass `memCacheWidth` or `memCacheHeight` to `CachedNetworkImage` (or `maxWidth` / `maxHeight` to `CachedNetworkImageProvider`) when rendering large images inside compact list/grid cells.
2. **Web File Paths vs. Native File Paths**:
   - On Android, iOS, macOS, Windows, and Linux (`capabilities.supportsFileSystemPaths == true`), `entry.filePath` is an absolute OS filesystem path suitable for `File(entry.filePath)`.
   - On Web (`capabilities.supportsFileSystemPaths == false`), `entry.filePath` is a browser `Blob` object URL or `CacheStorage` URI. Use `CachedNetworkImage` or `cache.readCacheBytes(keyOrUrl)` when you need cross-platform compatibility.
3. **Pinned Entries**:
   - Entries with `pinned: true` are never evicted by automatic `LRU`, `LFU`, or `FIFO` quota enforcement or `removeExpired()`. To clear everything except pinned files, call `clearAll(includePinned: false)`.
4. **AI Agent Skills**:
   - Consumers can install this package's bundled AI coding skill by running `dart run skills@ get`.

## Author & Repository

- **Author**: Matkurban
- **Email**: [3496354336@qq.com](mailto:3496354336@qq.com)
- **Repository**: [https://github.com/Matkurban/xue_hua_navite_cache_manager](https://github.com/Matkurban/xue_hua_navite_cache_manager)
