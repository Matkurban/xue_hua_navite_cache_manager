#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _XueHuaNaviteCacheManagerPlugin XueHuaNaviteCacheManagerPlugin;
typedef struct {
  GObjectClass parent_class;
} XueHuaNaviteCacheManagerPluginClass;

FLUTTER_PLUGIN_EXPORT GType xue_hua_navite_cache_manager_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void xue_hua_navite_cache_manager_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_CACHE_MANAGER_PLUGIN_H_
