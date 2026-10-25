import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_platform_interface.dart';
import 'package:xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockXueHuaNaviteCacheManagerPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteCacheManagerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final XueHuaNaviteCacheManagerPlatform initialPlatform = XueHuaNaviteCacheManagerPlatform.instance;

  test('$MethodChannelXueHuaNaviteCacheManager is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelXueHuaNaviteCacheManager>());
  });

  test('getPlatformVersion', () async {
    XueHuaNaviteCacheManager xueHuaNaviteCacheManagerPlugin = XueHuaNaviteCacheManager();
    MockXueHuaNaviteCacheManagerPlatform fakePlatform = MockXueHuaNaviteCacheManagerPlatform();
    XueHuaNaviteCacheManagerPlatform.instance = fakePlatform;

    expect(await xueHuaNaviteCacheManagerPlugin.getPlatformVersion(), '42');
  });
}
