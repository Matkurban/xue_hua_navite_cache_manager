import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'src/cache_hash_utils.dart';
import 'src/cache_models.dart';
import 'xue_hua_navite_cache_manager_platform_interface.dart';

/// Web implementation of [XueHuaNaviteCacheManagerPlatform] backed by the browser
/// `CacheStorage` API (`window.caches`), `localStorage` metadata index, `fetch()`,
/// and `Blob` object URLs with automatic in-memory fallback.
class XueHuaNaviteCacheManagerWeb extends XueHuaNaviteCacheManagerPlatform {
  /// Constructs a [XueHuaNaviteCacheManagerWeb].
  XueHuaNaviteCacheManagerWeb();

  /// Registers [XueHuaNaviteCacheManagerWeb] as the default platform instance.
  static void registerWith(Registrar registrar) {
    XueHuaNaviteCacheManagerPlatform.instance = XueHuaNaviteCacheManagerWeb();
  }

  final StreamController<CacheProgressEvent> _progressController =
      StreamController<CacheProgressEvent>.broadcast();

  CacheManagerConfig _config = const CacheManagerConfig();
  final Map<String, CacheEntry> _index = <String, CacheEntry>{};
  final Map<String, Uint8List> _memoryBlobs = <String, Uint8List>{};
  final Map<String, String> _blobUrls = <String, String>{};
  final Map<String, web.AbortController> _activeAborts =
      <String, web.AbortController>{};
  final Map<String, Future<CacheFetchResult>> _inFlightRequests =
      <String, Future<CacheFetchResult>>{};

  bool _initialized = false;
  int _hitCount = 0;
  int _missCount = 0;
  int _evictionCount = 0;

  String get _storageKey => 'xue_hua_cache_index_${_config.cacheSubdirectory}';

