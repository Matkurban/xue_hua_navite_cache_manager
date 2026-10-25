## 1.0.0

* Initial stable release of `xue_hua_navite_cache_manager` across Android, iOS, macOS, Windows, Linux, and Web.
* Added `XueHuaNaviteCacheManager.instance` unified API with global configuration (`CacheManagerConfig`).
* Added network file downloading and caching (`downloadFile`, `getSingleFile`, `prefetch`, `prefetchAll`, `cancelDownload`) with conditional HTTP `ETag` / `Last-Modified` (`304 Not Modified`) revalidation and `Cache-Control: max-age` parsing.
* Added native MD5 and SHA-256 checksum verification (`CacheChecksumAlgorithm`).
* Added configurable disk quota eviction policies (`LRU`, `LFU`, `FIFO`, `TTL-only`) and pinned entry protection (`setPinned`).
* Added manual cache insertion and reading (`putBytes`, `putFile`, `getFileFromCache`, `readCacheBytes`, `containsKey`).
* Added selective and bulk eviction (`removeFile`, `removeByTag`, `removeExpired`, `trimToSize`, `clearAll`) and real-time analytics (`getStats`, `listEntries`, `getCapabilities`, `progressStream`, `watchProgress`).
