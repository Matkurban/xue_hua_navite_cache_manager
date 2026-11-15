#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_PRIVATE_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_PRIVATE_H_

#include <flutter_linux/flutter_linux.h>

#include "include/xue_hua_navite_cache_manager/xue_hua_navite_cache_manager_plugin.h"
#include "messages.g.h"

// Exposes synchronous Pigeon handlers for unit testing.
XueHuaCacheCacheHostApiGetCapabilitiesResponse* get_capabilities_response();
XueHuaCacheCacheHostApiCancelDownloadResponse* cancel_download_response(
    const gchar* key_or_url);

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_PRIVATE_H_
