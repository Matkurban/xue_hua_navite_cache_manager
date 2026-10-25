import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

void main() {
  runApp(const CacheManagerDemoApp());
}

/// Comprehensive full-feature example application for `xue_hua_navite_cache_manager` v1.1.0.
class CacheManagerDemoApp extends StatelessWidget {
  const CacheManagerDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XueHua Native Cache Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0066CC),
        useMaterial3: true,
      ),
      home: const CacheWorkbenchPage(),
    );
  }
}

class CacheWorkbenchPage extends StatefulWidget {
  const CacheWorkbenchPage({super.key});

  @override
  State<CacheWorkbenchPage> createState() => _CacheWorkbenchPageState();
}

class _CacheWorkbenchPageState extends State<CacheWorkbenchPage> {
  final XueHuaNaviteCacheManager _cache = XueHuaNaviteCacheManager.instance;

  final TextEditingController _urlController = TextEditingController(
    text: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
  );
  final TextEditingController _customKeyController = TextEditingController();
  final TextEditingController _tagController = TextEditingController(
    text: 'images',
  );
  final TextEditingController _expectedHashController = TextEditingController();
  final TextEditingController _manualKeyController = TextEditingController(
    text: 'app_offline_manifest',
  );
  final TextEditingController _manualPayloadController = TextEditingController(
    text: '{"version":"1.1.0","environment":"production","offlineReady":true}',
  );

  CacheEvictionPolicy _evictionPolicy = CacheEvictionPolicy.lru;
  CacheChecksumAlgorithm _checksumAlgorithm = CacheChecksumAlgorithm.sha256;
  int _maxQuotaMb = 100;
  final int _defaultTtlSeconds = 3600;
  bool _forceRefresh = false;
  bool _fallbackOnError = true;
  bool _pinNewEntry = false;

  CachePlatformCapabilities? _capabilities;
  CacheStats? _stats;
  List<CacheEntry> _entries = const <CacheEntry>[];
  String? _selectedTagFilter;
  CacheProgressEvent? _latestProgress;
  CacheFetchResult? _lastFetchResult;
  Uint8List? _previewBytes;
  String _statusLog =
      'Ready. Configure, download network files, or test CachedNetworkImage.';
  String _benchmarkReport =
      'Click "Run 10,000+ Entries Stress Benchmark" to test high-volume index throughput.';
  bool _isBusy = false;

  StreamSubscription<CacheProgressEvent>? _progressSub;

  static const List<Map<String, String>> _sampleUrls = <Map<String, String>>[
    <String, String>{
      'label': 'Owl Image (JPG)',
      'url':
          'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
      'tag': 'images',
    },
    <String, String>{
      'label': 'Falcon Image (JPG)',
      'url':
          'https://flutter.github.io/assets-for-api-docs/assets/widgets/falcon.jpg',
      'tag': 'images',
    },
    <String, String>{
      'label': 'Puffin Image (JPG)',
      'url':
          'https://flutter.github.io/assets-for-api-docs/assets/widgets/puffin.jpg',
      'tag': 'images',
    },
    <String, String>{
      'label': 'Butterfly Video (MP4)',
      'url':
          'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4',
      'tag': 'videos',
    },
  ];

