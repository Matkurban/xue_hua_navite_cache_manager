# xue_hua_navite_cache_manager

[English](./README.md) | 简体中文

一款面向生产环境的 Flutter 全平台原生网络文件缓存管理插件，完整支持 **Android**、**iOS**、**macOS**、**Windows**、**Linux** 与 **Web** 六大平台。

`xue_hua_navite_cache_manager` 提供自动化的 HTTP/HTTPS 网络文件下载缓存、HTTP 条件协商重验证（`ETag` / `Last-Modified` / `304 Not Modified`）、`Cache-Control: max-age` 解析、可配置的磁盘配额淘汰策略（`LRU`、`LFU`、`FIFO`、`TTL-only`）、原生 `MD5` 与 `SHA-256` 完整性校验、按分类标签（Tag）批量清理、重要条目置顶保护（Pinned）以及实时下载进度流监听。

## 核心特性

- **六端原生级底层实现**：
  - **Android**：基于 `HttpURLConnection` + `MessageDigest`（`MD5` / `SHA-256`）+ `Context.getCacheDir()` 临时文件原子重命名落盘。
  - **iOS**：基于 `URLSession` + Apple `CryptoKit` + `NSCachesDirectory`，自动设置 `NSURLIsExcludedFromBackupKey = true` 避免占用用户 iCloud 备份空间。
  - **macOS**：基于 `URLSession` + Apple `CryptoKit` + `~/Library/Caches/<BundleID>/`。
  - **Windows**：基于原生 `WinHTTP` + Windows `BCrypt`（`MD5` / `SHA-256`）+ `%LOCALAPPDATA%\Temp\`。
  - **Linux**：基于 GLib `GChecksum`（`MD5` / `SHA-256`）+ `XDG_CACHE_HOME` (`g_get_user_cache_dir()`) + `curl` 传输。
  - **Web**：基于浏览器原生 `CacheStorage` API (`window.caches`) + `fetch()` (`AbortController`) + `Blob` Object URL + `localStorage` 元数据索引。
- **智能 HTTP 304 协商缓存**：自动保存响应头中的 `ETag` 与 `Last-Modified`，在过期或强制刷新时自动携带 `If-None-Match` 与 `If-Modified-Since`，若服务端返回 `304 Not Modified` 则直接续期本地文件，大幅节省带宽。
- **离线容错回退（Stale Cache Fallback）**：开启 `fallbackToCacheOnError: true`（默认开启）时，若设备断网或远端服务器异常，会自动回退返回本地已缓存的历史文件。
- **多种淘汰算法与置顶保护**：支持 `LRU`（最近最少使用）、`LFU`（最不经常使用）、`FIFO`（先进先出）和 `ttlOnly`（仅清理过期）四种淘汰策略，支持通过 `pinned: true` 锁定关键离线包防止被自动淘汰。
- **原生哈希校验**：支持在文件落盘前校验 `MD5` 或 `SHA-256` 指纹，防止残损或被篡改的文件污染缓存。
- **内置 AI 编码助手 Skill**：遵循 [Dart Package Skills](https://dart.dev/tools/pub/package-skills) 规范，在 `skills/xue-hua-navite-cache-manager/SKILL.md` 内置标准使用技能，支持通过 `dart run skills@ get` 一键安装。

## 环境与平台要求

| 平台 / 环境 | 最低版本要求 | 底层核心技术栈 |
| :--- | :--- | :--- |
| **Dart SDK** | `^3.13.0` | `plugin_platform_interface`, `web: ^1.0.0` |
| **Flutter** | `>=3.47.0` | `MethodChannel`, `EventChannel`, `flutter_web_plugins` |
| **Android** | API 24+ (Android 7.0+) | `HttpURLConnection`, `MessageDigest`, `Context.cacheDir` |
| **iOS** | iOS 15.0+ | `URLSession`, `CryptoKit`, `FileManager (.cachesDirectory)` |
| **macOS** | macOS 12.0+ | `URLSession`, `CryptoKit`, `FileManager (.cachesDirectory)` |
| **Windows** | Windows 10+ | `WinHTTP`, `BCrypt`, `SHGetKnownFolderPath` |
| **Linux** | GLib 2.56+ / GTK 3 | `GLib`, `GChecksum`, `curl` |
| **Web** | 现代主流浏览器 | `window.caches` (`CacheStorage`), `fetch`, `URL.createObjectURL` |

## 集成与各端配置

在项目的 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  xue_hua_navite_cache_manager: ^1.0.0
```

### Android 配置

插件的 `AndroidManifest.xml` 已自动声明 `<uses-permission android:name="android.permission.INTERNET" />`，正常访问 HTTPS 网络资源无需额外配置。

### iOS 配置

访问 HTTPS 资源无需额外配置。缓存文件默认保存在应用沙盒的 `Library/Caches` 下，并已自动标记 `isExcludedFromBackup = true`。

### macOS 配置

由于 macOS App Sandbox 限制，请务必在 `macos/Runner/DebugProfile.entitlements` 和 `macos/Runner/Release.entitlements` 中开启客户端网络权限：

```xml
<key>com.apple.security.network.client</key>
<true/>
```

### Windows 与 Linux 配置

- **Windows**：插件 `CMakeLists.txt` 已自动链接系统 `winhttp`、`bcrypt` 与 `shell32` 库，无需额外依赖。
- **Linux**：请确保运行环境已安装 `curl` 与 `ca-certificates`。

### Web 配置

