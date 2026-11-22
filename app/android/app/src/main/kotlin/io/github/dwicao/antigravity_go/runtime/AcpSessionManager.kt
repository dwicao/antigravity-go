package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Drives interactive `agy acp` JSON-RPC 2.0 sessions over stdin/stdout so users get
 * live streaming updates, real `ToolApprovalCard` permission prompts (`session/request_permission`),
 * and direct `fs/read_text_file` / `fs/write_text_file` backed by Android All Files Access.
 */
class AcpSessionManager(
    private val executor: ExecutorService,
    private val emit: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit,
) {
    private data class ActiveAcp(
        val process: Process,
        val writer: OutputStreamWriter,
        val nextId: AtomicInteger = AtomicInteger(1),
    )

    private val sessions = ConcurrentHashMap<String, ActiveAcp>()

    fun startTurn(
        turnId: String,
        binaryPath: String,
        cwd: File,
        env: Map<String, String>,
        prompt: String,
        extraDirs: List<String>,
        existingSessionId: String?,
        modelId: String?,
        modeCli: String?,
        skipPermissions: Boolean,
        onAuthenticated: () -> Unit,
    ) {
        executor.submit {
            var proc: Process? = null
            try {
                val cmd = mutableListOf(binaryPath, "acp")
                for (dir in extraDirs) {
                    if (dir.isNotBlank() && File(dir).exists()) {
                        cmd.addAll(listOf("--add-dir", dir))
                    }
                }
                if (skipPermissions) {
                    cmd.add("--dangerously-skip-permissions")
                }

                val pb = ProcessBuilder(cmd)
                pb.directory(cwd)
                pb.environment().putAll(env)
                proc = pb.start()

                val writer = OutputStreamWriter(proc.outputStream, Charsets.UTF_8)
                val active = ActiveAcp(process = proc, writer = writer)
                sessions[turnId] = active

                val errFuture = executor.submit {
                    BufferedReader(InputStreamReader(proc.errorStream)).use { err ->
                        var line: String?
                        while (err.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            log("[acp-err] $l")
                            emit(
                                mapOf(
                                    "kind" to "turn_stderr",
                                    "turnId" to turnId,
                                    "stderrLine" to l,
                                )
                            )
                        }
                    }
                }

                // 1. initialize
                val initId = active.nextId.getAndIncrement()
                sendJson(
                    writer,
                    JSONObject()
                        .put("jsonrpc", "2.0")
                        .put("id", initId)
                        .put("method", "initialize")
                        .put(
                            "params",
                            JSONObject()
                                .put("protocolVersion", 1)
                                .put(
                                    "clientInfo",
                                    JSONObject()
                                        .put("name", "antigravity-go")
                                        .put("version", "1.0.1")
                                )
                                .put(
                                    "clientCapabilities",
                                    JSONObject()
                                        .put(
                                            "fs",
                                            JSONObject()
                                                .put("readTextFile", true)
                                                .put("writeTextFile", true)
                                        )
                                        .put("terminal", true)
                                        .put("terminal-auth", true)
                                )
                        )
                )

                var acpSessionId: String? = null
                var newSessionReqId = -1
                var promptReqId = -1
                var gotTurnResult = false

                BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        val raw = line?.trim() ?: continue
                        if (!raw.startsWith("{")) continue

                        val msg = try {
                            JSONObject(raw)
                        } catch (_: Throwable) {
                            continue
                        }

                        val msgId = msg.opt("id")
                        val method = msg.optString("method", "")

                        // Handle initialize response -> create or load session
                        if (msgId is Number && msgId.toInt() == initId) {
                            if (msg.has("error")) {
                                emit(
                                    mapOf(
                                        "kind" to "turn_acp_line",
                                        "turnId" to turnId,
                                        "stdoutLine" to raw,
                                    )
                                )
                                break
                            }
                            onAuthenticated()
                            newSessionReqId = active.nextId.getAndIncrement()
                            if (!existingSessionId.isNullOrBlank()) {
                                sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", newSessionReqId)
                                        .put("method", "session/load")
                                        .put(
                                            "params",
                                            JSONObject()
                                                .put("sessionId", existingSessionId)
                                                .put("cwd", cwd.absolutePath)
                                        )
                                )
                            } else {
                                sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", newSessionReqId)
                                        .put("method", "session/new")
                                        .put(
                                            "params",
                                            JSONObject()
                                                .put("cwd", cwd.absolutePath)
                                                .put("mcpServers", JSONArray())
                                        )
                                )
                            }
                            continue
                        }

                        // Handle session/new or session/load response -> send prompt
                        if (msgId is Number && msgId.toInt() == newSessionReqId) {
                            val res = msg.optJSONObject("result")
                            acpSessionId = res?.optString("sessionId")
                                ?.takeIf { it.isNotBlank() } ?: existingSessionId

                            emit(
                                mapOf(
                                    "kind" to "turn_acp_line",
                                    "turnId" to turnId,
                                    "stdoutLine" to raw,
                                )
                            )

                            if (acpSessionId != null) {
                                if (!modelId.isNullOrBlank()) {
                                    sendJson(
                                        writer,
                                        JSONObject()
                                            .put("jsonrpc", "2.0")
                                            .put("id", active.nextId.getAndIncrement())
                                            .put("method", "session/set_config_option")
                                            .put(
                                                "params",
                                                JSONObject()
                                                    .put("sessionId", acpSessionId)
                                                    .put("configId", "model")
                                                    .put("value", modelId)
                                            )
                                    )
                                }
                                if (!modeCli.isNullOrBlank()) {
                                    sendJson(
                                        writer,
                                        JSONObject()
                                            .put("jsonrpc", "2.0")
                                            .put("id", active.nextId.getAndIncrement())
                                            .put("method", "session/set_config_option")
                                            .put(
                                                "params",
                                                JSONObject()
                                                    .put("sessionId", acpSessionId)
                                                    .put("configId", "mode")
                                                    .put("value", modeCli)
                                            )
                                    )
                                }

                                promptReqId = active.nextId.getAndIncrement()
                                sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", promptReqId)
                                        .put("method", "session/prompt")
                                        .put(
                                            "params",
                                            JSONObject()
                                                .put("sessionId", acpSessionId)
                                                .put(
                                                    "prompt",
                                                    JSONArray().put(
                                                        JSONObject()
                                                            .put("type", "text")
                                                            .put("text", prompt)
                                                    )
                                                )
                                        )
                                )
                            } else {
                                break
                            }
                            continue
                        }

                        // Handle client filesystem capabilities directly using All Files Access!
                        if (method == "fs/read_text_file" && msgId != null) {
                            handleReadTextFile(writer, msgId, msg.optJSONObject("params"))
                            continue
                        }
                        if (method == "fs/write_text_file" && msgId != null) {
                            handleWriteTextFile(writer, msgId, msg.optJSONObject("params"))
                            continue
                        }

                        // Forward notifications, permission requests, and errors to Flutter.
                        emit(
                            mapOf(
                                "kind" to "turn_acp_line",
                                "turnId" to turnId,
                                "stdoutLine" to raw,
                            )
                        )

                        if (msgId is Number && msgId.toInt() == promptReqId) {
                            gotTurnResult = true
                            break
                        }
                    }
                }

                try {
                    writer.close()
                } catch (_: Throwable) {}
                errFuture.get(3, TimeUnit.SECONDS)
                val exitCode = proc.waitFor()
                emit(
                    mapOf(
                        "kind" to "turn_exit",
                        "turnId" to turnId,
                        "exitCode" to if (gotTurnResult) 0 else exitCode,
                    )
                )
            } catch (t: Throwable) {
                emit(
                    mapOf(
                        "kind" to "turn_stderr",
                        "turnId" to turnId,
                        "stderrLine" to (t.message ?: t.toString()),
                    )
                )
                emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to 1))
            } finally {
                sessions.remove(turnId)
                try {
                    proc?.destroy()
                } catch (_: Throwable) {}
            }
        }
    }

    fun respondToPermission(turnId: String, requestId: Any, optionId: String) {
        val active = sessions[turnId] ?: return
        executor.submit {
            try {
                val resp = JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", requestId)
                    .put(
                        "result",
                        JSONObject().put(
                            "outcome",
                            JSONObject()
                                .put("outcome", "selected")
                                .put("optionId", optionId)
                        )
                    )
                sendJson(active.writer, resp)
            } catch (t: Throwable) {
                log("Failed sending permission response: ${t.message}")
            }
        }
    }

    fun cancel(turnId: String) {
        val active = sessions.remove(turnId) ?: return
        active.process.destroyForcibly()
    }

    private fun handleReadTextFile(
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        try {
            val file = File(path)
            val content = if (file.exists() && file.isFile) file.readText() else ""
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject().put("content", content))
            )
        } catch (t: Throwable) {
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put(
                        "error",
                        JSONObject()
                            .put("code", -32001)
                            .put("message", t.message ?: "Read failed")
                    )
            )
        }
    }

    private fun handleWriteTextFile(
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        val content = params?.optString("content", "") ?: ""
        try {
            val file = File(path)
            file.parentFile?.mkdirs()
            file.writeText(content)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject())
            )
        } catch (t: Throwable) {
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put(
                        "error",
                        JSONObject()
                            .put("code", -32001)
                            .put("message", t.message ?: "Write failed")
                    )
            )
        }
    }

    @Synchronized
    private fun sendJson(writer: OutputStreamWriter, obj: JSONObject) {
        writer.write(obj.toString())
        writer.write("\n")
        writer.flush()
    }
}
