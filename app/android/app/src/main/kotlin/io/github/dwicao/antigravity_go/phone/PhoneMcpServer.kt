package io.github.dwicao.antigravity_go.phone

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Loopback HTTP & MCP (JSON-RPC 2.0 Streamable HTTP) bridge exposing Android screen inspection
 * and tap/input actions guarded by [SafetyGate] and a per-session bearer token.
 */
class PhoneMcpServer(
    private val isStrictMode: () -> Boolean,
    private val contextProvider: () -> android.content.Context? = { null },
    private val onActionLogged: (action: String, target: String, allowed: Boolean, reason: String) -> Unit,
) {
    private val executor = Executors.newCachedThreadPool()
    private var serverSocket: ServerSocket? = null

    @Volatile
    var port: Int? = null
        private set

    @Volatile
    var authToken: String? = null
        private set

    @Volatile
    private var mcpSessionId: String? = null

    fun start(): Int {
        if (serverSocket != null && port != null) return port!!
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        authToken = bytes.joinToString("") { "%02x".format(it) }
        mcpSessionId = UUID.randomUUID().toString()
        val sock = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        serverSocket = sock
        port = sock.localPort
        executor.submit {
            while (!sock.isClosed) {
                try {
                    val client = sock.accept()
                    executor.submit { handleClient(client) }
                } catch (_: Throwable) {
                    break
                }
            }
        }
        return port!!
    }

    fun stop() {
        try {
            serverSocket?.close()
        } catch (_: Throwable) {}
        serverSocket = null
        port = null
        authToken = null
        mcpSessionId = null
    }

    private fun writeHttpResponse(
        sock: java.net.Socket,
        status: String,
        body: String? = null,
        extraHeaders: Map<String, String> = emptyMap(),
    ) {
        val bytes = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        sock.getOutputStream().apply {
            val sb = StringBuilder()
            sb.append("HTTP/1.1 ").append(status).append("\r\n")
            if (body != null) {
                sb.append("Content-Type: application/json\r\n")
            }
            sb.append("Content-Length: ").append(bytes.size).append("\r\n")
            for ((k, v) in extraHeaders) {
                sb.append(k).append(": ").append(v).append("\r\n")
            }
            sb.append("Connection: close\r\n\r\n")
            write(sb.toString().toByteArray(Charsets.UTF_8))
            if (bytes.isNotEmpty()) {
                write(bytes)
            }
            flush()
        }
    }

    private fun writeJsonResponse(
        sock: java.net.Socket,
        status: String,
        body: JSONObject,
        extraHeaders: Map<String, String> = emptyMap(),
    ) = writeHttpResponse(sock, status, body.toString(), extraHeaders)

    private fun handleClient(client: java.net.Socket) {
        client.use { sock ->
            sock.soTimeout = 15_000
            val input = BufferedInputStream(sock.getInputStream())
            val reqLine = readAsciiLine(input) ?: return
            val reqParts = reqLine.split(" ")
            val httpMethod = reqParts.getOrNull(0)?.uppercase() ?: "POST"
            val reqPath = reqParts.getOrNull(1)?.substringBefore("?") ?: "/"

            var contentLen = -1
            var isChunked = false
            var authHeader: String? = null
            while (true) {
                val h = readAsciiLine(input) ?: break
                if (h.isEmpty()) break
                val lower = h.lowercase()
                when {
                    lower.startsWith("content-length:") -> {
                        contentLen = h.substringAfter(":").trim().toIntOrNull() ?: 0
                    }
                    lower.startsWith("transfer-encoding:") && lower.contains("chunked") -> {
                        isChunked = true
                    }
                    lower.startsWith("authorization:") -> {
                        authHeader = h.substringAfter(":").trim()
                    }
                }
            }

            val expectedToken = authToken
            if (expectedToken != null && authHeader != "Bearer $expectedToken") {
                writeJsonResponse(
                    sock,
                    "401 Unauthorized",
                    JSONObject().put("allowed", false).put("error", "Missing or invalid bearer token"),
                )
                return
            }

            if (httpMethod == "GET") {
                writeHttpResponse(sock, "405 Method Not Allowed", null)
                return
            }
            if (httpMethod == "DELETE") {
                writeHttpResponse(sock, "200 OK", null)
                return
            }

            if (!isChunked && contentLen > 1_048_576) {
                writeJsonResponse(
                    sock,
                    "413 Payload Too Large",
                    JSONObject().put("allowed", false).put("error", "Payload exceeds 1 MB limit"),
                )
                return
            }

            val body = try {
                when {
                    isChunked -> readChunkedBody(input, 1_048_576)
                    contentLen > 0 -> readFixedBody(input, contentLen)
                    else -> ""
                }
            } catch (_: PayloadTooLargeException) {
                writeJsonResponse(
                    sock,
                    "413 Payload Too Large",
                    JSONObject().put("allowed", false).put("error", "Payload exceeds 1 MB limit"),
                )
                return
            }

            val payload = try {
                if (body.isNotBlank()) JSONObject(body) else JSONObject()
            } catch (_: Throwable) {
                writeJsonResponse(
                    sock,
                    "400 Bad Request",
                    JSONObject().put("allowed", false).put("error", "Invalid JSON payload"),
                )
                return
            }

            // MCP Streamable HTTP JSON-RPC 2.0 endpoint
            if (payload.has("jsonrpc") || payload.has("method")) {
                val sidHeaders = mcpSessionId?.let { mapOf("Mcp-Session-Id" to it) } ?: emptyMap()
                val rpcResp = dispatchJsonRpc(payload) { action, paramsObj ->
                    executeAction(action, paramsObj)
                }
                if (rpcResp == null) {
                    writeHttpResponse(sock, "202 Accepted", null, sidHeaders)
                } else {
                    writeJsonResponse(sock, "200 OK", rpcResp, sidHeaders)
                }
                return
            }

            // Legacy / gateway REST endpoints (/screen, /tap, /type, /device, /notify, etc.)
            val defaultAction = when {
                reqPath.contains("/screen") -> "screen"
                reqPath.contains("/device") || reqPath.contains("/system") -> "device_info"
                reqPath.contains("/notify") -> "notify"
                reqPath.contains("/clipboard") -> "clipboard"
                reqPath.contains("/torch") -> "torch"
                reqPath.contains("/vibrate") -> "vibrate"
                reqPath.contains("/toast") -> "toast"
                reqPath.contains("/open_url") -> "open_url"
                else -> "tap"
            }
            val action = payload.optString("action", defaultAction)
            val resp = executeAction(action, payload)
            writeJsonResponse(sock, "200 OK", resp)
        }
    }

    private fun executeAction(action: String, payload: JSONObject): JSONObject {
        val ctx = contextProvider()
        when (action) {
            "device_info", "system_info" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val res = DeviceGatewayHelper.systemInfo(ctx)
                onActionLogged("device_info", "System telemetry", res.optBoolean("allowed", true), "OK")
                return res
            }
            "notify" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val mode = payload.optString("mode", "post")
                val title = payload.optString("title", "Antigravity")
                val msg = payload.optString("message", "")
                val res = DeviceGatewayHelper.notify(
                    context = ctx,
                    action = mode,
                    title = title,
                    message = msg,
                    tag = payload.optString("tag", "agy_task"),
                    id = payload.optInt("id", 4201),
                    progress = payload.optInt("progress", -1),
                    ongoing = payload.optBoolean("ongoing", false),
                    channel = payload.optString("channel", DeviceGatewayHelper.CHANNEL_TASKS),
                )
                onActionLogged("notify", "$title: $msg".take(64), res.optBoolean("allowed", false), res.optString("error", "Posted"))
                return res
            }
            "clipboard" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val mode = payload.optString("mode", "get")
                val text = payload.optString("text", "")
                val res = DeviceGatewayHelper.clipboard(ctx, mode, text)
                onActionLogged("clipboard", mode, res.optBoolean("allowed", true), if (mode == "get") "Read clipboard" else "Wrote ${text.length} chars")
                return res
            }
            "torch" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val enabled = payload.optBoolean("enabled", true)
                val res = DeviceGatewayHelper.setTorch(ctx, enabled)
                onActionLogged("torch", if (enabled) "on" else "off", res.optBoolean("allowed", false), res.optString("error", "OK"))
                return res
            }
            "vibrate" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val ms = payload.optLong("durationMs", 100L)
                val res = DeviceGatewayHelper.vibrate(ctx, ms)
                onActionLogged("vibrate", "${ms}ms", res.optBoolean("allowed", false), res.optString("error", "OK"))
                return res
            }
            "toast" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val msg = payload.optString("message", "")
                val res = DeviceGatewayHelper.toast(ctx, msg, payload.optBoolean("long", false))
                onActionLogged("toast", msg.take(64), true, "OK")
                return res
            }
            "open_url" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val url = payload.optString("url", "")
                val res = DeviceGatewayHelper.openUrl(ctx, url)
                onActionLogged("open_url", url.take(80), res.optBoolean("allowed", false), res.optString("error", "Opened"))
                return res
            }
            "shizuku_exec" -> {
                if (ctx == null) return JSONObject().put("allowed", false).put("error", "Android context unavailable")
                val cmd = payload.optString("command", "")
                val res = DeviceGatewayHelper.shizukuExec(ctx, cmd)
                val allowed = res.optBoolean("allowed", false)
                onActionLogged("shizuku_exec", cmd.take(64), allowed, res.optString("reason", res.optString("error", "OK")))
                return res
            }
        }
        return executeAccessibilityAction(action, payload)
    }

    private fun executeAccessibilityAction(action: String, payload: JSONObject): JSONObject {
        val svc = AgyAccessibilityService.instance
            ?: return JSONObject()
                .put("allowed", false)
                .put("error", "Accessibility service is not connected")

        val callerTarget = payload.optString("target", "")
        val (actualLabel, isPassword) = when (action) {
            "tap" -> svc.describeNodeAt(
                payload.optDouble("x", 0.0).toFloat(),
                payload.optDouble("y", 0.0).toFloat(),
            )
            "type" -> svc.describeFocusedInput()
            else -> "" to svc.isFocusedInputPassword()
        }
        val combinedTarget = listOf(callerTarget, actualLabel)
            .filter { it.isNotBlank() }
            .joinToString(" | ")
        val decision = PhoneControlCoordinator.evaluateWithRules(
            packageName = svc.currentPackageName(),
            action = action,
            targetLabel = combinedTarget,
            isPasswordField = isPassword,
        )
        onActionLogged(action, combinedTarget.ifEmpty { callerTarget }, decision.allowed, decision.reason)
        if (!decision.allowed) {
            return JSONObject().put("allowed", false).put("reason", decision.reason)
        }
        return when (action) {
            "screen" -> JSONObject().put("allowed", true).put("tree", svc.dumpTree())
            "tap" -> {
                val ok = svc.tapAt(
                    payload.optDouble("x", 0.0).toFloat(),
                    payload.optDouble("y", 0.0).toFloat(),
                )
                JSONObject().put("allowed", true).put("ok", ok)
            }
            "type" -> {
                val ok = svc.inputText(payload.optString("text", ""))
                JSONObject().put("allowed", true).put("ok", ok)
            }
            else -> JSONObject().put("allowed", false).put("reason", "Unknown action: $action")
        }
    }

    private class PayloadTooLargeException : RuntimeException()

    private fun readAsciiLine(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        var b = input.read()
        if (b < 0) return null
        while (b >= 0) {
            if (b == '\n'.code) break
            if (b != '\r'.code) out.write(b)
            b = input.read()
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    private fun readFixedBody(input: InputStream, len: Int): String {
        val buf = ByteArray(len)
        var read = 0
        while (read < len) {
            val n = input.read(buf, read, len - read)
            if (n < 0) break
            read += n
        }
        return String(buf, 0, read, Charsets.UTF_8)
    }

    private fun readChunkedBody(input: InputStream, maxBytes: Int): String {
        val out = ByteArrayOutputStream()
        while (true) {
            val sizeLine = readAsciiLine(input) ?: break
            val sizeHex = sizeLine.substringBefore(";").trim()
            val chunkSize = sizeHex.toIntOrNull(16) ?: break
            if (chunkSize == 0) {
                while (true) {
                    val trailer = readAsciiLine(input) ?: break
                    if (trailer.isEmpty()) break
                }
                break
            }
            if (out.size() + chunkSize > maxBytes) throw PayloadTooLargeException()
            val chunk = ByteArray(chunkSize)
            var read = 0
            while (read < chunkSize) {
                val n = input.read(chunk, read, chunkSize - read)
                if (n < 0) break
                read += n
            }
            out.write(chunk, 0, read)
            readAsciiLine(input)
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    companion object {
        fun toolDefinitions(): JSONArray {
            val screenTool = JSONObject()
                .put("name", "phone_screen_tree")
                .put(
                    "description",
                    "Inspect the current Android UI accessibility hierarchy (packages, coordinates, labels, clickable elements)."
                )
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject().put(
                                "target",
                                JSONObject()
                                    .put("type", "string")
                                    .put("description", "Optional audit label"),
                            ),
                        ),
                )

            val tapTool = JSONObject()
                .put("name", "phone_tap")
                .put(
                    "description",
                    "Tap Android screen coordinates (x, y). Guarded by SafetyGate against protected apps and sensitive confirmation buttons."
                )
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject()
                                .put(
                                    "x",
                                    JSONObject()
                                        .put("type", "number")
                                        .put("description", "Screen X coordinate in pixels"),
                                )
                                .put(
                                    "y",
                                    JSONObject()
                                        .put("type", "number")
                                        .put("description", "Screen Y coordinate in pixels"),
                                )
                                .put(
                                    "target",
                                    JSONObject()
                                        .put("type", "string")
                                        .put("description", "Human-readable description of target element"),
                                ),
                        )
                        .put("required", JSONArray().put("x").put("y")),
                )

            val typeTool = JSONObject()
                .put("name", "phone_type")
                .put(
                    "description",
                    "Input text into the currently focused Android field. Blocked automatically on password inputs and protected apps."
                )
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject()
                                .put(
                                    "text",
                                    JSONObject()
                                        .put("type", "string")
                                        .put("description", "Text to insert into focused field"),
                                )
                                .put(
                                    "target",
                                    JSONObject()
                                        .put("type", "string")
                                        .put("description", "Optional description of target field"),
                                ),
                        )
                        .put("required", JSONArray().put("text")),
                )

            val deviceInfoTool = JSONObject()
                .put("name", "phone_device_info")
                .put("description", "Read Android battery level, charging state, network type, free storage, memory, ABI, and Shizuku availability.")
                .put("inputSchema", JSONObject().put("type", "object").put("properties", JSONObject()))

            val notifyTool = JSONObject()
                .put("name", "phone_notify")
                .put("description", "Post or cancel a native Android notification (supports progress bar and alert channel).")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject()
                                .put("mode", JSONObject().put("type", "string").put("description", "post or cancel"))
                                .put("title", JSONObject().put("type", "string"))
                                .put("message", JSONObject().put("type", "string"))
                                .put("tag", JSONObject().put("type", "string"))
                                .put("progress", JSONObject().put("type", "integer"))
                                .put("channel", JSONObject().put("type", "string")),
                        ),
                )

            val clipboardTool = JSONObject()
                .put("name", "phone_clipboard")
                .put("description", "Read or write the Android system clipboard.")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject()
                                .put("mode", JSONObject().put("type", "string").put("description", "get or set"))
                                .put("text", JSONObject().put("type", "string")),
                        ),
                )

            val torchTool = JSONObject()
                .put("name", "phone_torch")
                .put("description", "Turn the Android camera flashlight torch on or off.")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject().put("enabled", JSONObject().put("type", "boolean")),
                        )
                        .put("required", JSONArray().put("enabled")),
                )

            val vibrateTool = JSONObject()
                .put("name", "phone_vibrate")
                .put("description", "Trigger Android haptic vibration feedback.")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject().put("durationMs", JSONObject().put("type", "integer"))),
                )

            val toastTool = JSONObject()
                .put("name", "phone_toast")
                .put("description", "Show a short or long native Android Toast popup.")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put(
                            "properties",
                            JSONObject()
                                .put("message", JSONObject().put("type", "string"))
                                .put("long", JSONObject().put("type", "boolean")),
                        )
                        .put("required", JSONArray().put("message")),
                )

            val openUrlTool = JSONObject()
                .put("name", "phone_open_url")
                .put("description", "Open an HTTP/HTTPS URL in Android's browser.")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject().put("url", JSONObject().put("type", "string")))
                        .put("required", JSONArray().put("url")),
                )

            val shizukuTool = JSONObject()
                .put("name", "phone_shizuku_exec")
                .put("description", "Run an ADB-level shell command via bundled Shizuku rish when available (guarded by CommandSafetyGuard).")
                .put(
                    "inputSchema",
                    JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject().put("command", JSONObject().put("type", "string")))
                        .put("required", JSONArray().put("command")),
                )

            return JSONArray()
                .put(screenTool)
                .put(tapTool)
                .put(typeTool)
                .put(deviceInfoTool)
                .put(notifyTool)
                .put(clipboardTool)
                .put(torchTool)
                .put(vibrateTool)
                .put(toastTool)
                .put(openUrlTool)
                .put(shizukuTool)
        }

        /**
         * Dispatches an MCP JSON-RPC 2.0 request. Returns `null` for notifications (no `id`).
         */
        fun dispatchJsonRpc(
            req: JSONObject,
            executeAction: (action: String, args: JSONObject) -> JSONObject,
        ): JSONObject? {
            val id = req.opt("id")
            val hasId = req.has("id") && id != null && id !== JSONObject.NULL
            val method = req.optString("method", "")
            val params = req.optJSONObject("params") ?: JSONObject()

            if (!hasId) {
                return null
            }

            return when (method) {
                "initialize" -> {
                    val reqProto = params.optString("protocolVersion", "2024-11-05")
                    val proto = if (reqProto.startsWith("202")) reqProto else "2024-11-05"
                    JSONObject()
                        .put("jsonrpc", "2.0")
                        .put("id", id)
                        .put(
                            "result",
                            JSONObject()
                                .put("protocolVersion", proto)
                                .put(
                                    "capabilities",
                                    JSONObject().put(
                                        "tools",
                                        JSONObject().put("listChanged", false),
                                    ),
                                )
                                .put(
                                    "serverInfo",
                                    JSONObject()
                                        .put("name", "phone-control")
                                        .put("version", "1.0.27"),
                                ),
                        )
                }

                "ping" -> JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject())

                "tools/list" -> JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject().put("tools", toolDefinitions()))

                "tools/call" -> {
                    val toolName = params.optString("name", "")
                    val args = params.optJSONObject("arguments") ?: JSONObject()
                    val action = when (toolName) {
                        "phone_screen_tree", "screen" -> "screen"
                        "phone_tap", "tap" -> "tap"
                        "phone_type", "type" -> "type"
                        "phone_device_info", "device_info", "system_info" -> "device_info"
                        "phone_notify", "notify" -> "notify"
                        "phone_clipboard", "clipboard" -> "clipboard"
                        "phone_torch", "torch" -> "torch"
                        "phone_vibrate", "vibrate" -> "vibrate"
                        "phone_toast", "toast" -> "toast"
                        "phone_open_url", "open_url" -> "open_url"
                        "phone_shizuku_exec", "shizuku_exec" -> "shizuku_exec"
                        else -> ""
                    }
                    if (action.isEmpty()) {
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put(
                                "error",
                                JSONObject()
                                    .put("code", -32602)
                                    .put("message", "Unknown tool: $toolName"),
                            )
                    } else {
                        val actionResp = executeAction(action, args)
                        val allowed = actionResp.optBoolean("allowed", false)
                        val isError = !allowed || actionResp.has("error")
                        val text = when {
                            action == "screen" && allowed -> actionResp.optString("tree", "")
                            else -> actionResp.toString(2)
                        }
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put(
                                "result",
                                JSONObject()
                                    .put(
                                        "content",
                                        JSONArray().put(
                                            JSONObject()
                                                .put("type", "text")
                                                .put("text", text),
                                        ),
                                    )
                                    .put("isError", isError),
                            )
                    }
                }

                else -> JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put(
                        "error",
                        JSONObject()
                            .put("code", -32601)
                            .put("message", "Method not found: $method"),
                    )
            }
        }
    }
}
