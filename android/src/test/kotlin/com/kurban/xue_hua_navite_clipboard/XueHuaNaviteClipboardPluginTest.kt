package com.kurban.xue_hua_navite_clipboard

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

internal class XueHuaNaviteClipboardPluginTest {
    @Test
    fun getChangeCount_returnsZeroWhenNotAttached() {
        val plugin = XueHuaNaviteClipboardPlugin()
        val target = WireClipboardBufferTarget(buffer = WireClipboardBuffer.GENERAL)

        assertEquals(0L, plugin.getChangeCount(target))
    }

    @Test
    fun clear_returnsFalseWhenNotAttached() {
        val plugin = XueHuaNaviteClipboardPlugin()
        val target = WireClipboardBufferTarget(buffer = WireClipboardBuffer.GENERAL)

        assertFalse(plugin.clear(target))
    }

    @Test
    fun setPollingInterval_acceptsCustomIntervalWithoutContext() {
        val plugin = XueHuaNaviteClipboardPlugin()
        plugin.setPollingInterval(250L)
    }
}
