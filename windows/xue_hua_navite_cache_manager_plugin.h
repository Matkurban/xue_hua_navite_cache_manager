#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace xue_hua_navite_cache_manager {

class XueHuaNaviteCacheManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  XueHuaNaviteCacheManagerPlugin();

  virtual ~XueHuaNaviteCacheManagerPlugin();

  // Disallow copy and assign.
  XueHuaNaviteCacheManagerPlugin(const XueHuaNaviteCacheManagerPlugin&) = delete;
  XueHuaNaviteCacheManagerPlugin& operator=(const XueHuaNaviteCacheManagerPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace xue_hua_navite_cache_manager

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
