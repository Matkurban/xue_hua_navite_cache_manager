import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelXueHuaNaviteCacheManager platform =
      MethodChannelXueHuaNaviteCacheManager();
  const MethodChannel channel = MethodChannel('xue_hua_navite_cache_manager');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          log.add(methodCall);
          switch (methodCall.method) {
            case 'configure':
              return null;
            case 'downloadFile':
              return <String, Object?>{
                'entry': <String, Object?>{
                  'key': 'k_owl',
                  'url': 'https://example.com/owl.jpg',
                  'filePath': '/tmp/k_owl.jpg',
                  'sizeBytes': 4096,
                  'createdAtMs': 1700000000000,
                  'lastAccessedAtMs': 1700000000000,
                  'expiresAtMs': 1800000000000,
                  'hitCount': 2,
                  'tag': 'birds',
                  'mimeType': 'image/jpeg',
                  'eTag': '"owl-v1"',
                  'lastModified': 'Wed, 21 Oct 2026 07:28:00 GMT',
                  'checksum': 'abcd1234',
                  'checksumAlgorithm': 'sha256',
                  'pinned': false,
                },
                'source': 'cacheHit',
                'httpStatusCode': null,
                'elapsedMs': 3,
              };
            case 'prefetchAll':
              return <Object?>[
                <String, Object?>{
                  'key': 'k_1',
                  'url': 'https://example.com/1.png',
                  'filePath': '/tmp/k_1.png',
                  'sizeBytes': 512,
                  'createdAtMs': 1700000000000,
                  'lastAccessedAtMs': 1700000000000,
                  'expiresAtMs': 1800000000000,
                  'hitCount': 1,
                  'pinned': false,
                },
              ];
            case 'cancelDownload':
              return true;
            case 'getFileFromCache':
              return <String, Object?>{
                'key': 'k_owl',
                'url': 'https://example.com/owl.jpg',
                'filePath': '/tmp/k_owl.jpg',
                'sizeBytes': 4096,
                'createdAtMs': 1700000000000,
                'lastAccessedAtMs': 1700000000000,
                'expiresAtMs': 1800000000000,
                'hitCount': 3,
                'pinned': true,
              };
            case 'readCacheBytes':
              return Uint8List.fromList(<int>[1, 2, 3, 4]);
            case 'containsKey':
              return true;
            case 'putBytes':
            case 'putFile':
              return <String, Object?>{
                'key': 'k_put',
                'url': 'local://k_put',
                'filePath': '/tmp/k_put.bin',
                'sizeBytes': 4,
                'createdAtMs': 1700000000000,
                'lastAccessedAtMs': 1700000000000,
                'expiresAtMs': 1800000000000,
                'hitCount': 1,
                'pinned': true,
              };
            case 'setPinned':
            case 'removeFile':
              return true;
            case 'removeByTag':
            case 'removeExpired':
            case 'trimToSize':
            case 'clearAll':
              return 2;
            case 'listEntries':
              return <Object?>[
                <String, Object?>{
                  'key': 'k_owl',
                  'url': 'https://example.com/owl.jpg',
                  'filePath': '/tmp/k_owl.jpg',
                  'sizeBytes': 4096,
                  'createdAtMs': 1700000000000,
                  'lastAccessedAtMs': 1700000000000,
                  'expiresAtMs': 1800000000000,
                  'hitCount': 3,
                  'pinned': true,
                },
              ];
            case 'getStats':
              return <String, Object?>{
                'totalEntries': 1,
                'totalBytes': 4096,
                'expiredEntries': 0,
                'pinnedEntries': 1,
                'maxDiskCacheBytes': 10485760,
                'cacheDirectoryPath': '/tmp',
                'hitCount': 2,
                'missCount': 1,
                'evictionCount': 0,
                'bytesByTag': <String, int>{'birds': 4096},
              };
            case 'getCapabilities':
              return <String, Object?>{
                'platformName': 'macos',
                'supportsFileSystemPaths': true,
                'supportsConditionalHttpRevalidation': true,
                'supportsNativeCryptoHash': true,
                'supportsLowDiskSpaceNotifications': false,
                'storageMechanism': '~/Library/Caches',
                'defaultCacheRootPath': '/tmp',
              };
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('All 16 MethodChannel operations serialize arguments and responses accurately', () async {
    await platform.configure(const CacheManagerConfig());
    final dl = await platform.downloadFile(
      const CacheRequest(url: 'https://example.com/owl.jpg', tag: 'birds'),
    );
    expect(dl.source, CacheResultSource.cacheHit);
    expect(dl.entry.eTag, '"owl-v1"');

    final prefetched = await platform.prefetchAll(const <CacheRequest>[
      CacheRequest(url: 'https://example.com/1.png'),
    ]);
    expect(prefetched.length, 1);

    expect(await platform.cancelDownload('k_owl'), isTrue);
    expect((await platform.getFileFromCache('k_owl'))?.pinned, isTrue);
    expect(await platform.readCacheBytes('k_owl'), equals(<int>[1, 2, 3, 4]));
    expect(await platform.containsKey('k_owl'), isTrue);

    final putB = await platform.putBytes(
      key: 'k_put',
      bytes: Uint8List.fromList(<int>[9, 8, 7, 6]),
    );
    expect(putB.key, 'k_put');

    final putF = await platform.putFile(
      key: 'k_put',
      sourceFilePath: '/tmp/src.bin',
    );
    expect(putF.key, 'k_put');

    expect(await platform.setPinned('k_owl', pinned: true), isTrue);
    expect(await platform.removeFile('k_owl'), isTrue);
    expect(await platform.removeByTag('birds'), 2);
    expect(await platform.removeExpired(), 2);
    expect(await platform.trimToSize(1024), 2);
    expect(await platform.clearAll(includePinned: false), 2);
    expect((await platform.listEntries(tag: 'birds')).length, 1);

    final stats = await platform.getStats();
    expect(stats.totalBytes, 4096);

    final caps = await platform.getCapabilities();
    expect(caps.platformName, 'macos');
    expect(log.length, 18);
  });
}
