import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_navite_cache_manager/src/cache_hash_utils.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_method_channel.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_platform_interface.dart';

class FakeXueHuaNaviteCacheManagerPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteCacheManagerPlatform {
  CacheManagerConfig lastConfig = const CacheManagerConfig();
  final Map<String, CacheEntry> store = <String, CacheEntry>{};

  @override
  Stream<CacheProgressEvent> get progressStream =>
      Stream<CacheProgressEvent>.value(
        const CacheProgressEvent(
          key: 'k1',
          url: 'https://example.com/file.png',
          state: CacheTransferState.completed,
          bytesReceived: 128,
          totalBytes: 128,
          filePath: '/tmp/k1.png',
        ),
      );

  @override
  Future<void> configure(CacheManagerConfig config) async {
    lastConfig = config;
  }

  @override
  Future<CacheFetchResult> downloadFile(CacheRequest request) async {
    final key = request.customKey ?? 'key_${request.url.hashCode}';
    final entry = CacheEntry(
      key: key,
      url: request.url,
      filePath: '/tmp/$key.bin',
      sizeBytes: 1024,
      createdAtMs: 1700000000000,
      lastAccessedAtMs: 1700000000000,
      expiresAtMs: 1800000000000,
      hitCount: 1,
      tag: request.tag,
      mimeType: 'application/octet-stream',
      pinned: request.pinned,
    );
    store[key] = entry;
    return CacheFetchResult(
      entry: entry,
      source: CacheResultSource.networkDownload,
      httpStatusCode: 200,
      elapsedMs: 12,
    );
  }

  @override
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) async {
    final out = <CacheEntry>[];
    for (final r in requests) {
      final res = await downloadFile(r);
      out.add(res.entry);
    }
    return out;
  }

  @override
  Future<bool> cancelDownload(String keyOrUrl) async => true;

  @override
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async => store[keyOrUrl];

  @override
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async => Uint8List.fromList(<int>[1, 2, 3, 4]);

  @override
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) async =>
      store.containsKey(keyOrUrl);

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
    final entry = CacheEntry(
      key: key,
      url: url ?? 'local://$key',
      filePath: '/tmp/$key.${fileExtension ?? "bin"}',
      sizeBytes: bytes.length,
      createdAtMs: 1700000000000,
      lastAccessedAtMs: 1700000000000,
      expiresAtMs: 1800000000000,
      hitCount: 1,
      tag: tag,
      mimeType: mimeType,
      pinned: pinned,
    );
    store[key] = entry;
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
    final entry = CacheEntry(
      key: key,
      url: url ?? 'file://$sourceFilePath',
      filePath: '/tmp/$key.${fileExtension ?? "bin"}',
      sizeBytes: 512,
      createdAtMs: 1700000000000,
      lastAccessedAtMs: 1700000000000,
      expiresAtMs: 1800000000000,
      hitCount: 1,
      tag: tag,
      mimeType: mimeType,
      pinned: pinned,
    );
    store[key] = entry;
    return entry;
  }

  @override
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) async => true;

  @override
  Future<bool> removeFile(String keyOrUrl) async =>
      store.remove(keyOrUrl) != null;

  @override
  Future<int> removeByTag(String tag) async {
    final keys = store.values
        .where((e) => e.tag == tag)
        .map((e) => e.key)
        .toList();
    keys.forEach(store.remove);
    return keys.length;
  }

  @override
  Future<int> removeExpired() async => 0;

  @override
  Future<int> trimToSize(int maxBytes) async => 1;

  @override
  Future<int> clearAll({bool includePinned = true}) async {
    final count = store.length;
    store.clear();
    return count;
  }

  @override
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) async => store.values.toList();

  @override
  Future<CacheStats> getStats() async {
    return CacheStats(
      totalEntries: store.length,
      totalBytes: 1024,
      expiredEntries: 0,
      pinnedEntries: 1,
      maxDiskCacheBytes: lastConfig.maxDiskCacheBytes,
      cacheDirectoryPath: '/tmp/cache',
      hitCount: 5,
      missCount: 1,
      evictionCount: 0,
      bytesByTag: const <String, int>{'images': 1024},
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
      storageMechanism: 'NSCachesDirectory + URLSession',
      defaultCacheRootPath: '/tmp/cache',
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

  test('configure, downloadFile, putBytes, getStats, and capabilities work end-to-end', () async {
    final fakePlatform = FakeXueHuaNaviteCacheManagerPlatform();
    XueHuaNaviteCacheManagerPlatform.instance = fakePlatform;
    final manager = XueHuaNaviteCacheManager.instance;

    await manager.configure(
      const CacheManagerConfig(
        maxDiskCacheBytes: 100 * 1024 * 1024,
        evictionPolicy: CacheEvictionPolicy.lfu,
      ),
    );
    expect(fakePlatform.lastConfig.evictionPolicy, CacheEvictionPolicy.lfu);

    final entry = await manager.getSingleFile(
      'https://example.com/banner.png',
      customKey: 'banner_1',
      tag: 'banners',
      pinned: true,
    );
    expect(entry.key, 'banner_1');
    expect(entry.pinned, isTrue);
    expect(await manager.containsKey('banner_1'), isTrue);

    final manual = await manager.putBytes(
      key: 'manual_1',
      bytes: Uint8List.fromList(<int>[10, 20, 30]),
      tag: 'banners',
    );
    expect(manual.sizeBytes, 3);

    final stats = await manager.getStats();
    expect(stats.totalEntries, 2);
    expect(stats.hitRate, closeTo(5 / 6, 0.001));

    final caps = await manager.getCapabilities();
    expect(caps.platformName, 'macos');
    expect(caps.supportsFileSystemPaths, isTrue);

    final removedCount = await manager.removeByTag('banners');
    expect(removedCount, 2);
  });

  test('CacheHashUtils computes standard RFC MD5 and SHA-256 vectors', () {
    final abcBytes = Uint8List.fromList('abc'.codeUnits);
    expect(
      CacheHashUtils.md5Hex(abcBytes),
      '900150983cd24fb0d6963f7d28e17f72',
    );
    expect(
      CacheHashUtils.sha256Hex(abcBytes),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
