package io.github.dwicao.antigravity_go.phone

import io.github.dwicao.antigravity_go.runtime.SessionVariableStore
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneMcpServerTest {
    @Test
    fun initializeAndToolsListFollowMcpJsonRpc() {
        val initReq = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 1)
            .put("method", "initialize")
            .put("params", JSONObject().put("protocolVersion", "2024-11-05"))

        val initResp = PhoneMcpServer.dispatchJsonRpc(initReq) { _, _ -> JSONObject() }
        assertNotNull(initResp)
        assertEquals(1, initResp!!.getInt("id"))
        assertEquals("phone-control", initResp.getJSONObject("result").getJSONObject("serverInfo").getString("name"))

        val listReq = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 2)
            .put("method", "tools/list")
        val listResp = PhoneMcpServer.dispatchJsonRpc(listReq) { _, _ -> JSONObject() }
        val tools = listResp!!.getJSONObject("result").getJSONArray("tools")
        assertEquals(17, tools.length())
        assertEquals("phone_screen_tree", tools.getJSONObject(0).getString("name"))
        assertEquals("phone_tap", tools.getJSONObject(1).getString("name"))
        assertEquals("phone_type", tools.getJSONObject(2).getString("name"))
        assertEquals("phone_device_info", tools.getJSONObject(3).getString("name"))
        assertEquals("phone_torch", tools.getJSONObject(6).getString("name"))
        assertEquals("phone_shizuku_exec", tools.getJSONObject(10).getString("name"))
        assertEquals("phone_shizuku_logcat", tools.getJSONObject(11).getString("name"))
        assertEquals("phone_shizuku_install", tools.getJSONObject(12).getString("name"))
        assertEquals("phone_shizuku_ui_dump", tools.getJSONObject(13).getString("name"))
        assertEquals("phone_subagent_notify", tools.getJSONObject(14).getString("name"))
        assertEquals("phone_browser", tools.getJSONObject(15).getString("name"))
        assertEquals("var_inspect", tools.getJSONObject(16).getString("name"))
    }

    @Test
    fun notificationWithoutIdReturnsNullAndToolsCallRoutesAction() {
        val notif = JSONObject()
            .put("jsonrpc", "2.0")
            .put("method", "notifications/initialized")
        assertNull(PhoneMcpServer.dispatchJsonRpc(notif) { _, _ -> JSONObject() })

        var capturedAction = ""
        val callReq = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 9)
            .put("method", "tools/call")
            .put(
                "params",
                JSONObject()
                    .put("name", "phone_tap")
                    .put("arguments", JSONObject().put("x", 120).put("y", 240).put("target", "Search")),
            )

        val okResp = PhoneMcpServer.dispatchJsonRpc(callReq) { action, _ ->
            capturedAction = action
            JSONObject().put("allowed", true).put("ok", true)
        }!!
        assertEquals("tap", capturedAction)
        assertFalse(okResp.getJSONObject("result").getBoolean("isError"))

        val blockedResp = PhoneMcpServer.dispatchJsonRpc(callReq) { _, _ ->
            JSONObject().put("allowed", false).put("reason", "Blocked by SafetyGate")
        }!!
        assertTrue(blockedResp.getJSONObject("result").getBoolean("isError"))
    }

    @Test
    fun minimalCodingModeReducesToolSchemasToNotifyOnly() {
        val listReq = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 3)
            .put("method", "tools/list")
        val minResp = PhoneMcpServer.dispatchJsonRpc(listReq, minimalCodingOnly = true) { _, _ -> JSONObject() }!!
        val tools = minResp.getJSONObject("result").getJSONArray("tools")
        assertEquals(2, tools.length())
        assertEquals("phone_notify", tools.getJSONObject(0).getString("name"))
        assertEquals("phone_subagent_notify", tools.getJSONObject(1).getString("name"))
    }

    @Test
    fun capturesLargeMcpOutputAsSessionVarAndResolvesInSubsequentCall() {
        SessionVariableStore.shared.clear()
        SessionVariableStore.enabled = true
        val bigTree = "HEADER\n" + "node ".repeat(400) + "\nFOOTER"
        val screenCall = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 10)
            .put("method", "tools/call")
            .put(
                "params",
                JSONObject()
                    .put("name", "phone_screen_tree")
                    .put("arguments", JSONObject().put("save_as", "screen_dump")),
            )

        val screenResp = PhoneMcpServer.dispatchJsonRpc(screenCall) { _, _ ->
            JSONObject().put("allowed", true).put("tree", bigTree)
        }!!
        val screenText = screenResp.getJSONObject("result").getJSONArray("content").getJSONObject(0).getString("text")
        assertTrue(screenText.contains("[VAR STORED: \$screen_dump"))

        var capturedText = ""
        val typeCall = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 11)
            .put("method", "tools/call")
            .put(
                "params",
                JSONObject()
                    .put("name", "phone_type")
                    .put("arguments", JSONObject().put("text", "Line1:\$screen_dump[1:1]")),
            )
        PhoneMcpServer.dispatchJsonRpc(typeCall) { _, args ->
            capturedText = args.optString("text", "")
            JSONObject().put("allowed", true).put("ok", true)
        }
        assertEquals("Line1:HEADER", capturedText)

        val inspectCall = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 12)
            .put("method", "tools/call")
            .put(
                "params",
                JSONObject()
                    .put("name", "var_inspect")
                    .put("arguments", JSONObject().put("name", "\$screen_dump").put("grep", "FOOTER")),
            )
        val inspectResp = PhoneMcpServer.dispatchJsonRpc(inspectCall) { _, _ -> JSONObject() }!!
        val inspectText = inspectResp.getJSONObject("result").getJSONArray("content").getJSONObject(0).getString("text")
        assertTrue(inspectText.contains("FOOTER"))
        SessionVariableStore.shared.clear()
    }
}
