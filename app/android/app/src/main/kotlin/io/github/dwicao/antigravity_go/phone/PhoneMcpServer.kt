package io.github.dwicao.antigravity_go.phone

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.security.SecureRandom
import java.util.concurrent.Executors

/**
 * Lightweight loopback HTTP bridge exposing phone inspection and tap/input actions
 * guarded by [SafetyGate] and a per-session bearer token.
 */
class PhoneMcpServer(
    private val isStrictMode: () -> Boolean,
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

    fun start(): Int {
        if (serverSocket != null && port != null) return port!!
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        authToken = bytes.joinToString("") { "%02x".format(it) }
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
    }

    private fun writeHttpResponse(
        sock: java.net.Socket,
        status: String,
        body: JSONObject,
    ) {
        val jsonBytes = body.toString().toByteArray(Charsets.UTF_8)
        OutputStreamWriter(sock.getOutputStream(), Charsets.UTF_8).apply {
            write("HTTP/1.1 $status\r\n")
            write("Content-Type: application/json\r\n")
            write("Content-Length: ${jsonBytes.size}\r\n")
            write("Connection: close\r\n\r\n")
            write(String(jsonBytes, Charsets.UTF_8))
            flush()
        }
    }

    private fun handleClient(client: java.net.Socket) {
        client.use { sock ->
            sock.soTimeout = 10_000
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            val reqLine = reader.readLine() ?: return
            var contentLen = 0
            var authHeader: String? = null
            while (true) {
                val h = reader.readLine() ?: break
                if (h.isEmpty()) break
                val lower = h.lowercase()
                if (lower.startsWith("content-length:")) {
                    contentLen = h.substringAfter(":").trim().toIntOrNull() ?: 0
                } else if (lower.startsWith("authorization:")) {
                    authHeader = h.substringAfter(":").trim()
                }
            }

            val expectedToken = authToken
            if (expectedToken != null && authHeader != "Bearer $expectedToken") {
                writeHttpResponse(
                    sock,
                    "401 Unauthorized",
                    JSONObject().put("allowed", false).put("error", "Missing or invalid bearer token"),
                )
                return
            }
            if (contentLen < 0 || contentLen > 1_048_576) {
                writeHttpResponse(
                    sock,
                    "413 Payload Too Large",
                    JSONObject().put("allowed", false).put("error", "Payload exceeds 1 MB limit"),
                )
                return
            }

            val bodyChars = CharArray(contentLen)
            var read = 0
            while (read < contentLen) {
                val n = reader.read(bodyChars, read, contentLen - read)
                if (n < 0) break
                read += n
            }
            val body = String(bodyChars, 0, read)
            val svc = AgyAccessibilityService.instance
            if (svc == null) {
                writeHttpResponse(
                    sock,
                    "200 OK",
                    JSONObject().put("error", "Accessibility service is not connected"),
                )
                return
            }

            val payload = try {
                if (body.isNotBlank()) JSONObject(body) else JSONObject()
            } catch (_: Throwable) {
                writeHttpResponse(
                    sock,
                    "400 Bad Request",
                    JSONObject().put("allowed", false).put("error", "Invalid JSON payload"),
                )
                return
            }

            val action = payload.optString("action", if (reqLine.contains("/screen")) "screen" else "tap")
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
            val decision = SafetyGate.evaluate(
                strictMode = isStrictMode(),
                packageName = svc.currentPackageName(),
                action = action,
                targetLabel = combinedTarget,
                isPasswordField = isPassword,
            )
            onActionLogged(action, combinedTarget.ifEmpty { callerTarget }, decision.allowed, decision.reason)
            val resp = if (!decision.allowed) {
                JSONObject().put("allowed", false).put("reason", decision.reason)
            } else {
                when (action) {
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
            writeHttpResponse(sock, "200 OK", resp)
        }
    }
}
