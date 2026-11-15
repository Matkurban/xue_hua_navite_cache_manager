package com.kurban.xue_hua_navite_cache_manager

import kotlin.test.Test
import kotlin.test.assertFalse

internal class XueHuaNaviteCacheManagerPluginTest {
    @Test
    fun cancelDownload_unknownKey_returnsFalse() {
        val plugin = XueHuaNaviteCacheManagerPlugin()
        assertFalse(plugin.cancelDownload("https://example.com/missing.bin"))
    }
}
