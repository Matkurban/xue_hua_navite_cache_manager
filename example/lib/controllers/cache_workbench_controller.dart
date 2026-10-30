import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

import '../constants/workbench_presets.dart';

/// Reactive state and business logic controller for the Cache Manager Workbench,
/// powered by `signals_flutter` for fine-grained surgical UI updates without `setState`.
class CacheWorkbenchController {
  CacheWorkbenchController({XueHuaNaviteCacheManager? cacheManager})
    : _cache = cacheManager ?? XueHuaNaviteCacheManager.instance;

  final XueHuaNaviteCacheManager _cache;

  static const int defaultTtlSeconds = 7 * 24 * 3600;

  // Text input controllers
  final TextEditingController urlController = TextEditingController(
    text: kDefaultFetchUrl,
  );
  final TextEditingController customKeyController = TextEditingController();
  final TextEditingController tagController = TextEditingController(
    text: 'images',
  );
  final TextEditingController expectedHashController = TextEditingController();
  final TextEditingController manualKeyController = TextEditingController(
    text: 'app_offline_manifest',
  );
  final TextEditingController manualPayloadController = TextEditingController(
    text: '{"version":"1.2.0","environment":"production","offlineReady":true}',
  );

  // Fine-grained reactive signals
  final Signal<bool> isReady = signal<bool>(false);
  final Signal<bool> isBusy = signal<bool>(false);

  final Signal<CacheEvictionPolicy> evictionPolicy =
      signal<CacheEvictionPolicy>(CacheEvictionPolicy.lru);
  final Signal<CacheChecksumAlgorithm> checksumAlgorithm =
      signal<CacheChecksumAlgorithm>(CacheChecksumAlgorithm.sha256);
  final Signal<int> maxQuotaMb = signal<int>(250);

  final Signal<bool> forceRefresh = signal<bool>(false);
  final Signal<bool> fallbackOnError = signal<bool>(true);
  final Signal<bool> pinNewEntry = signal<bool>(false);
  final Signal<bool> simulateBrokenCard = signal<bool>(false);

  final Signal<CachePlatformCapabilities?> capabilities =
      signal<CachePlatformCapabilities?>(null);
  final Signal<CacheStats?> stats = signal<CacheStats?>(null);
  final Signal<List<CacheEntry>> entries = signal<List<CacheEntry>>(
    const <CacheEntry>[],
  );
  final Signal<String?> selectedTagFilter = signal<String?>(null);
  final Signal<CacheProgressEvent?> latestProgress =
      signal<CacheProgressEvent?>(null);
  final Signal<CacheFetchResult?> lastFetchResult = signal<CacheFetchResult?>(
    null,
  );
  final Signal<Uint8List?> previewBytes = signal<Uint8List?>(null);

  final Signal<String> statusLog = signal<String>(
    'Ready. Configure, download network files, or test CachedNetworkImage (104 public images).',
  );
  final Signal<String> benchmarkReport = signal<String>(
    'Click "Run 10,000+ Entries Stress Benchmark" to test high-volume index throughput.',
  );

  /// Computed gallery items list that reactively appends the simulated broken URL card.
  late final ReadonlySignal<List<Map<String, String>>> galleryItems =
      computed<List<Map<String, String>>>(() {
        final bool includeBroken = simulateBrokenCard.value;
        return <Map<String, String>>[
          ...kPublicGalleryImages,
          if (includeBroken) kBrokenGalleryCardItem,
        ];
      });

  /// Computed tag names extracted from the latest [CacheStats].
  late final ReadonlySignal<List<String>> availableTags =
      computed<List<String>>(() {
        return stats.value?.bytesByTag.keys.toList() ?? const <String>[];
      });

  StreamSubscription<CacheProgressEvent>? _progressSub;
  DateTime _lastProgressUi = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isDisposed = false;

  /// Subscribes to progress events and initializes plugin configuration.
  Future<void> initialize() async {
    _progressSub = _cache.progressStream.listen((CacheProgressEvent event) {
      if (_isDisposed) return;
      final bool terminal =
          event.state == CacheTransferState.completed ||
          event.state == CacheTransferState.failed ||
          event.state == CacheTransferState.canceled ||
          event.state == CacheTransferState.cacheHit;
      final DateTime now = DateTime.now();
      if (!terminal &&
          now.difference(_lastProgressUi) < const Duration(milliseconds: 50)) {
        return;
      }
      _lastProgressUi = now;
      latestProgress.value = event;
    });

    try {
      await applyConfiguration(silent: true);
      await refreshDashboard();
    } catch (e) {
      setLog('Initialization notice: $e');
    } finally {
      if (!_isDisposed) {
        isReady.value = true;
      }
    }
  }

  /// Releases streams and text editing controllers.
  void dispose() {
    _isDisposed = true;
    _progressSub?.cancel();
    urlController.dispose();
    customKeyController.dispose();
    tagController.dispose();
    expectedHashController.dispose();
    manualKeyController.dispose();
    manualPayloadController.dispose();
  }

  void setLog(String message) {
    if (_isDisposed) return;
    statusLog.value = message;
  }

