package com.kurban.xue_hua_navite_clipboard

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

internal class XueHuaNaviteClipboardPluginTest {
    @Test
    fun onMethodCall_getChangeCount_returnsZeroInitially() {
        val plugin = XueHuaNaviteClipboardPlugin()

        val call = MethodCall("getChangeCount", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(0)
    }
}
