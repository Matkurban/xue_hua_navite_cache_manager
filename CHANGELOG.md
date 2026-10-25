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