  void selectPreset(Map<String, String> preset) {
    urlController.text = preset['url']!;
    tagController.text = preset['tag']!;
  }

  void setSimulateBrokenCard(bool enabled) {
    simulateBrokenCard.value = enabled;
    if (!enabled && latestProgress.value?.state == CacheTransferState.failed) {
      latestProgress.value = null;
    }
  }

  Future<void> selectTagFilter(String? tag) async {
    selectedTagFilter.value = tag == 'untagged' ? null : tag;
    await refreshDashboard();
  }

  Future<void> applyConfiguration({bool silent = false}) async {
    final int quotaMb = maxQuotaMb.value;
    final CacheEvictionPolicy policy = evictionPolicy.value;
    final CacheManagerConfig config = CacheManagerConfig(
      maxDiskCacheBytes: quotaMb * 1024 * 1024,
      maxEntries: 20000,
      defaultTtlSeconds: defaultTtlSeconds,
      evictionPolicy: policy,
      cacheSubdirectory: 'xue_hua_network_cache',
      maxConcurrentDownloads: 6,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      defaultHeaders: const <String, String>{
        'X-Client-Plugin': 'xue_hua_navite_cache_manager/1.2.0',
      },
      respectHttpCacheHeaders: true,
      autoTrimOnWrite: true,
    );
    await _cache.configure(config);
    if (!silent) {
      setLog(
        'Applied config: quota=${quotaMb}MB, maxEntries=20000, policy=${policy.wireValue}',
      );
      await refreshDashboard();
    }
  }

  Future<void> refreshDashboard() async {
    try {
      final CachePlatformCapabilities caps = await _cache.getCapabilities();
      final CacheStats latestStats = await _cache.getStats();
      final List<CacheEntry> latestEntries = await _cache.listEntries(
        tag: selectedTagFilter.value,
        includeExpired: true,
      );
      if (_isDisposed) return;
      batch(() {
        capabilities.value = caps;
        stats.value = latestStats;
        entries.value = latestEntries;
      });
    } catch (e) {
      setLog('Failed to refresh dashboard: $e');
    }
  }

  Future<void> handleDownload() async {
    final String url = urlController.text.trim();
    if (url.isEmpty) return;

    isBusy.value = true;
    try {
      final CacheRequest request = CacheRequest(
        url: url,
        customKey: customKeyController.text.trim().isEmpty
            ? null
            : customKeyController.text.trim(),
        tag: tagController.text.trim().isEmpty
            ? null
            : tagController.text.trim(),
        forceRefresh: forceRefresh.value,
        fallbackToCacheOnError: fallbackOnError.value,
        pinned: pinNewEntry.value,
        checksumAlgorithm: checksumAlgorithm.value,
        expectedChecksum: expectedHashController.text.trim().isEmpty
            ? null
            : expectedHashController.text.trim(),
      );
      final CacheFetchResult result = await _cache.downloadFile(request);
      final Uint8List? bytes = await _cache.readCacheBytes(result.entry.key);
      if (_isDisposed) return;
      batch(() {
        lastFetchResult.value = result;
        previewBytes.value = bytes;
      });
      setLog(
        'Resolved [${result.source.wireValue}] in ${result.elapsedMs}ms '
        '(${formatByteSize(result.entry.sizeBytes)}) -> ${result.entry.filePath}',
      );
      await refreshDashboard();
    } catch (e) {
      setLog('Download error: $e');
    } finally {
      if (!_isDisposed) {
        isBusy.value = false;
      }
    }
  }

  Future<void> handlePrefetchBatch() async {
    isBusy.value = true;
    try {
      final List<CacheRequest> requests = kSampleUrls
          .map(
            (Map<String, String> item) => CacheRequest(
              url: item['url']!,
              tag: item['tag'],
              checksumAlgorithm: CacheChecksumAlgorithm.sha256,
            ),
          )
          .toList();
      final List<CacheEntry> prefetched = await _cache.prefetchAll(requests);
      setLog('Batch prefetched ${prefetched.length} network files.');
      await refreshDashboard();
    } catch (e) {
      setLog('Batch prefetch error: $e');
    } finally {
      if (!_isDisposed) {
        isBusy.value = false;
      }
    }
  }

  Future<void> handleCancelInFlight() async {
    final bool canceled = await _cache.cancelDownload(
      urlController.text.trim(),
    );
    setLog('Cancel download result: $canceled');
  }

  Future<void> handlePrefetchGalleryImages(int count) async {
    isBusy.value = true;
    try {
      final List<Map<String, String>> subset = kPublicGalleryImages
          .take(count)
          .toList();
      final List<CacheRequest> requests = subset
          .map(
            (Map<String, String> item) =>
                CacheRequest(url: item['url']!, tag: 'gallery'),
          )
          .toList();
      final List<CacheEntry> prefetched = await _cache.prefetchAll(requests);
      setLog(
        'Prefetched ${prefetched.length}/$count gallery images into persistent disk cache.',
      );
      await refreshDashboard();
    } catch (e) {
      setLog('Gallery prefetch error: $e');
    } finally {
      if (!_isDisposed) {
        isBusy.value = false;
      }
    }
  }

