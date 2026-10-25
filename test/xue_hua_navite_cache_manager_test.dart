import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_navite_cache_manager/src/cache_hash_utils.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_method_channel.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_platform_interface.dart';

class FullMockCachePlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteCacheManagerPlatform {
  CacheManagerConfig config = const CacheManagerConfig();
  final Map<String, CacheEntry> entries = <String, CacheEntry>{};
  final Map<String, Uint8List> bytesStore = <String, Uint8List>{};
  int hitCount = 0;
  int missCount = 0;
  int evictionCount = 0;

  @override
  Stream<CacheProgressEvent> get progressStream =>
      Stream<CacheProgressEvent>.fromIterable(<CacheProgressEvent>[
        const CacheProgressEvent(
          key: 'k1',
          url: 'https://example.com/a.png',
          state: CacheTransferState.started,
          bytesReceived: 0,
          totalBytes: 100,
        ),
        const CacheProgressEvent(
          key: 'k1',
          url: 'https://example.com/a.png',
          state: CacheTransferState.inProgress,
          bytesReceived: 50,
          totalBytes: 100,
        ),
        const CacheProgressEvent(
          key: 'k1',
          url: 'https://example.com/a.png',
          state: CacheTransferState.completed,
          bytesReceived: 100,
          totalBytes: 100,
          filePath: '/tmp/k1.png',
        ),
      ]);

  @override
  Future<void> configure(CacheManagerConfig newConfig) async {
    config = newConfig;
  }

  @override
  Future<CacheFetchResult> downloadFile(CacheRequest request) async {
    final key = request.customKey ?? CacheHashUtils.sha256String(request.url);
    final existing = entries[key];
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!request.forceRefresh && existing != null && !existing.isExpired) {
      hitCount++;
      final updated = CacheEntry(
        key: existing.key,
        url: existing.url,
        filePath: existing.filePath,
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
      entries[key] = updated;
      return CacheFetchResult(
        entry: updated,
        source: CacheResultSource.cacheHit,
        elapsedMs: 1,
      );
    }

    if (request.forceRefresh && existing != null && existing.eTag != null) {
      hitCount++;
      final revalidated = CacheEntry(
        key: existing.key,
        url: existing.url,
        filePath: existing.filePath,
        sizeBytes: existing.sizeBytes,
        createdAtMs: existing.createdAtMs,
        lastAccessedAtMs: now,
        expiresAtMs:
            now + (request.ttlSeconds ?? config.defaultTtlSeconds) * 1000,
        hitCount: existing.hitCount + 1,
        tag: request.tag ?? existing.tag,
        mimeType: existing.mimeType,
        eTag: existing.eTag,
        lastModified: existing.lastModified,
        checksum: existing.checksum,
        checksumAlgorithm: existing.checksumAlgorithm,
        pinned: request.pinned || existing.pinned,
      );
      entries[key] = revalidated;
      return CacheFetchResult(
        entry: revalidated,
        source: CacheResultSource.revalidated,
        httpStatusCode: 304,
        elapsedMs: 4,
      );
    }

    missCount++;
    final payload = Uint8List.fromList(request.url.codeUnits);
    String? checksum;
    if (request.checksumAlgorithm != CacheChecksumAlgorithm.none) {
      checksum = request.checksumAlgorithm == CacheChecksumAlgorithm.md5
          ? CacheHashUtils.md5Hex(payload)
          : CacheHashUtils.sha256Hex(payload);
      if (request.expectedChecksum != null &&
          request.expectedChecksum!.isNotEmpty &&
          checksum != request.expectedChecksum!.toLowerCase()) {
        throw PlatformException(
          code: 'CHECKSUM_MISMATCH',
          message: 'Checksum mismatch',
        );
      }
    }

    bytesStore[key] = payload;
    final entry = CacheEntry(
      key: key,
      url: request.url,
      filePath: '/tmp/$key.${request.fileExtension ?? "bin"}',
      sizeBytes: payload.length,
      createdAtMs: now,
      lastAccessedAtMs: now,
      expiresAtMs:
          now + (request.ttlSeconds ?? config.defaultTtlSeconds) * 1000,
      hitCount: 1,
      tag: request.tag,
      mimeType: 'application/octet-stream',
      eTag: '"etag-$key"',
      checksum: checksum,
      checksumAlgorithm: request.checksumAlgorithm,
      pinned: request.pinned,
    );
    entries[key] = entry;
    return CacheFetchResult(
      entry: entry,
      source: CacheResultSource.networkDownload,
      httpStatusCode: 200,
      elapsedMs: 10,
    );
  }

