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
    private val onTasksChanged: () -> Unit = {},
) {
    private class TerminalProc(
        val process: Process,
        val command: String,
        val startedAtMs: Long = System.currentTimeMillis(),
        val output: StringBuffer = StringBuffer(),
        @Volatile var exitCode: Int? = null,
    )

    private data class ActiveAcp(
        val process: Process,
        val writer: OutputStreamWriter,
        val env: Map<String, String>,
        val defaultCwd: File,
        val promptSummary: String,
        val startedAtMs: Long = System.currentTimeMillis(),
        val nextId: AtomicInteger = AtomicInteger(1),
        @Volatile var sessionId: String? = null,
        val terminals: ConcurrentHashMap<String, TerminalProc> = ConcurrentHashMap(),
    )

    private val sessions = ConcurrentHashMap<String, ActiveAcp>()

    companion object {
        /**
         * `session/load` replays all prior historical `session/update` notifications
         * before responding with its JSON-RPC result. Suppress `session/update`
         * until `session/prompt` has actually been sent so previous chat results are
         * never duplicated into the new assistant reply bubble.
         */
        fun shouldForwardAcpNotification(method: String, promptSent: Boolean): Boolean {
            if (!promptSent && method == "session/update") return false
            return true
        }

        fun summarizeCommand(raw: String, maxLen: Int = 80): String {
            val singleLine = raw.trim().replace(Regex("\\s+"), " ")
            if (singleLine.isEmpty()) return "Shell command"
            return if (singleLine.length > maxLen) "${singleLine.take(maxLen - 1)}…" else singleLine
        }
    }

    fun listBackgroundTasks(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        for ((turnId, active) in sessions) {
            out.add(
                mapOf(
                    "id" to "turn:$turnId",
                    "turnId" to turnId,
                    "kind" to "turn",
                    "title" to active.promptSummary,
                    "status" to "running",
                    "startedAtMs" to active.startedAtMs,
                )
            )
            for ((termId, tp) in active.terminals) {
                if (tp.exitCode == null && tp.process.isAlive) {
                    out.add(
                        mapOf(
                            "id" to termId,
                            "turnId" to turnId,
                            "kind" to "terminal",
                            "title" to tp.command,
                            "status" to "running",
                            "startedAtMs" to tp.startedAtMs,
                        )
                    )
                }
            }
        }
        out.sortBy { (it["startedAtMs"] as? Long) ?: 0L }
        return out
    }

    fun cancelTerminal(termId: String): Boolean {
        for (active in sessions.values) {
            val tp = active.terminals[termId] ?: continue
            try {
                tp.process.destroyForcibly()
            } catch (_: Throwable) {}
            tp.exitCode = -1
            onTasksChanged()
            return true
        }
        return false
    }

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
                val active = ActiveAcp(
                    process = proc,
                    writer = writer,
                    env = env,
                    defaultCwd = cwd,
                    promptSummary = summarizeCommand(prompt, maxLen = 64),
                )
                sessions[turnId] = active
                onTasksChanged()

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
                var promptSent = false
                var triedLoadFallback = false
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
                            if (msg.has("error") && !existingSessionId.isNullOrBlank() && !triedLoadFallback) {
                                triedLoadFallback = true
                                newSessionReqId = active.nextId.getAndIncrement()
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
                                continue
                            }
                            val res = msg.optJSONObject("result")
                            acpSessionId = res?.optString("sessionId")
                                ?.takeIf { it.isNotBlank() } ?: if (res != null) existingSessionId else null

                            emit(
                                mapOf(
                                    "kind" to "turn_acp_line",
                                    "turnId" to turnId,
                                    "stdoutLine" to raw,
                                )
                            )

                            if (acpSessionId != null) {
                                active.sessionId = acpSessionId
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
                                val safeModeCli = when (modeCli?.lowercase()?.trim()) {
                                    null, "", "auto" -> if (skipPermissions) null else "default"
                                    else -> modeCli
                                }
                                if (!safeModeCli.isNullOrBlank()) {
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
                                                    .put("value", safeModeCli)
                                            )
                                    )
                                }

                                promptReqId = active.nextId.getAndIncrement()
                                promptSent = true
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

                        // Handle client filesystem & terminal capabilities directly!
                        if (method == "fs/read_text_file" && msgId != null) {
                            handleReadTextFile(writer, msgId, msg.optJSONObject("params"))
                            continue
                        }
                        if (method == "fs/write_text_file" && msgId != null) {
                            handleWriteTextFile(writer, msgId, msg.optJSONObject("params"))
                            continue
                        }
                        if (method.startsWith("terminal/") && msgId != null) {
                            handleTerminalRpc(active, method, msgId, msg.optJSONObject("params"))
                            continue
                        }

                        // Ignore historical replay notifications from session/load until session/prompt is sent.
                        if (!shouldForwardAcpNotification(method, promptSent)) {
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
                val removed = sessions.remove(turnId)
                removed?.terminals?.values?.forEach { term ->
                    try {
                        term.process.destroyForcibly()
                    } catch (_: Throwable) {}
                }
                if (removed != null) {
                    onTasksChanged()
                }
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
        active.terminals.values.forEach { term ->
            try {
                term.process.destroyForcibly()
            } catch (_: Throwable) {}
        }
        onTasksChanged()
        val sid = active.sessionId
        if (!sid.isNullOrBlank()) {
            try {
                sendJson(
                    active.writer,
                    JSONObject()
                        .put("jsonrpc", "2.0")
                        .put("method", "session/cancel")
                        .put("params", JSONObject().put("sessionId", sid))
                )
            } catch (_: Throwable) {}
        }
        active.process.destroyForcibly()
    }

    private fun handleTerminalRpc(
        active: ActiveAcp,
        method: String,
        id: Any,
        params: JSONObject?,
    ) {
        try {
            when (method) {
                "terminal/create" -> {
                    val command = params?.optString("command", "") ?: ""
                    val argsArr = params?.optJSONArray("args")
                    val cwdStr = params?.optString("cwd")?.takeIf { it.isNotBlank() }
                    val dir = if (cwdStr != null) File(cwdStr) else active.defaultCwd
                    if (!dir.exists()) dir.mkdirs()

                    val cmdList = mutableListOf<String>()
                    if (argsArr != null && argsArr.length() > 0) {
                        val resolved = if (command == "bash" || command == "/bin/bash") {
                            active.env["SHELL"] ?: "bash"
                        } else {
                            command
                        }
                        cmdList.add(resolved)
                        for (i in 0 until argsArr.length()) {
                            cmdList.add(argsArr.optString(i, ""))
                        }
                    } else {
                        val shell = active.env["SHELL"] ?: "/system/bin/sh"
                        cmdList.addAll(listOf(shell, "-c", command))
                    }

                    val pb = ProcessBuilder(cmdList)
                    pb.directory(dir)
                    pb.environment().putAll(active.env)
                    val envArr = params?.optJSONArray("env")
                    if (envArr != null) {
                        for (i in 0 until envArr.length()) {
                            val item = envArr.optJSONObject(i) ?: continue
                            val k = item.optString("name", "")
                            val v = item.optString("value", "")
                            if (k.isNotBlank()) pb.environment()[k] = v
                        }
                    }
                    pb.redirectErrorStream(true)
                    val proc = pb.start()
                    val termId = "term-${active.nextId.getAndIncrement()}"
                    val displayCmd = summarizeCommand(
                        if (cmdList.size >= 3 && cmdList[1] == "-c") cmdList[2] else cmdList.joinToString(" "),
                    )
                    val tp = TerminalProc(process = proc, command = displayCmd)
                    active.terminals[termId] = tp
                    onTasksChanged()

                    executor.submit {
                        try {
                            BufferedReader(InputStreamReader(proc.inputStream)).use { br ->
                                val buf = CharArray(4096)
                                var n: Int
                                while (br.read(buf).also { n = it } >= 0) {
                                    if (tp.output.length < 262_144) {
                                        tp.output.append(buf, 0, n)
                                    }
                                }
                            }
                        } catch (_: Throwable) {}
                        tp.exitCode = try {
                            proc.waitFor()
                        } catch (_: Throwable) {
                            -1
                        }
                        onTasksChanged()
                    }

                    sendJson(
                        active.writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put("result", JSONObject().put("terminalId", termId))
                    )
                }

                "terminal/output" -> {
                    val termId = params?.optString("terminalId", "") ?: ""
                    val tp = active.terminals[termId]
                    val res = JSONObject()
                        .put("output", tp?.output?.toString() ?: "")
                        .put("truncated", (tp?.output?.length ?: 0) >= 262_144)
                    tp?.exitCode?.let { code ->
                        res.put("exitStatus", JSONObject().put("exitCode", code))
                    }
                    sendJson(
                        active.writer,
                        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", res)
                    )
                }

                "terminal/wait_for_exit" -> {
                    val termId = params?.optString("terminalId", "") ?: ""
                    val tp = active.terminals[termId]
                    val code = tp?.process?.waitFor() ?: tp?.exitCode ?: 0
                    tp?.exitCode = code
                    onTasksChanged()
                    sendJson(
                        active.writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put("result", JSONObject().put("exitCode", code))
                    )
                }

                "terminal/kill" -> {
                    val termId = params?.optString("terminalId", "") ?: ""
                    active.terminals[termId]?.let { tp ->
                        tp.process.destroyForcibly()
                        tp.exitCode = -1
                        onTasksChanged()
                    }
                    sendJson(
                        active.writer,
                        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", JSONObject())
                    )
                }

                "terminal/release" -> {
                    val termId = params?.optString("terminalId", "") ?: ""
                    active.terminals.remove(termId)?.let { tp ->
                        tp.process.destroyForcibly()
                        onTasksChanged()
                    }
                    sendJson(
                        active.writer,
                        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", JSONObject())
                    )
                }

                else -> {
                    sendJson(
                        active.writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put(
                                "error",
                                JSONObject().put("code", -32601).put("message", "Method not found: $method")
                            )
                    )
                }
            }
        } catch (t: Throwable) {
            sendJson(
                active.writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put(
                        "error",
                        JSONObject().put("code", -32001).put("message", t.message ?: "Terminal RPC error")
                    )
            )
        }
    }

    private fun handleReadTextFile(
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        try {
            val file = File(path)
            if (file.isDirectory) {
                throw IllegalStateException("Path is a directory: $path")
            }
            if (!file.exists()) {
                throw IllegalStateException("File does not exist: $path")
            }
            val startLine = params?.optInt("line", 0) ?: 0
            val limit = params?.optInt("limit", 0) ?: 0
            val rawText = file.readText()
            val content = if (startLine > 0 || limit > 0) {
                val lines = rawText.lines()
                val from = (startLine - 1).coerceIn(0, lines.size)
                val to = if (limit > 0) (from + limit).coerceAtMost(lines.size) else lines.size
                lines.subList(from, to).joinToString("\n")
            } else {
                rawText
            }
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