  @override
  void initState() {
    super.initState();
    _progressSub = _cache.progressStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _latestProgress = event;
      });
    });
    _initializePlugin();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _urlController.dispose();
    _customKeyController.dispose();
    _tagController.dispose();
    _expectedHashController.dispose();
    _manualKeyController.dispose();
    _manualPayloadController.dispose();
    super.dispose();
  }

  Future<void> _initializePlugin() async {
    try {
      await _applyConfiguration(silent: true);
      await _refreshDashboard();
    } catch (e) {
      _setLog('Initialization notice: $e');
    }
  }

  void _setLog(String message) {
    if (!mounted) return;
    setState(() {
      _statusLog = message;
    });
  }

  Future<void> _applyConfiguration({bool silent = false}) async {
    final config = CacheManagerConfig(
      maxDiskCacheBytes: _maxQuotaMb * 1024 * 1024,
      maxEntries: 20000,
      defaultTtlSeconds: _defaultTtlSeconds,
      evictionPolicy: _evictionPolicy,
      cacheSubdirectory: 'xue_hua_demo_cache',
      maxConcurrentDownloads: 4,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      defaultHeaders: const <String, String>{
        'X-Client-Plugin': 'xue_hua_navite_cache_manager/1.1.0',
      },
      respectHttpCacheHeaders: true,
      autoTrimOnWrite: true,
    );
    await _cache.configure(config);
    if (!silent) {
      _setLog(
        'Applied config: quota=${_maxQuotaMb}MB, maxEntries=20000, policy=${_evictionPolicy.wireValue}',
      );
      await _refreshDashboard();
    }
  }

  Future<void> _refreshDashboard() async {
    try {
      final caps = await _cache.getCapabilities();
      final stats = await _cache.getStats();
      final entries = await _cache.listEntries(
        tag: _selectedTagFilter,
        includeExpired: true,
      );
      if (!mounted) return;
      setState(() {
        _capabilities = caps;
        _stats = stats;
        _entries = entries;
      });
    } catch (e) {
      _setLog('Failed to refresh dashboard: $e');
    }
  }

  Future<void> _handleDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isBusy = true;
    });
    try {
      final request = CacheRequest(
        url: url,
        customKey: _customKeyController.text.trim().isEmpty
            ? null
            : _customKeyController.text.trim(),
        tag: _tagController.text.trim().isEmpty
            ? null
            : _tagController.text.trim(),
        forceRefresh: _forceRefresh,
        fallbackToCacheOnError: _fallbackOnError,
        pinned: _pinNewEntry,
        checksumAlgorithm: _checksumAlgorithm,
        expectedChecksum: _expectedHashController.text.trim().isEmpty
            ? null
            : _expectedHashController.text.trim(),
      );
      final result = await _cache.downloadFile(request);
      final bytes = await _cache.readCacheBytes(result.entry.key);
      if (!mounted) return;
      setState(() {
        _lastFetchResult = result;
        _previewBytes = bytes;
      });
      _setLog(
        'Resolved [${result.source.wireValue}] in ${result.elapsedMs}ms '
        '(${_formatBytes(result.entry.sizeBytes)}) -> ${result.entry.filePath}',
      );
      await _refreshDashboard();
    } catch (e) {
      _setLog('Download error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _handlePrefetchBatch() async {
    setState(() {
      _isBusy = true;
    });
    try {
      final requests = _sampleUrls
          .map(
            (item) => CacheRequest(
              url: item['url']!,
              tag: item['tag'],
              checksumAlgorithm: CacheChecksumAlgorithm.sha256,
            ),
          )
          .toList();
      final prefetched = await _cache.prefetchAll(requests);
      _setLog('Batch prefetched ${prefetched.length} network files.');
      await _refreshDashboard();
    } catch (e) {
      _setLog('Batch prefetch error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _handlePutBytes() async {
    final key = _manualKeyController.text.trim();
    final text = _manualPayloadController.text;
    if (key.isEmpty) return;

    try {
      final bytes = Uint8List.fromList(utf8.encode(text));
      final entry = await _cache.putBytes(
        key: key,
        bytes: bytes,
        fileExtension: 'json',
        mimeType: 'application/json',
        tag: 'config',
        pinned: true,
      );
      _setLog(
        'Stored manual bytes under key="${entry.key}" (${entry.sizeBytes} B, SHA-256=${entry.checksum?.substring(0, 12)}...)',
      );
      await _refreshDashboard();
    } catch (e) {
      _setLog('putBytes failed: $e');
    }
  }

  Future<void> _runBulkBenchmark(int count) async {
    setState(() {
      _isBusy = true;
      _benchmarkReport = 'Running $count-entry benchmark...';
    });
    try {
      final swWrite = Stopwatch()..start();
      final sampleBytes = Uint8List.fromList('{"bench":true}'.codeUnits);
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

      final swLookup = Stopwatch()..start();
      int hits = 0;
      for (int i = 0; i < count; i++) {
        if (await _cache.containsKey('bench_key_$i')) {
          hits++;
        }
      }
      swLookup.stop();

      final swCleanup = Stopwatch()..start();
      final removed = await _cache.removeByTag('benchmark');
      swCleanup.stop();

      final report =
          'Benchmark ($count entries) passed:\n'
          '• Write $count entries: ${swWrite.elapsedMilliseconds} ms\n'
          '• O(1) Lookup $count entries ($hits hits): ${swLookup.elapsedMilliseconds} ms\n'
          '• Tag Eviction ($removed removed): ${swCleanup.elapsedMilliseconds} ms';
      if (!mounted) return;
      setState(() {
        _benchmarkReport = report;
      });
      _setLog('Completed $count-entry benchmark.');
      await _refreshDashboard();
    } catch (e) {
      _setLog('Benchmark error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _inspectEntry(CacheEntry entry) async {
    try {
      final bytes = await _cache.readCacheBytes(
        entry.key,
        ignoreExpired: false,
      );
      if (!mounted) return;
      setState(() {
        _previewBytes = bytes;
      });
      _setLog(
        'Loaded "${entry.key}" from cache (${_formatBytes(entry.sizeBytes)}, hits=${entry.hitCount}).',
      );
      await _refreshDashboard();
    } catch (e) {
      _setLog('Failed to read entry bytes: $e');
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('XueHua Native Cache Manager'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Refresh Stats',
              onPressed: _refreshDashboard,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: <Widget>[
              Tab(icon: Icon(Icons.cloud_download), text: 'Download & Fetch'),
              Tab(icon: Icon(Icons.photo_library), text: 'CachedNetworkImage'),
              Tab(icon: Icon(Icons.folder_special), text: 'Cache Browser'),
              Tab(icon: Icon(Icons.memory), text: 'Manual Put & 10K Bench'),
              Tab(icon: Icon(Icons.tune), text: 'Config & Capabilities'),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            _buildStatusBanner(),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _buildDownloadTab(),
                  _buildCachedImageGalleryTab(),
                  _buildCacheBrowserTab(),
                  _buildManualPutTab(),
                  _buildConfigAndCapabilitiesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final progress = _latestProgress;
    final stats = _stats;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusLog,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (stats != null)
                Chip(
                  label: Text(
                    '${stats.totalEntries} files • ${_formatBytes(stats.totalBytes)} • Hit ${(stats.hitRate * 100).toStringAsFixed(0)}%',
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (progress != null) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Text(
                  'Event [${progress.state.wireValue}]: ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress.progress,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_formatBytes(progress.bytesReceived)}'
                  '${progress.totalBytes > 0 ? " / ${_formatBytes(progress.totalBytes)}" : ""}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadTab() {
    final res = _lastFetchResult;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Preset Network Resources',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _sampleUrls.map((preset) {
                    return ActionChip(
                      avatar: const Icon(Icons.link, size: 16),
                      label: Text(preset['label']!),
                      onPressed: () {
                        setState(() {
                          _urlController.text = preset['url']!;
                          _tagController.text = preset['tag']!;
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Remote File URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _customKeyController,
                        decoration: const InputDecoration(
                          labelText: 'Custom Key (Optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _tagController,
                        decoration: const InputDecoration(
                          labelText: 'Category Tag (e.g. images)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    DropdownButton<CacheChecksumAlgorithm>(
                      value: _checksumAlgorithm,
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _checksumAlgorithm = val);
                        }
                      },
                      items: CacheChecksumAlgorithm.values
                          .map(
                            (alg) => DropdownMenuItem<CacheChecksumAlgorithm>(
                              value: alg,
                              child: Text('Hash: ${alg.wireValue.toUpperCase()}'),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _expectedHashController,
                        decoration: const InputDecoration(
                          labelText: 'Expected Checksum Hex (Optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    FilterChip(
                      label: const Text('Force Refresh'),
                      selected: _forceRefresh,
                      onSelected: (v) => setState(() => _forceRefresh = v),
                    ),
                    FilterChip(
                      label: const Text('Fallback to Stale Cache on Error'),
                      selected: _fallbackOnError,
                      onSelected: (v) => setState(() => _fallbackOnError = v),
                    ),
                    FilterChip(
                      label: const Text('Pin Entry (Prevent Eviction)'),
                      selected: _pinNewEntry,
                      onSelected: (v) => setState(() => _pinNewEntry = v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _isBusy ? null : _handleDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Fetch / Cache File'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : _handlePrefetchBatch,
                      icon: const Icon(Icons.playlist_add_check),
                      label: const Text('Batch Prefetch Presets'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final canceled = await _cache.cancelDownload(
                          _urlController.text.trim(),
                        );
                        _setLog('Cancel download result: $canceled');
                      },
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel In-Flight'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (res != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Last Fetch Result (${res.source.wireValue})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text('Key: ${res.entry.key}'),
                  Text('Local Path / URI: ${res.entry.filePath}'),
                  Text(
                    'Size: ${_formatBytes(res.entry.sizeBytes)} • Elapsed: ${res.elapsedMs} ms • HTTP: ${res.httpStatusCode ?? "N/A (Cache Hit)"}',
                  ),
                  Text(
                    'MIME: ${res.entry.mimeType ?? "unknown"} • Hits: ${res.entry.hitCount} • Pinned: ${res.entry.pinned}',
                  ),
                  if (res.entry.checksum != null)
                    Text(
                      'Checksum (${res.entry.checksumAlgorithm.wireValue}): ${res.entry.checksum}',
                    ),
                  if (_previewBytes != null &&
                      (res.entry.mimeType?.startsWith('image/') ?? false)) ...<Widget>[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _previewBytes!,
                        height: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCachedImageGalleryTab() {
    final galleryItems = <Map<String, String>>[
      <String, String>{
        'title': 'Owl (Downsampled 400px + Progress)',
        'url':
            'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
      },
      <String, String>{
        'title': 'Falcon (Downsampled 400px + Pinned)',
        'url':
            'https://flutter.github.io/assets-for-api-docs/assets/widgets/falcon.jpg',
      },
      <String, String>{
        'title': 'Puffin (Custom Circle imageBuilder)',
        'url':
            'https://flutter.github.io/assets-for-api-docs/assets/widgets/puffin.jpg',
      },
      <String, String>{
        'title': 'Broken URL (Error Widget Fallback)',
        'url': 'https://invalid.xuehua.local/non_existent_image.png',
      },
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'CachedNetworkImage & CachedNetworkImageProvider',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Zero-jank image caching with synchronous ImageCache fast-path, '
                  'Engine IO ImmutableBuffer.fromFilePath decoding, and C++ codec downsampling (memCacheWidth).',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () {
                        PaintingBinding.instance.imageCache.clear();
                        setState(() {});
                        _setLog(
                          'Cleared Flutter in-memory ImageCache (next render will hit native disk cache).',
                        );
                      },
                      icon: const Icon(Icons.memory),
                      label: const Text('Clear Memory ImageCache'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await _cache.removeByTag('gallery');
                        PaintingBinding.instance.imageCache.clear();
                        setState(() {});
                        await _refreshDashboard();
                        _setLog('Cleared gallery disk & memory cache.');
                      },
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Evict "gallery" Tag'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 320,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
          ),
          itemCount: galleryItems.length,
          itemBuilder: (context, index) {
            final item = galleryItems[index];
            final isCircleDemo = index == 2;
            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: CachedNetworkImage(
                      imageUrl: item['url']!,
                      tag: 'gallery',
                      pinned: index == 1,
                      memCacheWidth: 400,
                      fit: BoxFit.cover,
                      imageBuilder: isCircleDemo
                          ? (context, provider) => Center(
                              child: CircleAvatar(
                                radius: 64,
                                backgroundImage: provider,
                              ),
                            )
                          : null,
                      progressIndicatorBuilder: (context, url, progress) {
                        final double? ratio =
                            progress?.expectedTotalBytes != null &&
                                progress!.expectedTotalBytes! > 0
                            ? progress.cumulativeBytesLoaded /
                                  progress.expectedTotalBytes!
                            : null;
                        return Center(
                          child: CircularProgressIndicator(value: ratio),
                        );
                      },
                      errorWidget: (context, url, error, stackTrace) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.broken_image_outlined,
                                size: 36,
                                color: Colors.redAccent,
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Load Failed (Fallback)',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      item['title']!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCacheBrowserTab() {
    final stats = _stats;
    final tags = stats?.bytesByTag.keys.toList() ?? const <String>[];

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              ChoiceChip(
                label: const Text('All Tags'),
                selected: _selectedTagFilter == null,
                onSelected: (_) {
                  setState(() => _selectedTagFilter = null);
                  _refreshDashboard();
                },
              ),
              ...tags.map(
                (t) => ChoiceChip(
                  label: Text(
                    '$t (${_formatBytes(stats?.bytesByTag[t] ?? 0)})',
                  ),
                  selected: _selectedTagFilter == t,
                  onSelected: (_) {
                    setState(
                      () => _selectedTagFilter = t == 'untagged' ? null : t,
                    );
                    _refreshDashboard();
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final count = await _cache.removeExpired();
                  _setLog('Removed $count expired entries.');
                  await _refreshDashboard();
                },
                icon: const Icon(Icons.timer_off_outlined, size: 18),
                label: const Text('Purge Expired'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final count = await _cache.trimToSize(1024 * 1024); // 1 MB
                  _setLog('Trimmed cache to 1 MB (evicted $count entries).');
                  await _refreshDashboard();
                },
                icon: const Icon(Icons.compress, size: 18),
                label: const Text('Trim to 1 MB'),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final count = await _cache.clearAll(includePinned: false);
                  _setLog('Cleared $count unpinned entries (pinned preserved).');
                  await _refreshDashboard();
                },
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: const Text('Clear Unpinned'),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final count = await _cache.clearAll(includePinned: true);
                  _setLog('Cleared all $count entries.');
                  await _refreshDashboard();
                },
                icon: const Icon(Icons.delete_forever, size: 18),
                label: const Text('Clear All'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _entries.isEmpty
              ? const Center(
                  child: Text('No cached files match the current filter.'),
                )
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: Icon(
                          entry.pinned ? Icons.push_pin : Icons.insert_drive_file,
                          color: entry.pinned
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(
                          entry.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'Key: ${entry.key.length > 16 ? "${entry.key.substring(0, 16)}..." : entry.key} • '
                          '${_formatBytes(entry.sizeBytes)} • Hits: ${entry.hitCount} • '
                          'Tag: ${entry.tag ?? "none"} • Expired: ${entry.isExpired}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: entry.pinned ? 'Unpin' : 'Pin',
                              icon: Icon(
                                entry.pinned
                                    ? Icons.lock
                                    : Icons.lock_open_outlined,
                              ),
                              onPressed: () async {
                                await _cache.setPinned(
                                  entry.key,
                                  pinned: !entry.pinned,
                                );
                                await _refreshDashboard();
                              },
                            ),
                            IconButton(
                              tooltip: 'Read Bytes',
                              icon: const Icon(Icons.visibility_outlined),
                              onPressed: () => _inspectEntry(entry),
                            ),
                            IconButton(
                              tooltip: 'Delete Entry',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await _cache.removeFile(entry.key);
                                _setLog('Removed entry ${entry.key}');
                                await _refreshDashboard();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildManualPutTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Store In-Memory Bytes (putBytes)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _manualKeyController,
                  decoration: const InputDecoration(
                    labelText: 'Cache Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _manualPayloadController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'UTF-8 Payload to Cache',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _handlePutBytes,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Put Bytes into Cache'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final key = _manualKeyController.text.trim();
                        final exists = await _cache.containsKey(key);
                        final entry = await _cache.getFileFromCache(key);
                        _setLog(
                          'Offline lookup for "$key": containsKey=$exists, path=${entry?.filePath ?? "none"}',
                        );
                      },
                      icon: const Icon(Icons.search),
                      label: const Text('Check Offline Cache (getFileFromCache)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final count = await _cache.removeByTag('config');
                        _setLog('Removed $count entries with tag="config".');
                        await _refreshDashboard();
                      },
                      icon: const Icon(Icons.label_off_outlined),
                      label: const Text('Remove Tag "config"'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'High-Volume 10,000+ Cache Entries Stress Benchmark',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(_benchmarkReport),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _isBusy ? null : () => _runBulkBenchmark(1000),
                      icon: const Icon(Icons.speed),
                      label: const Text('Run 1,000 Entries Benchmark'),
                    ),
                    FilledButton.icon(
                      onPressed: _isBusy
                          ? null
                          : () => _runBulkBenchmark(10000),
                      icon: const Icon(Icons.bolt),
                      label: const Text(
                        'Run 10,000+ Entries Stress Benchmark',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigAndCapabilitiesTab() {
    final caps = _capabilities;
    final stats = _stats;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Global Cache Configuration',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    const Text('Eviction Policy: '),
                    const SizedBox(width: 12),
                    DropdownButton<CacheEvictionPolicy>(
                      value: _evictionPolicy,
                      onChanged: (policy) {
                        if (policy != null) {
                          setState(() => _evictionPolicy = policy);
                        }
                      },
                      items: CacheEvictionPolicy.values
                          .map(
                            (p) => DropdownMenuItem<CacheEvictionPolicy>(
                              value: p,
                              child: Text(p.wireValue.toUpperCase()),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Max Disk Quota: $_maxQuotaMb MB'),
                Slider(
                  value: _maxQuotaMb.toDouble(),
                  min: 5,
                  max: 500,
                  divisions: 99,
                  label: '$_maxQuotaMb MB',
                  onChanged: (v) => setState(() => _maxQuotaMb = v.round()),
                ),
                FilledButton.icon(
                  onPressed: () => _applyConfiguration(),
                  icon: const Icon(Icons.check),
                  label: const Text('Apply Configuration'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (caps != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Host Platform Capabilities (${caps.platformName.toUpperCase()})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text('Storage Engine: ${caps.storageMechanism}'),
                  Text('Default Cache Root: ${caps.defaultCacheRootPath}'),
                  Text(
                    'Supports Native OS File Paths: ${caps.supportsFileSystemPaths}',
                  ),
                  Text(
                    'Supports HTTP 304 Revalidation: ${caps.supportsConditionalHttpRevalidation}',
                  ),
                  Text(
                    'Supports Native Crypto Hashing: ${caps.supportsNativeCryptoHash}',
                  ),
                  Text(
                    'OS Low-Disk-Space Auto-Purge: ${caps.supportsLowDiskSpaceNotifications}',
                  ),
                ],
              ),
            ),
          ),
        if (stats != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Live Cache Telemetry',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text('Total Entries: ${stats.totalEntries}'),
                  Text('Total Size: ${_formatBytes(stats.totalBytes)}'),
                  Text(
                    'Quota Usage: ${(stats.quotaUsageRatio * 100).toStringAsFixed(1)}%',
                  ),
                  Text(
                    'Hits / Misses / Evictions: ${stats.hitCount} / ${stats.missCount} / ${stats.evictionCount}',
                  ),
                  Text('Pinned Entries: ${stats.pinnedEntries}'),
                  Text('Expired Entries: ${stats.expiredEntries}'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