  @override
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) async {
    final list = <CacheEntry>[];
    for (final req in requests) {
      final res = await downloadFile(req);
      list.add(res.entry);
    }
    return list;
  }

  @override
  Future<bool> cancelDownload(String keyOrUrl) async => true;

  @override
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final e =
        entries[keyOrUrl] ?? entries[CacheHashUtils.sha256String(keyOrUrl)];
    if (e == null) return null;
    if (ignoreExpired && e.isExpired) return null;
    return e;
  }

  @override
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final e = await getFileFromCache(keyOrUrl, ignoreExpired: ignoreExpired);
    if (e == null) return null;
    return bytesStore[e.key];
  }

  @override
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) async {
    return (await getFileFromCache(keyOrUrl, ignoreExpired: ignoreExpired)) !=
        null;
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
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = ttlSeconds ?? config.defaultTtlSeconds;
    bytesStore[key] = bytes;
    final entry = CacheEntry(
      key: key,
      url: url ?? 'local://$key',
      filePath: '/tmp/$key.${fileExtension ?? "bin"}',
      sizeBytes: bytes.length,
      createdAtMs: now,
      lastAccessedAtMs: now,
      expiresAtMs: now + ttl * 1000,
      hitCount: 1,
      tag: tag,
      mimeType: mimeType ?? 'application/octet-stream',
      checksum: CacheHashUtils.sha256Hex(bytes),
      checksumAlgorithm: CacheChecksumAlgorithm.sha256,
      pinned: pinned,
    );
    entries[key] = entry;
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
    final payload = Uint8List.fromList(sourceFilePath.codeUnits);
    return putBytes(
      key: key,
      bytes: payload,
      url: url ?? 'file://$sourceFilePath',
      fileExtension: fileExtension,
      mimeType: mimeType,
      tag: tag,
      ttlSeconds: ttlSeconds,
      pinned: pinned,
    );
  }

  @override
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) async {
    final e = entries[keyOrUrl];
    if (e == null) return false;
    entries[keyOrUrl] = CacheEntry(
      key: e.key,
      url: e.url,
      filePath: e.filePath,
      sizeBytes: e.sizeBytes,
      createdAtMs: e.createdAtMs,
      lastAccessedAtMs: e.lastAccessedAtMs,
      expiresAtMs: e.expiresAtMs,
      hitCount: e.hitCount,
      tag: e.tag,
      mimeType: e.mimeType,
      eTag: e.eTag,
      lastModified: e.lastModified,
      checksum: e.checksum,
      checksumAlgorithm: e.checksumAlgorithm,
      pinned: pinned,
    );
    return true;
  }

  @override
  Future<bool> removeFile(String keyOrUrl) async {
    bytesStore.remove(keyOrUrl);
    return entries.remove(keyOrUrl) != null;
  }

  @override
  Future<int> removeByTag(String tag) async {
    final keys = entries.values
        .where((e) => e.tag == tag)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      entries.remove(k);
      bytesStore.remove(k);
    }
    return keys.length;
  }

  @override
  Future<int> removeExpired() async {
    final keys = entries.values
        .where((e) => !e.pinned && e.isExpired)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      entries.remove(k);
      bytesStore.remove(k);
      evictionCount++;
    }
    return keys.length;
  }

  @override
  Future<int> trimToSize(int maxBytes) async {
    var total = entries.values.fold<int>(0, (s, e) => s + e.sizeBytes);
    var evicted = 0;
    final unpinned = entries.values.where((e) => !e.pinned).toList();
    for (final e in unpinned) {
      if (total <= maxBytes) break;
      entries.remove(e.key);
      bytesStore.remove(e.key);
      total -= e.sizeBytes;
      evicted++;
      evictionCount++;
    }
    return evicted;
  }

  @override
  Future<int> clearAll({bool includePinned = true}) async {
    final keys = entries.values
        .where((e) => includePinned || !e.pinned)
        .map((e) => e.key)
        .toList();
    for (final k in keys) {
      entries.remove(k);
      bytesStore.remove(k);
    }
    return keys.length;
  }

  @override
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) async {
    return entries.values.where((e) {
      if (tag != null && e.tag != tag) return false;
      if (!includeExpired && e.isExpired) return false;
      return true;
    }).toList();
  }

  @override
  Future<CacheStats> getStats() async {
    final totalBytes = entries.values.fold<int>(0, (s, e) => s + e.sizeBytes);
    final byTag = <String, int>{};
    for (final e in entries.values) {
      final t = e.tag ?? 'untagged';
      byTag[t] = (byTag[t] ?? 0) + e.sizeBytes;
    }
    return CacheStats(
      totalEntries: entries.length,
      totalBytes: totalBytes,
      expiredEntries: entries.values.where((e) => e.isExpired).length,
      pinnedEntries: entries.values.where((e) => e.pinned).length,
      maxDiskCacheBytes: config.maxDiskCacheBytes,
      cacheDirectoryPath: '/tmp/xue_hua_cache',
      hitCount: hitCount,
      missCount: missCount,
      evictionCount: evictionCount,
      bytesByTag: byTag,
    );
  }

  @override
  Future<CachePlatformCapabilities> getCapabilities() async {
    return const CachePlatformCapabilities(
      platformName: 'macos',
      supportsFileSystemPaths: true,
      supportsConditionalHttpRevalidation: true,
      supportsNativeCryptoHash: true,
      supportsLowDiskSpaceNotifications: false,
      storageMechanism: '~/Library/Caches + URLSession + CryptoKit',
      defaultCacheRootPath: '/tmp/xue_hua_cache',
    );
  }
}