  void clearMemoryImageCacheOnly() {
    PaintingBinding.instance.imageCache.clear();
    setLog(
      'Cleared Flutter memory ImageCache. Scrolling now loads directly from persistent disk cache!',
    );
  }

  Future<void> clearGalleryDiskAndMemory() async {
    final int removed = await _cache.removeByTag('gallery');
    PaintingBinding.instance.imageCache.clear();
    latestProgress.value = null;
    await refreshDashboard();
    setLog('Evicted $removed "gallery" images from disk and memory cache.');
  }

  Future<void> handlePutBytes() async {
    final String key = manualKeyController.text.trim();
    final String text = manualPayloadController.text;
    if (key.isEmpty) return;

    try {
      final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
      final CacheEntry entry = await _cache.putBytes(
        key: key,
        bytes: bytes,
        fileExtension: 'json',
        mimeType: 'application/json',
        tag: 'config',
        pinned: true,
      );
      setLog(
        'Stored manual bytes under key="${entry.key}" (${entry.sizeBytes} B, SHA-256=${entry.checksum?.substring(0, 12)}...)',
      );
      await refreshDashboard();
    } catch (e) {
      setLog('putBytes failed: $e');
    }
  }

  Future<void> handleOfflineLookup() async {
    final String key = manualKeyController.text.trim();
    final bool exists = await _cache.containsKey(key);
    final CacheEntry? entry = await _cache.getFileFromCache(key);
    setLog(
      'Offline lookup for "$key": containsKey=$exists, path=${entry?.filePath ?? "none"}',
    );
  }

  Future<void> handleRemoveConfigTag() async {
    final int count = await _cache.removeByTag('config');
    setLog('Removed $count entries with tag="config".');
    await refreshDashboard();
  }

  Future<void> runBulkBenchmark(int count) async {
    batch(() {
      isBusy.value = true;
      benchmarkReport.value = 'Running $count-entry benchmark...';
    });
    try {
      final Stopwatch swWrite = Stopwatch()..start();
      final Uint8List sampleBytes = Uint8List.fromList(
        '{"bench":true}'.codeUnits,
      );
      for (int i = 0; i < count; i++) {
        await _cache.putBytes(
          key: 'bench_key_$i',
          bytes: sampleBytes,
          fileExtension: 'json',
          mimeType: 'application/json',
          tag: 'benchmark',
        );
      }
      swWrite.stop();

      final Stopwatch swLookup = Stopwatch()..start();
      int hits = 0;
      for (int i = 0; i < count; i++) {
        if (await _cache.containsKey('bench_key_$i')) {
          hits++;
        }
      }
      swLookup.stop();

      final Stopwatch swCleanup = Stopwatch()..start();
      final int removed = await _cache.removeByTag('benchmark');
      swCleanup.stop();

      final String report =
          'Benchmark ($count entries) passed:\n'
          '• Write $count entries: ${swWrite.elapsedMilliseconds} ms\n'
          '• O(1) Lookup $count entries ($hits hits): ${swLookup.elapsedMilliseconds} ms\n'
          '• Tag Eviction ($removed removed): ${swCleanup.elapsedMilliseconds} ms';
      if (_isDisposed) return;
      benchmarkReport.value = report;
      setLog('Completed $count-entry benchmark.');
      await refreshDashboard();
    } catch (e) {
      setLog('Benchmark error: $e');
    } finally {
      if (!_isDisposed) {
        isBusy.value = false;
      }
    }
  }

  Future<void> inspectEntry(CacheEntry entry) async {
    try {
      final Uint8List? bytes = await _cache.readCacheBytes(
        entry.key,
        ignoreExpired: false,
      );
      if (_isDisposed) return;
      previewBytes.value = bytes;
      setLog(
        'Loaded "${entry.key}" from cache (${formatByteSize(entry.sizeBytes)}, hits=${entry.hitCount}).',
      );
      await refreshDashboard();
    } catch (e) {
      setLog('Failed to read entry bytes: $e');
    }
  }

  Future<void> togglePinEntry(CacheEntry entry) async {
    await _cache.setPinned(entry.key, pinned: !entry.pinned);
    await refreshDashboard();
  }

  Future<void> deleteEntry(CacheEntry entry) async {
    await _cache.removeFile(entry.key);
    setLog('Removed entry ${entry.key}');
    await refreshDashboard();
  }

  Future<void> purgeExpired() async {
    final int count = await _cache.removeExpired();
    setLog('Removed $count expired entries.');
    await refreshDashboard();
  }

  Future<void> trimToOneMegabyte() async {
    final int count = await _cache.trimToSize(1024 * 1024);
    setLog('Trimmed cache to 1 MB (evicted $count entries).');
    await refreshDashboard();
  }

  Future<void> clearUnpinned() async {
    final int count = await _cache.clearAll(includePinned: false);
    setLog('Cleared $count unpinned entries (pinned preserved).');
    await refreshDashboard();
  }

  Future<void> clearAllEntries() async {
    final int count = await _cache.clearAll(includePinned: true);
    setLog('Cleared all $count entries.');
    await refreshDashboard();
  }
}
