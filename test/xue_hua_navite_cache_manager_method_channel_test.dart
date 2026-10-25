import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelXueHuaNaviteCacheManager platform =
      MethodChannelXueHuaNaviteCacheManager();
  const MethodChannel channel = MethodChannel('xue_hua_navite_cache_manager');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
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
              'checksum': 'abcd1234',
              'checksumAlgorithm': 'sha256',
              'pinned': false,
            },
            'source': 'cacheHit',
            'httpStatusCode': null,
            'elapsedMs': 3,
          };
        case 'getStats':
          return <String, Object?>{
            'totalEntries': 1,
            'totalBytes': 4096,
            'expiredEntries': 0,
            'pinnedEntries': 0,
            'maxDiskCacheBytes': 10485760,
            'cacheDirectoryPath': '/tmp',
            'hitCount': 2,
            'missCount': 1,
            'evictionCount': 0,
            'bytesByTag': <String, int>{'birds': 4096},
          };
        case 'getCapabilities':
          return <String, Object?>{
            'platformName': 'android',
            'supportsFileSystemPaths': true,
            'supportsConditionalHttpRevalidation': true,
            'supportsNativeCryptoHash': true,
            'supportsLowDiskSpaceNotifications': true,
            'storageMechanism': 'Context.getCacheDir()',
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

  test('methodChannel downloadFile and getStats serialize properly', () async {
    final result = await platform.downloadFile(
      const CacheRequest(url: 'https://example.com/owl.jpg', tag: 'birds'),
    );
    expect(result.source, CacheResultSource.cacheHit);
    expect(result.entry.key, 'k_owl');
    expect(result.entry.sizeBytes, 4096);

    final stats = await platform.getStats();
    expect(stats.totalEntries, 1);
    expect(stats.bytesByTag['birds'], 4096);

    final caps = await platform.getCapabilities();
    expect(caps.platformName, 'android');
    expect(caps.supportsLowDiskSpaceNotifications, isTrue);
  });
}
