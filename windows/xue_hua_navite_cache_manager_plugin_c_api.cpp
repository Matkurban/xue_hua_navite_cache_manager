#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "xue_hua_navite_cache_manager_plugin.h"

void XueHuaNaviteCacheManagerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  xue_hua_navite_cache_manager::XueHuaNaviteCacheManagerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