Web 端使用浏览器的 `fetch()` 与 `CacheStorage` 接口，跨域资源需要目标服务器配置合法的 CORS 响应头（`Access-Control-Allow-Origin`）。

## 快速上手

### 1. 初始化全局缓存配置

建议在应用启动时调用 `configure` 配置最大磁盘配额、默认过期时间及淘汰策略：

```dart
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

final cache = XueHuaNaviteCacheManager.instance;

Future<void> initCache() async {
  await cache.configure(
    const CacheManagerConfig(
      maxDiskCacheBytes: 300 * 1024 * 1024, // 300 MB 磁盘上限
      maxEntries: 1500,
      defaultTtlSeconds: 7 * 24 * 3600, // 默认缓存 7 天
      evictionPolicy: CacheEvictionPolicy.lru, // LRU 淘汰策略
      cacheSubdirectory: 'app_media_cache',
      maxConcurrentDownloads: 4,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      defaultHeaders: <String, String>{
        'User-Agent': 'MyFlutterApp/1.0.0',
      },
      respectHttpCacheHeaders: true,
      autoTrimOnWrite: true,
    ),
  );
}
```

### 2. 下载并缓存网络文件

使用 `downloadFile` 可获取包含命中来源（`cacheHit`、`revalidated`、`networkDownload`、`staleCacheFallback`）与 HTTP 状态码的完整结果：

```dart
final result = await cache.downloadFile(
  const CacheRequest(
    url: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
    tag: 'wildlife',
    fallbackToCacheOnError: true,
    checksumAlgorithm: CacheChecksumAlgorithm.sha256,
  ),
);

print('数据来源: ${result.source.wireValue}');
print('本地路径 / URI: ${result.filePath}');
print('文件大小: ${result.entry.sizeBytes} 字节, SHA-256: ${result.entry.checksum}');
```

如果只需要获取缓存条目 `CacheEntry`，也可以直接调用便捷方法 `getSingleFile`：

```dart
final entry = await cache.getSingleFile(
  'https://flutter.github.io/assets-for-api-docs/assets/widgets/falcon.jpg',
  tag: 'wildlife',
);
```

### 3. 监听实时下载进度

```dart
final subscription = cache
    .watchProgress('https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4')
    .listen((event) {
  final percent = ((event.progress ?? 0) * 100).toStringAsFixed(1);
  print('[${event.state.wireValue}] $percent% (${event.bytesReceived}/${event.totalBytes})');
});

// 页面销毁时取消订阅：
// await subscription.cancel();
```

### 4. 批量预取与纯离线查询

```dart
// 批量预加载网络资源
final entries = await cache.prefetchAll(const <CacheRequest>[
  CacheRequest(
    url: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
    tag: 'onboarding',
    pinned: true,
  ),
  CacheRequest(
    url: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/falcon.jpg',
    tag: 'onboarding',
  ),
]);

// 仅查询本地缓存（不发起网络请求）
final cachedEntry = await cache.getFileFromCache(
  'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
);
final bytes = await cache.readCacheBytes(
  'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
);
```

### 5. 手动写入缓存（`putBytes` / `putFile`）与按需清理

```dart
import 'dart:typed_data';

// 直接将内存字节写入受管缓存并置顶保护
await cache.putBytes(
  key: 'user_theme_config',
  bytes: Uint8List.fromList('{"darkMode":true}'.codeUnits),
  fileExtension: 'json',
  mimeType: 'application/json',
  tag: 'settings',
  pinned: true,
);

// 按标签、过期状态或目标体积清理缓存
await cache.removeByTag('onboarding');
await cache.removeExpired();
await cache.trimToSize(50 * 1024 * 1024); // 裁剪至 50 MB 以内
await cache.clearAll(includePinned: false); // 清空非置顶缓存，保留置顶文件
```

### 6. 获取缓存统计与平台能力信息

```dart
final stats = await cache.getStats();
print('缓存总数: ${stats.totalEntries}, 命中率: ${(stats.hitRate * 100).toStringAsFixed(1)}%');

final capabilities = await cache.getCapabilities();
print('当前平台: ${capabilities.platformName}, 存储引擎: ${capabilities.storageMechanism}');
```

## 注意事项与避坑指南

1. **Web 端与原生端路径差异**：
   - 在 Android、iOS、macOS、Windows 和 Linux 上（`capabilities.supportsFileSystemPaths == true`），`entry.filePath` 是真实的操作系统的本地绝对路径，可直接传给 `File(entry.filePath)`。
   - 在 Web 端（`capabilities.supportsFileSystemPaths == false`），由于浏览器沙盒限制，`entry.filePath` 是 `Blob` URL 或 `CacheStorage` 虚拟 URI。如果需要跨六端统一读取字节数据，请优先使用 `cache.readCacheBytes(keyOrUrl)`。
2. **置顶条目保护（Pinned）**：
   - 设置了 `pinned: true`（或调用 `setPinned(key, pinned: true)`）的条目不会在 `LRU`/`LFU`/`FIFO` 自动配额裁剪或 `removeExpired()` 时被删除。若需在清理缓存时保留置顶文件，请调用 `clearAll(includePinned: false)`。
3. **AI 编码技能（Package Skills）**：
   - 依赖本插件的项目可执行 `dart run skills@ get` 自动安装随包发布的 AI 辅助编程指南。

## 作者与仓库信息

- **作者**：Matkurban
- **邮箱**：[3496354336@qq.com](mailto:3496354336@qq.com)
- **仓库地址**：[https://github.com/Matkurban/xue_hua_navite_cache_manager](https://github.com/Matkurban/xue_hua_navite_cache_manager)