  @override
  Stream<CacheProgressEvent> get progressStream => _progressController.stream;

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    try {
      final raw = web.window.localStorage.getItem(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final entriesList = decoded['entries'];
          if (entriesList is List) {
            for (final item in entriesList) {
              if (item is Map) {
                final entry = CacheEntry.fromMap(item.cast<Object?, Object?>());
                _index[entry.key] = entry;
              }
            }
          }
          _hitCount = (decoded['hitCount'] as num?)?.toInt() ?? 0;
          _missCount = (decoded['missCount'] as num?)?.toInt() ?? 0;
          _evictionCount = (decoded['evictionCount'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {
      // Ignore localStorage quota or security errors in restricted iframes.
    }
  }

  void _persistIndex() {
    try {
      final payload = jsonEncode(<String, Object?>{
        'hitCount': _hitCount,
        'missCount': _missCount,
        'evictionCount': _evictionCount,
        'entries': _index.values.map((e) => e.toMap()).toList(),
      });
      web.window.localStorage.setItem(_storageKey, payload);
    } catch (_) {}
  }

  String _resolveKey(String keyOrUrl, {String? customKey}) {
    if (customKey != null && customKey.trim().isNotEmpty) {
      return customKey.trim();
    }
    if (_index.containsKey(keyOrUrl)) {
      return keyOrUrl;
    }
    return CacheHashUtils.sha256String(keyOrUrl);
  }

  Future<void> _putBrowserCacheBytes(
    String key,
    Uint8List bytes,
    String mimeType,
  ) async {
    _memoryBlobs[key] = bytes;
    try {
      final cache = await web.window.caches
          .open(_config.cacheSubdirectory)
          .toDart;
      final jsBytes = bytes.toJS;
      final blobParts = <JSAny>[jsBytes].toJS;
      final blob = web.Blob(blobParts, web.BlobPropertyBag(type: mimeType));
      final oldUrl = _blobUrls[key];
      if (oldUrl != null) {
        web.URL.revokeObjectURL(oldUrl);
      }
      _blobUrls[key] = web.URL.createObjectURL(blob);
      final responseInit = web.ResponseInit(
        status: 200,
        headers:
            (<String, String>{'Content-Type': mimeType}).jsify()
                as web.HeadersInit,
      );
      final response = web.Response(blob, responseInit);
      await cache.put('https://xuehua.cache.local/$key'.toJS, response).toDart;
    } catch (_) {
      // Fallback to _memoryBlobs when CacheStorage is unavailable (e.g. insecure HTTP context).
    }
  }

  Future<Uint8List?> _readBrowserCacheBytes(String key) async {
    final mem = _memoryBlobs[key];
    if (mem != null) {
      return mem;
    }
    try {
      final cache = await web.window.caches
          .open(_config.cacheSubdirectory)
          .toDart;
      final response = await cache
          .match('https://xuehua.cache.local/$key'.toJS)
          .toDart;
      if (response != null) {
        final buffer = await response.arrayBuffer().toDart;
        final data = buffer.toDart.asUint8List();
        _memoryBlobs[key] = data;
        return data;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _deleteBrowserCacheEntry(String key) async {
    _memoryBlobs.remove(key);
    final blobUrl = _blobUrls.remove(key);
    if (blobUrl != null) {
      try {
        web.URL.revokeObjectURL(blobUrl);
      } catch (_) {}
    }
    try {
      final cache = await web.window.caches
          .open(_config.cacheSubdirectory)
          .toDart;
      await cache.delete('https://xuehua.cache.local/$key'.toJS).toDart;
    } catch (_) {}
  }

  @override
  Future<void> configure(CacheManagerConfig config) async {
    _ensureInitialized();
    _config = config;
    if (_config.autoTrimOnWrite) {
      await _enforceQuota();
    }
  }

  @override
  Future<CacheFetchResult> downloadFile(CacheRequest request) async {
    _ensureInitialized();
    final key = _resolveKey(request.url, customKey: request.customKey);

    final inFlight = _inFlightRequests[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _executeDownload(key, request);
    _inFlightRequests[key] = future;
    try {
      return await future;
    } finally {
      _inFlightRequests.remove(key);
    }
  }

  Future<CacheFetchResult> _executeDownload(
    String key,
    CacheRequest request,
  ) async {
    final startTime = DateTime.now().millisecondsSinceEpoch;
    final existing = _index[key];

    if (!request.forceRefresh && existing != null && !existing.isExpired) {
      final bytes = await _readBrowserCacheBytes(key);
      if (bytes != null) {
        _hitCount++;
        final now = DateTime.now().millisecondsSinceEpoch;
        final updated = CacheEntry(
          key: existing.key,
          url: existing.url,
          filePath: _blobUrls[key] ?? existing.filePath,
          sizeBytes: existing.sizeBytes,
          createdAtMs: existing.createdAtMs,
          lastAccessedAtMs: now,
          expiresAtMs: existing.expiresAtMs,
          hitCount: existing.hitCount + 1,
          tag: request.tag ?? existing.tag,
          mimeType: existing.mimeType,
          eTag: existing.eTag,
          lastModified: existing.lastModified,
          checksum: existing.checksum,
          checksumAlgorithm: existing.checksumAlgorithm,
          pinned: request.pinned || existing.pinned,
        );
        _index[key] = updated;
        _persistIndex();
        _progressController.add(
          CacheProgressEvent(
            key: key,
            url: request.url,
            state: CacheTransferState.cacheHit,
            bytesReceived: updated.sizeBytes,
            totalBytes: updated.sizeBytes,
            filePath: updated.filePath,
          ),
        );
        return CacheFetchResult(
          entry: updated,
          source: CacheResultSource.cacheHit,
          elapsedMs: DateTime.now().millisecondsSinceEpoch - startTime,
        );
      }
    }

    _missCount++;
    _progressController.add(
      CacheProgressEvent(
        key: key,
        url: request.url,
        state: CacheTransferState.started,
        bytesReceived: 0,
        totalBytes: -1,
      ),
    );

    final abortController = web.AbortController();
    _activeAborts[key] = abortController;

    try {
      final headersMap = <String, String>{
        ..._config.defaultHeaders,
        ...request.headers,
      };
      if (_config.respectHttpCacheHeaders && existing != null) {
        if (existing.eTag != null && existing.eTag!.isNotEmpty) {
          headersMap['If-None-Match'] = existing.eTag!;
        }
        if (existing.lastModified != null &&
            existing.lastModified!.isNotEmpty) {
          headersMap['If-Modified-Since'] = existing.lastModified!;
        }
      }

      final requestInit = web.RequestInit(
        method: 'GET',
        headers: headersMap.jsify() as web.HeadersInit,
        signal: abortController.signal,
      );

      final response = await web.window
          .fetch(request.url.toJS, requestInit)
          .toDart;
      final status = response.status;

      if (status == 304 && existing != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final ttlSec = request.ttlSeconds ?? _config.defaultTtlSeconds;
        final refreshed = CacheEntry(
          key: existing.key,
          url: existing.url,
          filePath: _blobUrls[key] ?? existing.filePath,
          sizeBytes: existing.sizeBytes,
          createdAtMs: existing.createdAtMs,
          lastAccessedAtMs: now,
          expiresAtMs: now + ttlSec * 1000,
          hitCount: existing.hitCount + 1,
          tag: request.tag ?? existing.tag,
          mimeType: existing.mimeType,
          eTag: response.headers.get('etag') ?? existing.eTag,
          lastModified:
              response.headers.get('last-modified') ?? existing.lastModified,
          checksum: existing.checksum,
          checksumAlgorithm: existing.checksumAlgorithm,
          pinned: request.pinned || existing.pinned,
        );
        _index[key] = refreshed;
        _persistIndex();
        _progressController.add(
          CacheProgressEvent(
            key: key,
            url: request.url,
            state: CacheTransferState.cacheHit,
            bytesReceived: refreshed.sizeBytes,
            totalBytes: refreshed.sizeBytes,
            filePath: refreshed.filePath,
          ),
        );
        return CacheFetchResult(
          entry: refreshed,
          source: CacheResultSource.revalidated,
          httpStatusCode: 304,
          elapsedMs: DateTime.now().millisecondsSinceEpoch - startTime,
        );
      }

      if (status < 200 || status >= 300) {
        throw PlatformException(
          code: 'HTTP_ERROR',
          message: 'HTTP request failed with status $status for ${request.url}',
          details: status,
        );
      }

      final arrayBuffer = await response.arrayBuffer().toDart;
      final bytes = arrayBuffer.toDart.asUint8List();

      _progressController.add(
        CacheProgressEvent(
          key: key,
          url: request.url,
          state: CacheTransferState.inProgress,
          bytesReceived: bytes.length,
          totalBytes: bytes.length,
        ),
      );

      String? computedChecksum;
      if (request.checksumAlgorithm != CacheChecksumAlgorithm.none) {
        computedChecksum =
            request.checksumAlgorithm == CacheChecksumAlgorithm.md5
            ? CacheHashUtils.md5Hex(bytes)
            : CacheHashUtils.sha256Hex(bytes);
        if (request.expectedChecksum != null &&
            request.expectedChecksum!.isNotEmpty &&
            computedChecksum.toLowerCase() !=
                request.expectedChecksum!.trim().toLowerCase()) {
          throw PlatformException(
            code: 'CHECKSUM_MISMATCH',
            message:
                'Checksum mismatch for ${request.url}: expected ${request.expectedChecksum}, got $computedChecksum',
          );
        }
      }

      final mimeType =
          response.headers.get('content-type')?.split(';').first.trim() ??
          'application/octet-stream';
      final eTag = response.headers.get('etag');
      final lastModified = response.headers.get('last-modified');
      final cacheControl = response.headers.get('cache-control');

      var ttlSeconds = request.ttlSeconds ?? _config.defaultTtlSeconds;
      if (request.ttlSeconds == null &&
          _config.respectHttpCacheHeaders &&
          cacheControl != null) {
        final match = RegExp(r'max-age=(\d+)').firstMatch(cacheControl);
        if (match != null) {
          final parsed = int.tryParse(match.group(1)!);
          if (parsed != null && parsed >= 0) {
            ttlSeconds = parsed;
          }
        }
      }

      await _putBrowserCacheBytes(key, bytes, mimeType);
      final now = DateTime.now().millisecondsSinceEpoch;
      final entry = CacheEntry(
        key: key,
        url: request.url,
        filePath:
            _blobUrls[key] ?? 'web-cache://${_config.cacheSubdirectory}/$key',
        sizeBytes: bytes.length,
        createdAtMs: now,
        lastAccessedAtMs: now,
        expiresAtMs: now + ttlSeconds * 1000,
        hitCount: 1,
        tag: request.tag,
        mimeType: mimeType,
        eTag: eTag,
        lastModified: lastModified,
        checksum: computedChecksum,
        checksumAlgorithm: request.checksumAlgorithm,
        pinned: request.pinned,
      );

      _index[key] = entry;
      if (_config.autoTrimOnWrite) {
        await _enforceQuota(protectedKey: key);
      }
      _persistIndex();

      _progressController.add(
        CacheProgressEvent(
          key: key,
          url: request.url,
          state: CacheTransferState.completed,
          bytesReceived: bytes.length,
          totalBytes: bytes.length,
          filePath: entry.filePath,
        ),
      );

      return CacheFetchResult(
        entry: entry,
        source: CacheResultSource.networkDownload,
        httpStatusCode: status,
        elapsedMs: DateTime.now().millisecondsSinceEpoch - startTime,
      );
    } catch (error) {
      if (request.fallbackToCacheOnError && existing != null) {
        final fallbackBytes = await _readBrowserCacheBytes(key);
        if (fallbackBytes != null) {
          return CacheFetchResult(
            entry: existing,
            source: CacheResultSource.staleCacheFallback,
            elapsedMs: DateTime.now().millisecondsSinceEpoch - startTime,
          );
        }
      }
      _progressController.add(
        CacheProgressEvent(
          key: key,
          url: request.url,
          state: CacheTransferState.failed,
          bytesReceived: 0,
          totalBytes: -1,
          errorMessage: error.toString(),
        ),
      );
      rethrow;
    } finally {
      _activeAborts.remove(key);
    }
  }

  @override
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) async {
    final results = <CacheEntry>[];
    for (final request in requests) {
      try {
        final res = await downloadFile(request);
        results.add(res.entry);
      } catch (_) {}
    }
    return results;
  }

  @override
  Future<bool> cancelDownload(String keyOrUrl) async {
    _ensureInitialized();
    final key = _resolveKey(keyOrUrl);
    final controller =
        _activeAborts.remove(key) ?? _activeAborts.remove(keyOrUrl);
    if (controller != null) {
      controller.abort();
      _progressController.add(
        CacheProgressEvent(
          key: key,
          url: keyOrUrl,
          state: CacheTransferState.canceled,
          bytesReceived: 0,
          totalBytes: -1,
        ),
      );
      return true;
    }
    return false;
  }

  @override
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    _ensureInitialized();
    final key = _resolveKey(keyOrUrl);
    final entry = _index[key];
    if (entry == null) {
      _missCount++;
      return null;
    }
    if (ignoreExpired && entry.isExpired) {
      _missCount++;
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = CacheEntry(
      key: entry.key,
      url: entry.url,
      filePath: _blobUrls[key] ?? entry.filePath,
      sizeBytes: entry.sizeBytes,
      createdAtMs: entry.createdAtMs,
      lastAccessedAtMs: now,
      expiresAtMs: entry.expiresAtMs,
      hitCount: entry.hitCount + 1,
      tag: entry.tag,
      mimeType: entry.mimeType,
      eTag: entry.eTag,
      lastModified: entry.lastModified,
      checksum: entry.checksum,
      checksumAlgorithm: entry.checksumAlgorithm,
      pinned: entry.pinned,
    );
    _index[key] = updated;
    _hitCount++;
    _persistIndex();
    return updated;
  }

  @override
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final entry = await getFileFromCache(
      keyOrUrl,
      ignoreExpired: ignoreExpired,
    );
    if (entry == null) return null;
    return _readBrowserCacheBytes(entry.key);
  }

  @override
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) async {
    _ensureInitialized();
    final key = _resolveKey(keyOrUrl);
    final entry = _index[key];
    if (entry == null) return false;
    if (ignoreExpired && entry.isExpired) return false;
    return true;
  }

  @override
  Future<CacheEntry> putBytes({
    required String key,
    required Uint8List bytes,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) async {
    _ensureInitialized();
    final resolvedMime = mimeType ?? 'application/octet-stream';
    await _putBrowserCacheBytes(key, bytes, resolvedMime);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = ttlSeconds ?? _config.defaultTtlSeconds;
    final checksum = CacheHashUtils.sha256Hex(bytes);

    final entry = CacheEntry(
      key: key,
      url: url ?? 'local://$key',
      filePath:
          _blobUrls[key] ?? 'web-cache://${_config.cacheSubdirectory}/$key',
      sizeBytes: bytes.length,
      createdAtMs: now,
      lastAccessedAtMs: now,
      expiresAtMs: now + ttl * 1000,
      hitCount: 1,
      tag: tag,
      mimeType: resolvedMime,
      checksum: checksum,
      checksumAlgorithm: CacheChecksumAlgorithm.sha256,
      pinned: pinned,
    );
    _index[key] = entry;
    if (_config.autoTrimOnWrite) {
      await _enforceQuota(protectedKey: key);
    }
    _persistIndex();
    return entry;
  }

  @override
  Future<CacheEntry> putFile({
    required String key,
    required String sourceFilePath,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) async {
    final response = await web.window.fetch(sourceFilePath.toJS).toDart;
    final buffer = await response.arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
    return putBytes(
      key: key,
      bytes: bytes,
      url: url ?? sourceFilePath,
      fileExtension: fileExtension,
      mimeType: mimeType,
      tag: tag,
      ttlSeconds: ttlSeconds,
      pinned: pinned,
    );
  }

  @override
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) async {
    _ensureInitialized();
    final key = _resolveKey(keyOrUrl);
    final existing = _index[key];
    if (existing == null) return false;
    _index[key] = CacheEntry(
      key: existing.key,
      url: existing.url,
      filePath: existing.filePath,
      sizeBytes: existing.sizeBytes,
      createdAtMs: existing.createdAtMs,
      lastAccessedAtMs: existing.lastAccessedAtMs,
      expiresAtMs: existing.expiresAtMs,
      hitCount: existing.hitCount,
      tag: existing.tag,
      mimeType: existing.mimeType,
      eTag: existing.eTag,
      lastModified: existing.lastModified,
      checksum: existing.checksum,
      checksumAlgorithm: existing.checksumAlgorithm,
      pinned: pinned,
    );
    _persistIndex();
    return true;
  }

  @override
  Future<bool> removeFile(String keyOrUrl) async {
    _ensureInitialized();
    final key = _resolveKey(keyOrUrl);
    final removed = _index.remove(key);
    if (removed == null) return false;
    await _deleteBrowserCacheEntry(key);
    _persistIndex();
    return true;
  }

  @override
  Future<int> removeByTag(String tag) async {
    _ensureInitialized();
    final keysToRemove = _index.values
        .where((e) => e.tag == tag)
        .map((e) => e.key)
        .toList();
    for (final key in keysToRemove) {
      _index.remove(key);
      await _deleteBrowserCacheEntry(key);
    }
    if (keysToRemove.isNotEmpty) {
      _persistIndex();
    }
    return keysToRemove.length;
  }

  @override
  Future<int> removeExpired() async {
    _ensureInitialized();
    final expiredKeys = _index.values
        .where((e) => !e.pinned && e.isExpired)
        .map((e) => e.key)
        .toList();
    for (final key in expiredKeys) {
      _index.remove(key);
      await _deleteBrowserCacheEntry(key);
    }
    if (expiredKeys.isNotEmpty) {
      _evictionCount += expiredKeys.length;
      _persistIndex();
    }
    return expiredKeys.length;
  }

  @override
  Future<int> trimToSize(int maxBytes) async {
    _ensureInitialized();
    return _enforceQuota(targetMaxBytes: maxBytes);
  }

  Future<int> _enforceQuota({int? targetMaxBytes, String? protectedKey}) async {
    var evicted = await removeExpired();
    final maxAllowedBytes = targetMaxBytes ?? _config.maxDiskCacheBytes;
    final maxAllowedEntries = _config.maxEntries;

    if (_config.evictionPolicy == CacheEvictionPolicy.ttlOnly) {
      return evicted;
    }

    var totalBytes = _index.values.fold<int>(0, (sum, e) => sum + e.sizeBytes);
    if (totalBytes <= maxAllowedBytes && _index.length <= maxAllowedEntries) {
      return evicted;
    }

    final candidates = _index.values
        .where((e) => !e.pinned && e.key != protectedKey)
        .toList();

    candidates.sort((a, b) {
      switch (_config.evictionPolicy) {
        case CacheEvictionPolicy.lru:
          return a.lastAccessedAtMs.compareTo(b.lastAccessedAtMs);
        case CacheEvictionPolicy.lfu:
          final cmp = a.hitCount.compareTo(b.hitCount);
          return cmp != 0
              ? cmp
              : a.lastAccessedAtMs.compareTo(b.lastAccessedAtMs);
        case CacheEvictionPolicy.fifo:
          return a.createdAtMs.compareTo(b.createdAtMs);
        case CacheEvictionPolicy.ttlOnly:
          return a.expiresAtMs.compareTo(b.expiresAtMs);
      }
    });

    for (final candidate in candidates) {
      if (totalBytes <= maxAllowedBytes && _index.length <= maxAllowedEntries) {
        break;
      }
      _index.remove(candidate.key);
      await _deleteBrowserCacheEntry(candidate.key);
      totalBytes -= candidate.sizeBytes;
      evicted++;
      _evictionCount++;
    }

    if (evicted > 0) {
      _persistIndex();
    }
    return evicted;
  }

  @override
  Future<int> clearAll({bool includePinned = true}) async {
    _ensureInitialized();
    final keysToRemove = _index.values
        .where((e) => includePinned || !e.pinned)
        .map((e) => e.key)
        .toList();
    for (final key in keysToRemove) {
      _index.remove(key);
      await _deleteBrowserCacheEntry(key);
    }
    _persistIndex();
    return keysToRemove.length;
  }

  @override
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) async {
    _ensureInitialized();
    final list = _index.values.where((entry) {
      if (tag != null && entry.tag != tag) return false;
      if (!includeExpired && entry.isExpired) return false;
      return true;
    }).toList();
    list.sort((a, b) => b.lastAccessedAtMs.compareTo(a.lastAccessedAtMs));
    return list;
  }

  @override
  Future<CacheStats> getStats() async {
    _ensureInitialized();
    var totalBytes = 0;
    var expiredCount = 0;
    var pinnedCount = 0;
    final bytesByTag = <String, int>{};

    for (final entry in _index.values) {
      totalBytes += entry.sizeBytes;
      if (entry.isExpired) expiredCount++;
      if (entry.pinned) pinnedCount++;
      final tagKey = (entry.tag == null || entry.tag!.isEmpty)
          ? 'untagged'
          : entry.tag!;
      bytesByTag[tagKey] = (bytesByTag[tagKey] ?? 0) + entry.sizeBytes;
    }

    return CacheStats(
      totalEntries: _index.length,
      totalBytes: totalBytes,
      expiredEntries: expiredCount,
      pinnedEntries: pinnedCount,
      maxDiskCacheBytes: _config.maxDiskCacheBytes,
      cacheDirectoryPath: 'CacheStorage://${_config.cacheSubdirectory}',
      hitCount: _hitCount,
      missCount: _missCount,
      evictionCount: _evictionCount,
      bytesByTag: bytesByTag,
    );
  }

  @override
  Future<CachePlatformCapabilities> getCapabilities() async {
    return CachePlatformCapabilities(
      platformName: 'web',
      supportsFileSystemPaths: false,
      supportsConditionalHttpRevalidation: true,
      supportsNativeCryptoHash: true,
      supportsLowDiskSpaceNotifications: false,
      storageMechanism: 'Browser CacheStorage API (window.caches) + Object URLs + localStorage Index',
      defaultCacheRootPath: 'CacheStorage://${_config.cacheSubdirectory}',
    );
  }
}