void main() {
  final XueHuaNaviteCacheManagerPlatform initialPlatform =
      XueHuaNaviteCacheManagerPlatform.instance;

  test('$MethodChannelXueHuaNaviteCacheManager is the default instance', () {
    expect(
      initialPlatform,
      isInstanceOf<MethodChannelXueHuaNaviteCacheManager>(),
    );
  });

  test(
    'All XueHuaNaviteCacheManager APIs and models work end-to-end',
    () async {
      final mock = FullMockCachePlatform();
      XueHuaNaviteCacheManagerPlatform.instance = mock;
      final manager = XueHuaNaviteCacheManager.instance;

      // 1. Configure & copyWith
      const baseConfig = CacheManagerConfig();
      final customConfig = baseConfig.copyWith(
        maxDiskCacheBytes: 64 * 1024 * 1024,
        evictionPolicy: CacheEvictionPolicy.lfu,
        cacheSubdirectory: 'test_subdir',
      );
      await manager.configure(customConfig);
      expect(mock.config.evictionPolicy, CacheEvictionPolicy.lfu);
      expect(mock.config.cacheSubdirectory, 'test_subdir');

      // 2. Download, Cache Hit, and HTTP 304 Revalidation
      const url = 'https://example.com/resource.dat';
      final expectedSha256 = CacheHashUtils.sha256String(url);

      final first = await manager.downloadFile(
        CacheRequest(
          url: url,
          customKey: 'res_1',
          tag: 'media',
          checksumAlgorithm: CacheChecksumAlgorithm.sha256,
          expectedChecksum: expectedSha256,
        ),
      );
      expect(first.source, CacheResultSource.networkDownload);
      expect(first.httpStatusCode, 200);
      expect(first.entry.checksum, expectedSha256);

      final second = await manager.downloadFile(
        const CacheRequest(url: url, customKey: 'res_1'),
      );
      expect(second.source, CacheResultSource.cacheHit);
      expect(second.entry.hitCount, 2);

      final third = await manager.downloadFile(
        const CacheRequest(url: url, customKey: 'res_1', forceRefresh: true),
      );
      expect(third.source, CacheResultSource.revalidated);
      expect(third.httpStatusCode, 304);

      // 3. Checksum mismatch throws PlatformException
      expect(
        () => manager.downloadFile(
          const CacheRequest(
            url: 'https://example.com/corrupt.dat',
            checksumAlgorithm: CacheChecksumAlgorithm.md5,
            expectedChecksum: '00000000000000000000000000000000',
          ),
        ),
        throwsA(isA<PlatformException>()),
      );

      // 4. Prefetch & PrefetchAll
      final singlePrefetch = await manager.prefetch(
        const CacheRequest(
          url: 'https://example.com/p1.png',
          customKey: 'p1',
          tag: 'prefetch_group',
        ),
      );
      expect(singlePrefetch.key, 'p1');

      final batchPrefetch = await manager.prefetchAll(const <CacheRequest>[
        CacheRequest(
          url: 'https://example.com/p2.png',
          customKey: 'p2',
          tag: 'prefetch_group',
        ),
        CacheRequest(
          url: 'https://example.com/p3.png',
          customKey: 'p3',
          tag: 'prefetch_group',
        ),
      ]);
      expect(batchPrefetch.length, 2);

      // 5. putBytes, putFile, readCacheBytes, containsKey
      final raw = Uint8List.fromList(<int>[10, 20, 30, 40, 50]);
      final manualBytesEntry = await manager.putBytes(
        key: 'manual_bytes',
        bytes: raw,
        tag: 'manual',
        pinned: true,
      );
      expect(manualBytesEntry.pinned, isTrue);
      expect(await manager.readCacheBytes('manual_bytes'), equals(raw));

      final manualFileEntry = await manager.putFile(
        key: 'manual_file',
        sourceFilePath: '/var/tmp/input.txt',
        tag: 'manual',
      );
      expect(manualFileEntry.key, 'manual_file');
      expect(await manager.containsKey('manual_file'), isTrue);

      // 6. Progress stream & watchProgress
      final watchedEvents = await manager.watchProgress('k1').toList();
      expect(watchedEvents.length, 3);
      expect(watchedEvents[1].progress, closeTo(0.5, 0.001));
      expect(watchedEvents.last.progress, 1.0);

      // 7. Stats, Pinning, Eviction, and ClearAll
      final stats = await manager.getStats();
      expect(stats.totalEntries, 6);
      expect(stats.pinnedEntries, 1);
      expect(stats.hitRate, greaterThan(0.0));

      expect(await manager.removeByTag('prefetch_group'), 3);
      expect(await manager.trimToSize(10), greaterThanOrEqualTo(1));

      // Clear unpinned preserves 'manual_bytes'
      await manager.clearAll(includePinned: false);
      expect(await manager.containsKey('manual_bytes'), isTrue);

      await manager.setPinned('manual_bytes', pinned: false);
      expect(await manager.removeFile('manual_bytes'), isTrue);
      expect((await manager.listEntries()).isEmpty, isTrue);
    },
  );

  test('CacheHashUtils computes standard RFC 1321 MD5 and FIPS 180-4 SHA-256 vectors', () {
    final emptyBytes = Uint8List(0);
    expect(
      CacheHashUtils.md5Hex(emptyBytes),
      'd41d8cd98f00b204e9800998ecf8427e',
    );
    expect(
      CacheHashUtils.sha256Hex(emptyBytes),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

    final abcBytes = Uint8List.fromList('abc'.codeUnits);
    expect(CacheHashUtils.md5Hex(abcBytes), '900150983cd24fb0d6963f7d28e17f72');
    expect(
      CacheHashUtils.sha256Hex(abcBytes),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
