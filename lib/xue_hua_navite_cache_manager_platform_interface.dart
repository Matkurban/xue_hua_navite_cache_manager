import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'xue_hua_navite_cache_manager_method_channel.dart';

abstract class XueHuaNaviteCacheManagerPlatform extends PlatformInterface {
  /// Constructs a XueHuaNaviteCacheManagerPlatform.
  XueHuaNaviteCacheManagerPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteCacheManagerPlatform _instance = MethodChannelXueHuaNaviteCacheManager();

  /// The default instance of [XueHuaNaviteCacheManagerPlatform] to use.
  ///
  /// Defaults to [MethodChannelXueHuaNaviteCacheManager].
  static XueHuaNaviteCacheManagerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [XueHuaNaviteCacheManagerPlatform] when
  /// they register themselves.
  static set instance(XueHuaNaviteCacheManagerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
