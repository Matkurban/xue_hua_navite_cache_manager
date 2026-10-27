import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// Hash helper is not on the public barrel. The digest is derived from the
// payload bytes, then checked against the known SHA-256 so it cannot drift.
// ignore: implementation_imports
import 'package:xue_hua_navite_cache_manager/src/cache_hash_utils.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Full end-to-end functional & 10,000+ entries performance test of XueHuaNaviteCacheManager',
    (WidgetTester tester) async {
      final cache = XueHuaNaviteCacheManager.instance;
      final events = <CacheProgressEvent>[];
      final sub = cache.progressStream.listen(events.add);

      // 1. Verify platform capabilities
      final caps = await cache.getCapabilities();
      expect(caps.platformName.isNotEmpty, isTrue);
      expect(caps.supportsConditionalHttpRevalidation, isTrue);
      expect(caps.supportsNativeCryptoHash, isTrue);

      // 2. Configure global cache manager for 20,000 maxEntries
      await cache.configure(
        const CacheManagerConfig(
          maxDiskCacheBytes: 200 * 1024 * 1024,
          maxEntries: 20000,
          defaultTtlSeconds: 3600,
          evictionPolicy: CacheEvictionPolicy.lru,
          cacheSubdirectory: 'xue_hua_e2e_test_cache',
          respectHttpCacheHeaders: true,
          autoTrimOnWrite: true,
        ),
      );

      // Clear any previous state
      await cache.clearAll(includePinned: true);

      // 3. Test putBytes & offline cache queries (containsKey, getFileFromCache, readCacheBytes)
      final rawPayload = Uint8List.fromList(
        '{"status":"ok","items":[1,2,3]}'.codeUnits,
      );
      final putEntry = await cache.putBytes(
        key: 'e2e_json_config',
        bytes: rawPayload,
        fileExtension: 'json',
        mimeType: 'application/json',
        tag: 'config',
        pinned: true,
      );
      expect(putEntry.key, 'e2e_json_config');
      expect(putEntry.sizeBytes, rawPayload.length);
      expect(putEntry.pinned, isTrue);
      expect(putEntry.checksum?.isNotEmpty, isTrue);

      expect(await cache.containsKey('e2e_json_config'), isTrue);
      final cachedConfig = await cache.getFileFromCache('e2e_json_config');
      expect(cachedConfig, isNotNull);
      expect(cachedConfig!.hitCount, greaterThanOrEqualTo(2));

      final readBytes = await cache.readCacheBytes('e2e_json_config');
      expect(readBytes, equals(rawPayload));

      // 4. Test putFile on native platforms supporting file system paths
      if (caps.supportsFileSystemPaths) {
        final tempSource = File(
          '${Directory.systemTemp.path}/xue_hua_source_test.txt',
        );
        await tempSource.writeAsString('Hello from local file test');
        final fileEntry = await cache.putFile(
          key: 'e2e_local_file',
          sourceFilePath: tempSource.path,
          fileExtension: 'txt',
          mimeType: 'text/plain',
          tag: 'files',
        );
        expect(fileEntry.sizeBytes, 26);
        expect(await cache.containsKey('e2e_local_file'), isTrue);
        if (await tempSource.exists()) {
          await tempSource.delete();
        }
      }

      // 5. Test local loopback HTTP server download, cacheHit, HTTP 304 revalidation, and SHA-256 verification
      if (caps.supportsFileSystemPaths) {
        int requestCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serverBody = Uint8List.fromList(
          'Native Cache Manager Loopback Payload'.codeUnits,
        );
        // SHA-256 of the ASCII payload above (OpenSSL / hashlib).
        // The previous constant did not hash this string.
        final expectedSha256 = CacheHashUtils.sha256Hex(serverBody);
        expect(
          expectedSha256,
          'bd2708ce19a7937efd2adf4b93e336d9303166a4d3f1610705dcccfce7916bc4',
        );

        server.listen((HttpRequest req) async {
          requestCount++;
          final ifNoneMatch = req.headers.value(HttpHeaders.ifNoneMatchHeader);
          if (ifNoneMatch == '"v1-etag"') {
            req.response.statusCode = HttpStatus.notModified;
            req.response.headers.set(HttpHeaders.etagHeader, '"v1-etag"');
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.text;
          req.response.headers.set(HttpHeaders.etagHeader, '"v1-etag"');
          req.response.add(serverBody);
          await req.response.close();
        });

        final testUrl = 'http://127.0.0.1:${server.port}/payload.txt';

        // 5a. First download -> networkDownload
        final firstFetch = await cache.downloadFile(
          CacheRequest(
            url: testUrl,
            tag: 'network',
            checksumAlgorithm: CacheChecksumAlgorithm.sha256,
            expectedChecksum: expectedSha256,
          ),
        );
        expect(firstFetch.source, CacheResultSource.networkDownload);
        expect(firstFetch.httpStatusCode, 200);
        expect(firstFetch.entry.sizeBytes, serverBody.length);
        expect(firstFetch.entry.checksum, expectedSha256);

        // 5b. Second download without forceRefresh -> cacheHit (no HTTP call)
        final secondFetch = await cache.downloadFile(
          CacheRequest(url: testUrl, tag: 'network'),
        );
        expect(secondFetch.source, CacheResultSource.cacheHit);
        expect(requestCount, 1);

        // 5c. Third download with forceRefresh: true -> HTTP 304 revalidated
        final thirdFetch = await cache.downloadFile(
          CacheRequest(url: testUrl, tag: 'network', forceRefresh: true),
        );
        expect(thirdFetch.source, CacheResultSource.revalidated);
        expect(thirdFetch.httpStatusCode, 304);
        expect(requestCount, 2);

        await server.close(force: true);
      }

      // 6. High-volume 10,000 entries stress test with debounced index flushing
      const bulkCount = 10000;
      final tinyBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      for (int i = 0; i < bulkCount; i++) {
        await cache.putBytes(
          key: 'e2e_bulk_$i',
          bytes: tinyBytes,
          tag: 'bulk_10k',
        );
      }
      final stats10k = await cache.getStats();
      expect(stats10k.totalEntries, greaterThanOrEqualTo(bulkCount));
      final purged10k = await cache.removeByTag('bulk_10k');
      expect(purged10k, bulkCount);

      // 7. Test setPinned, removeByTag, and clearAll
      final removedByTag = await cache.removeByTag('files');
      expect(removedByTag, caps.supportsFileSystemPaths ? 1 : 0);

      // Clear unpinned only -> pinned 'e2e_json_config' must survive
      await cache.clearAll(includePinned: false);
      expect(await cache.containsKey('e2e_json_config'), isTrue);

      // Unpin and remove
      expect(await cache.setPinned('e2e_json_config', pinned: false), isTrue);
      expect(await cache.removeFile('e2e_json_config'), isTrue);
      expect(await cache.containsKey('e2e_json_config'), isFalse);

      await sub.cancel();
    },
  );

  testWidgets(
    'Uncovered API surface: getSingleFile, prefetch*, cancel, TTL, trim, list, progress',
    (WidgetTester tester) async {
      final cache = XueHuaNaviteCacheManager.instance;
      final caps = await cache.getCapabilities();

      await cache.configure(
        const CacheManagerConfig(
          maxDiskCacheBytes: 50 * 1024 * 1024,
          maxEntries: 5000,
          defaultTtlSeconds: 3600,
          evictionPolicy: CacheEvictionPolicy.lru,
          cacheSubdirectory: 'xue_hua_e2e_api_gaps',
          respectHttpCacheHeaders: true,
          autoTrimOnWrite: true,
        ),
      );
      await cache.clearAll(includePinned: true);

      // putBytes + listEntries + getSingleFile path via download after local HTTP
      final seed = Uint8List.fromList('gap-seed'.codeUnits);
      await cache.putBytes(
        key: 'gap_seed',
        bytes: seed,
        tag: 'gap',
        ttlSeconds: 3600,
      );
      final listed = await cache.listEntries(tag: 'gap');
      expect(listed.any((e) => e.key == 'gap_seed'), isTrue);

      // removeExpired: short TTL entry should be purged after expiry
      await cache.putBytes(
        key: 'gap_ttl',
        bytes: Uint8List.fromList(<int>[9]),
        tag: 'gap_ttl',
        ttlSeconds: 1,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      final expiredRemoved = await cache.removeExpired();
      expect(expiredRemoved, greaterThanOrEqualTo(1));
      expect(await cache.containsKey('gap_ttl'), isFalse);

      // trimToSize: fill then trim hard
      for (int i = 0; i < 20; i++) {
        await cache.putBytes(
          key: 'gap_trim_$i',
          bytes: Uint8List(2048),
          tag: 'gap_trim',
        );
      }
      final trimmed = await cache.trimToSize(8 * 1024);
      expect(trimmed, greaterThanOrEqualTo(1));
      await cache.removeByTag('gap_trim');

      if (caps.supportsFileSystemPaths) {
        int hits = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final body = Uint8List.fromList('gap-http-body'.codeUnits);
        server.listen((HttpRequest req) async {
          hits++;
          // Slow path for cancel coverage
          if (req.uri.path.contains('slow')) {
            await Future<void>.delayed(const Duration(seconds: 8));
          }
          req.response.statusCode = HttpStatus.ok;
          req.response.add(body);
          await req.response.close();
        });

        final base = 'http://127.0.0.1:${server.port}';

        // getSingleFile + prefetch
        final single = await cache.getSingleFile(
          '$base/one.txt',
          tag: 'gap_net',
          checksumAlgorithm: CacheChecksumAlgorithm.md5,
        );
        expect(single.sizeBytes, body.length);

        final prefetched = await cache.prefetch(
          CacheRequest(url: '$base/two.txt', tag: 'gap_net'),
        );
        expect(prefetched.sizeBytes, body.length);

        final many = await cache.prefetchAll(<CacheRequest>[
          CacheRequest(url: '$base/a.txt', tag: 'gap_net'),
          CacheRequest(url: '$base/b.txt', tag: 'gap_net'),
        ]);
        expect(many.length, 2);

        // watchProgress should see at least one event during a fresh download
        final progressEvents = <CacheProgressEvent>[];
        final watchSub = cache.watchProgress('$base/prog.txt').listen(
          progressEvents.add,
        );
        await cache.downloadFile(
          CacheRequest(url: '$base/prog.txt', tag: 'gap_net', forceRefresh: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await watchSub.cancel();
        expect(progressEvents, isNotEmpty);

        // cancelDownload: start slow download then cancel
        final slowUrl = '$base/slow.bin';
        final slowFuture = cache.downloadFile(
          CacheRequest(url: slowUrl, tag: 'gap_cancel', forceRefresh: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final canceled = await cache.cancelDownload(slowUrl);
        expect(canceled, isTrue);
        try {
          await slowFuture;
        } catch (_) {
          // Cancellation may surface as an error; that is acceptable.
        }

        await server.close(force: true);
        expect(hits, greaterThanOrEqualTo(1));
        await cache.removeByTag('gap_net');
        await cache.removeByTag('gap_cancel');
      }

      await cache.clearAll(includePinned: true);
    },
  );
}
