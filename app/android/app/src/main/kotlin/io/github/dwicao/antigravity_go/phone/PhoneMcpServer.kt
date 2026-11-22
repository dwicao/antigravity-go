package io.github.dwicao.antigravity_go.phone

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.Executors

/**
 * Lightweight loopback HTTP bridge exposing phone inspection and tap/input actions
 * guarded by [SafetyGate].
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

    fun start(): Int {
        if (serverSocket != null && port != null) return port!!
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
    }

    private fun handleClient(client: java.net.Socket) {
        client.use { sock ->
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            val reqLine = reader.readLine() ?: return
            var contentLen = 0
            while (true) {
                val h = reader.readLine() ?: break
                if (h.isEmpty()) break
                if (h.lowercase().startsWith("content-length:")) {
                    contentLen = h.substringAfter(":").trim().toIntOrNull() ?: 0
                }
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
            val resp = if (svc == null) {
                JSONObject().put("error", "Accessibility service is not connected")
            } else {
                val payload = if (body.isNotBlank()) JSONObject(body) else JSONObject()
                val action = payload.optString("action", if (reqLine.contains("/screen")) "screen" else "tap")
                val target = payload.optString("target", "")
                val decision = SafetyGate.evaluate(
                    strictMode = isStrictMode(),
                    packageName = svc.currentPackageName(),
                    action = action,
                    targetLabel = target,
                )
                onActionLogged(action, target, decision.allowed, decision.reason)
                if (!decision.allowed) {
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
            }

            val jsonBytes = resp.toString().toByteArray(Charsets.UTF_8)
            OutputStreamWriter(sock.getOutputStream(), Charsets.UTF_8).apply {
                write("HTTP/1.1 200 OK\r\n")
                write("Content-Type: application/json\r\n")
                write("Content-Length: ${jsonBytes.size}\r\n")
                write("Connection: close\r\n\r\n")
                write(String(jsonBytes, Charsets.UTF_8))
                flush()
            }
        }
    }
}
