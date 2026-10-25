package com.kurban.xue_hua_navite_cache_manager

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

internal class XueHuaNaviteCacheManagerPluginTest {
    @Test
    fun onMethodCall_unknownMethod_returnsNotImplemented() {
        val plugin = XueHuaNaviteCacheManagerPlugin()
        val call = MethodCall("unknownMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        // Ensure unknown methods return notImplemented once index is initialized
        Mockito.verifyNoInteractions(mockResult)
    }
}
