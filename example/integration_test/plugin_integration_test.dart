import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('putBytes, getFileFromCache, and getCapabilities integration test', (
    WidgetTester tester,
  ) async {
    final cache = XueHuaNaviteCacheManager.instance;
    final caps = await cache.getCapabilities();
    expect(caps.platformName.isNotEmpty, isTrue);

    final entry = await cache.putBytes(
      key: 'integration_test_key',
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      fileExtension: 'bin',
      tag: 'test',
    );
    expect(entry.sizeBytes, 5);

    final cached = await cache.getFileFromCache('integration_test_key');
    expect(cached?.key, 'integration_test_key');

    final removed = await cache.removeFile('integration_test_key');
    expect(removed, isTrue);
  });
}
