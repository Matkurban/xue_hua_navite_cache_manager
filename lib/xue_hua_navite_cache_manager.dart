
import 'xue_hua_navite_cache_manager_platform_interface.dart';

class XueHuaNaviteCacheManager {
  Future<String?> getPlatformVersion() {
    return XueHuaNaviteCacheManagerPlatform.instance.getPlatformVersion();
  }
}
