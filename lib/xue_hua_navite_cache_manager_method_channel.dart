import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'xue_hua_navite_cache_manager_platform_interface.dart';

/// An implementation of [XueHuaNaviteCacheManagerPlatform] that uses method channels.
class MethodChannelXueHuaNaviteCacheManager extends XueHuaNaviteCacheManagerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('xue_hua_navite_cache_manager');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
