## 1.1.5

* Fixed Darwin `flutter_driver` stalls after the example gallery scrolls. `flutter_driver` `waitFor` does not search until `transientCallbackCount` is 0. The gallery's indeterminate `CircularProgressIndicator` (no `Content-Length` yet) and the status banner's indeterminate `LinearProgressIndicator` (latest event `started` / `failed` / `canceled`) never stop ticking, so every later `tapText` hit the 20s command timeout while the isolate itself stayed alive. Loading placeholders are now static unless byte progress is known, and the banner never passes a null progress value.
* Fixed iOS `URLSession` startup. The session was first created on a GCD worker inside `downloadFile`; CFNetwork can abort the process from that thread, which matches the simulator fetch dying before `Last Fetch Result` and the Dart VM restarting. The session is now created on the main thread, with `waitsForConnectivity = false`, explicit request/resource timeouts, and a background delegate queue.
* Darwin downloads stream to disk with `URLSessionDownloadTask` instead of buffering the whole body in a `dataTask`. Progress events are throttled to 50ms and include the expected byte count. A watchdog cancels a task that never completes and releases its download permit exactly once. Nil fields are omitted from event and download payloads so the iOS codec does not see `NSNull`.
* iOS index load now recovers orphaned cache files when `cache_index_v1.json` is missing, matching macOS, and ignores in-flight `.partial` downloads.

## 1.1.4

* Fixed Windows platform-thread delivery for the event channel and download method results. `EventSink` and `MethodResult` are no longer invoked from WinHTTP worker threads. Flutter 3.50 and newer SDKs use `PluginRegistrarWindows::PostPlatformThreadTask` when that API is present; earlier 3.47+ SDKs post to a message-only window created on the platform thread, which is the thread the engine requires.
* Throttled Windows `inProgress` events to one per 50ms so gallery downloads do not flood the platform thread.
* Windows cache-index writes are now debounced (600ms) and flushed off the platform thread, matching the documented 10,000-entry index engine, so the example stress benchmark does not rewrite the full index on every `putBytes`.
* Replaced deprecated `package:flutter/material.dart` imports with `package:material_ui/material_ui.dart` (`material_ui: ^1.0.0`) so root `flutter analyze` is clean on Flutter 3.47+.

## 1.1.3

* Corrected the example integration test checksum expectation for the loopback payload.
* Added an example flutter_driver UI harness under `example/test_driver/`.
* Fixed Linux conditional HTTP revalidation. Downloads now store `ETag` and `Last-Modified`, and an HTTP `304 Not Modified` response is reported as `revalidated` instead of another `networkDownload`.

## 1.1.2

* Shortened the pubspec `description` so it meets pub.dev's 60–180 character guidance and search engines can show the full text.

## 1.1.1

* Fixed Windows `CMakeLists.txt` native-test gate: `if(FALSE AND ${include_..._tests})` expanded to invalid `if(FALSE AND)` when the variable was unset, breaking host app `flutter build windows`.

## 1.1.0

* Added a bounded native download concurrency pool controlled by `maxConcurrentDownloads` across Android, iOS, macOS, Windows, Linux, and Web, so large batches (e.g. 100+ images) stay controlled instead of flooding the network stack.
* Reworked iOS/macOS downloads to pure async `URLSession` completion callbacks with a download permit queue (removed blocking `semaphore.wait()` on GCD workers).
* Made `prefetchAll` run through the same bounded concurrent pool on every platform instead of serial one-by-one downloads.
* Added in-flight request deduplication by cache key on native platforms and in Dart `downloadFile`, so concurrent callers for the same URL/key share one network transfer and fan out one result.
* Moved Windows WinHTTP and Linux curl downloads onto background worker threads so MethodChannel / UI threads are no longer blocked during transfers.
* Fixed Windows `cancelDownload` so custom keys that are still only in the in-flight table (not yet indexed) can be canceled, matching Linux/Apple/Android behavior.
* Added `CachedNetworkImage` widget and `CachedNetworkImageProvider` for high-performance, zero-jank 60/120 FPS network image rendering and caching across all 6 platforms.
* Implemented zero-copy native file decoding (`ui.ImmutableBuffer.fromFilePath`) and C++ codec target-size downsampling (`memCacheWidth`, `memCacheHeight`, `maxWidth`, `maxHeight`) to prevent GPU/RAM spikes on high-resolution images.
* Added synchronous `ImageCache` fast-path short-circuiting (`wasSynchronouslyLoaded`) to eliminate fade-in flicker during rapid list/grid scrolling.
* Upgraded cache index engine across Android, iOS, macOS, Windows, Linux, and Web to support **10,000+ cached entries** (`maxEntries` default raised to `20,000`) with `O(1)` running byte quota tracking, 600ms debounced asynchronous disk flushing, and 50ms progress event throttling.
* Split data models and enums into dedicated modular files under `lib/src/models/`.
* Added a 5-tab example workbench featuring a `CachedNetworkImage` gallery and a 10,000+ entries stress benchmark, along with comprehensive unit, widget, and performance test suites.

## 1.0.0

* Initial stable release of `xue_hua_navite_cache_manager` across Android, iOS, macOS, Windows, Linux, and Web.
* Added `XueHuaNaviteCacheManager.instance` unified API with global configuration (`CacheManagerConfig`).
* Added network file downloading and caching (`downloadFile`, `getSingleFile`, `prefetch`, `prefetchAll`, `cancelDownload`) with conditional HTTP `ETag` / `Last-Modified` (`304 Not Modified`) revalidation and `Cache-Control: max-age` parsing.
* Added native MD5 and SHA-256 checksum verification (`CacheChecksumAlgorithm`).
* Added configurable disk quota eviction policies (`LRU`, `LFU`, `FIFO`, `TTL-only`) and pinned entry protection (`setPinned`).
* Added manual cache insertion and reading (`putBytes`, `putFile`, `getFileFromCache`, `readCacheBytes`, `containsKey`).
* Added selective and bulk eviction (`removeFile`, `removeByTag`, `removeExpired`, `trimToSize`, `clearAll`) and real-time analytics (`getStats`, `listEntries`, `getCapabilities`, `progressStream`, `watchProgress`).
