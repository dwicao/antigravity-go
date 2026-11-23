package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.Base64
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
    private val outputOffloadDir: File? = null,
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
        val agent: String? = null,
        @Volatile var promptSummary: String,
        val startedAtMs: Long = System.currentTimeMillis(),
        val nextId: AtomicInteger = AtomicInteger(1),
        @Volatile var sessionId: String? = null,
        @Volatile var currentTurnId: String? = null,
        @Volatile var promptReqId: Int = -1,
        @Volatile var promptSent: Boolean = false,
        @Volatile var pendingPromptText: String? = null,
        @Volatile var pendingPromptAttachments: List<String> = emptyList(),
        val pendingConfigReqIds: MutableSet<Int> = Collections.synchronizedSet(mutableSetOf()),
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        val exitEmittedTurnIds: ConcurrentHashMap<String, Boolean> = ConcurrentHashMap(),
        val terminals: ConcurrentHashMap<String, TerminalProc> = ConcurrentHashMap(),
    )

    private val sessions = ConcurrentHashMap<String, ActiveAcp>()
    private val liveWorkers = LinkedHashMap<String, ActiveAcp>(4, 0.75f, true)

    private fun emitTurnExitOnce(turnId: String, exitCode: Int, active: ActiveAcp? = null) {
        if (active != null && active.exitEmittedTurnIds.putIfAbsent(turnId, true) != null) {
            return
        }
        emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to exitCode))
    }

    private fun takeLiveWorker(sessionId: String?, agent: String?): ActiveAcp? {
        if (sessionId.isNullOrBlank()) return null
        synchronized(liveWorkers) {
            val worker = liveWorkers[sessionId] ?: return null
            if (worker.agent != agent) return null
            liveWorkers.remove(sessionId)
            return worker
        }
    }

    private fun putLiveWorker(sessionId: String, active: ActiveAcp) {
        val evicted = mutableListOf<ActiveAcp>()
        synchronized(liveWorkers) {
            liveWorkers[sessionId] = active
            while (liveWorkers.size > 3) {
                val oldestKey = liveWorkers.keys.firstOrNull() ?: break
                liveWorkers.remove(oldestKey)?.let(evicted::add)
            }
        }
        for (worker in evicted) {
            worker.terminals.values.forEach { t -> runCatching { t.process.destroyForcibly() } }
            runCatching { worker.writer.close() }
            runCatching { worker.process.destroyForcibly() }
        }
    }

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
        val seenTermIds = HashSet<String>()
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
                if (tp.exitCode == null && tp.process.isAlive && seenTermIds.add(termId)) {
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
        val workersSnapshot = synchronized(liveWorkers) { liveWorkers.entries.map { it.key to it.value } }
        for ((sid, active) in workersSnapshot) {
            for ((termId, tp) in active.terminals) {
                if (tp.exitCode == null && tp.process.isAlive && seenTermIds.add(termId)) {
                    out.add(
                        mapOf(
                            "id" to termId,
                            "turnId" to sid,
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
        val workersSnapshot = synchronized(liveWorkers) { liveWorkers.values.toList() }
        for (active in (sessions.values + workersSnapshot)) {
            val tp = active.terminals[termId] ?: continue
            try {
                tp.process.destroyForcibly()
            } catch (_: Throwable) {}
            if (tp.exitCode == null) tp.exitCode = -1
            onTasksChanged()
            return true
        }
        return false
    }

    fun closeWorker(sessionId: String): Boolean {
        val worker = synchronized(liveWorkers) { liveWorkers.remove(sessionId) } ?: return false
        worker.terminals.values.forEach { term ->
            runCatching { term.process.destroyForcibly() }
        }
        runCatching { worker.writer.close() }
        runCatching { worker.process.destroyForcibly() }
        onTasksChanged()
        return true
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
        effort: String? = null,
        modeCli: String?,
        skipPermissions: Boolean,
        agent: String? = null,
        attachments: List<String> = emptyList(),
        clientVersion: String = "1.0.15",
        onAuthenticated: () -> Unit,
    ) {
        executor.submit {
            // Fast path: reuse an already-live ACP worker for this conversation & agent.
            // Zero respawn, zero session/load replay, 100% incremental turns.
            val reused = takeLiveWorker(existingSessionId, agent)
            if (reused != null && reused.process.isAlive) {
                try {
                    reused.promptSummary = summarizeCommand(prompt, maxLen = 64)
                    reused.cancelled.set(false)
                    reused.currentTurnId = turnId
                    reused.pendingConfigReqIds.clear()
                    reused.promptReqId = -1
                    reused.promptSent = false
                    reused.pendingPromptText = prompt
                    reused.pendingPromptAttachments = attachments
                    sessions[turnId] = reused
                    onTasksChanged()
                    emit(
                        mapOf(
                            "kind" to "turn_acp_line",
                            "turnId" to turnId,
                            "stdoutLine" to JSONObject()
                                .put("jsonrpc", "2.0")
                                .put("result", JSONObject().put("sessionId", existingSessionId))
                                .toString(),
                        )
                    )
                    queueConfigOptions(
                        active = reused,
                        writer = reused.writer,
                        sessionId = existingSessionId!!,
                        modelId = modelId,
                        effort = effort,
                        modeCli = modeCli,
                        skipPermissions = skipPermissions,
                    )
                    if (reused.pendingConfigReqIds.isEmpty()) {
                        val nextPromptId = reused.nextId.getAndIncrement()
                        reused.promptReqId = nextPromptId
                        reused.promptSent = true
                        reused.pendingPromptText = null
                        reused.pendingPromptAttachments = emptyList()
                        sendPromptRpc(
                            writer = reused.writer,
                            reqId = nextPromptId,
                            sessionId = existingSessionId,
                            prompt = prompt,
                            attachments = attachments,
                        )
                    }
                    return@submit
                } catch (t: Throwable) {
                    log("Reused ACP worker failed, falling back to fresh spawn: ${t.message}")
                    sessions.remove(turnId)
                    reused.currentTurnId = null
                    reused.promptReqId = -1
                    reused.cancelled.set(true)
                    try {
                        reused.process.destroyForcibly()
                    } catch (_: Throwable) {}
                }
            }

            var proc: Process? = null
            var activeRef: ActiveAcp? = null
            try {
                val cmd = mutableListOf(binaryPath, "acp")
                for (dir in extraDirs) {
                    if (dir.isNotBlank() && File(dir).exists()) {
                        cmd.addAll(listOf("--add-dir", dir))
                    }
                }
                if (!agent.isNullOrBlank()) {
                    cmd.addAll(listOf("--agent", agent))
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
                    agent = agent,
                    promptSummary = summarizeCommand(prompt, maxLen = 64),
                    currentTurnId = turnId,
                )
                activeRef = active
                sessions[turnId] = active
                onTasksChanged()

                val errFuture = executor.submit {
                    BufferedReader(InputStreamReader(proc.errorStream)).use { err ->
                        var line: String?
                        while (err.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            log("[acp-err] $l")
                            val targetTid = active.currentTurnId
                            if (targetTid != null) {
                                emit(
                                    mapOf(
                                        "kind" to "turn_stderr",
                                        "turnId" to targetTid,
                                        "stderrLine" to l,
                                    )
                                )
                            }
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
                                        .put("version", clientVersion)
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
                var triedLoadFallback = false
                var triedNewFallback = false

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
                                // Prefer session/resume so conversation continues WITHOUT replaying old turns.
                                sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", newSessionReqId)
                                        .put("method", "session/resume")
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

                        // Handle session/new, session/resume, or session/load response -> send config then prompt
                        if (msgId is Number && msgId.toInt() == newSessionReqId) {
                            if (msg.has("error") && !existingSessionId.isNullOrBlank() && !triedLoadFallback) {
                                triedLoadFallback = true
                                val errObj = msg.optJSONObject("error")
                                val errCode = errObj?.optInt("code", 0) ?: 0
                                newSessionReqId = active.nextId.getAndIncrement()
                                // If session/resume isn't supported (-32601), try session/load;
                                // if session was not found / expired, start fresh with session/new.
                                val fallbackMethod = if (errCode == -32601) "session/load" else "session/new"
                                val fallbackParams = if (fallbackMethod == "session/load") {
                                    JSONObject()
                                        .put("sessionId", existingSessionId)
                                        .put("cwd", cwd.absolutePath)
                                } else {
                                    JSONObject()
                                        .put("cwd", cwd.absolutePath)
                                        .put("mcpServers", JSONArray())
                                }
                                sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", newSessionReqId)
                                        .put("method", fallbackMethod)
                                        .put("params", fallbackParams)
                                )
                                continue
                            }
                            if (msg.has("error") && triedLoadFallback && !triedNewFallback && acpSessionId == null) {
                                triedNewFallback = true
                                // Final fallback: if session/load also failed, open a clean session/new
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

                            val activeTid = active.currentTurnId
                            if (activeTid != null) {
                                emit(
                                    mapOf(
                                        "kind" to "turn_acp_line",
                                        "turnId" to activeTid,
                                        "stdoutLine" to raw,
                                    )
                                )
                            }

                            if (acpSessionId != null) {
                                active.sessionId = acpSessionId
                                active.pendingConfigReqIds.clear()
                                active.pendingPromptText = prompt
                                active.pendingPromptAttachments = attachments
                                queueConfigOptions(
                                    active = active,
                                    writer = writer,
                                    sessionId = acpSessionId,
                                    modelId = modelId,
                                    effort = effort,
                                    modeCli = modeCli,
                                    skipPermissions = skipPermissions,
                                )

                                if (active.pendingConfigReqIds.isEmpty()) {
                                    val nextPid = active.nextId.getAndIncrement()
                                    active.promptReqId = nextPid
                                    active.promptSent = true
                                    active.pendingPromptText = null
                                    active.pendingPromptAttachments = emptyList()
                                    sendPromptRpc(
                                        writer = writer,
                                        reqId = nextPid,
                                        sessionId = acpSessionId,
                                        prompt = prompt,
                                        attachments = attachments,
                                    )
                                }
                            } else {
                                break
                            }
                            continue
                        }

                        // Wait until all session/set_config_option responses arrive before sending session/prompt.
                        val configMsgId = when (msgId) {
                            is Number -> msgId.toInt()
                            is String -> msgId.toIntOrNull()
                            else -> null
                        }
                        if (configMsgId != null && active.pendingConfigReqIds.remove(configMsgId)) {
                            val activeSid = active.sessionId
                            if (active.pendingConfigReqIds.isEmpty() && !active.promptSent && activeSid != null) {
                                val nextPid = active.nextId.getAndIncrement()
                                active.promptReqId = nextPid
                                active.promptSent = true
                                val pText = active.pendingPromptText ?: prompt
                                val pAtt = active.pendingPromptAttachments
                                active.pendingPromptText = null
                                active.pendingPromptAttachments = emptyList()
                                sendPromptRpc(
                                    writer = writer,
                                    reqId = nextPid,
                                    sessionId = activeSid,
                                    prompt = pText,
                                    attachments = pAtt,
                                )
                            }
                            continue
                        }

                        // Handle client filesystem & terminal capabilities directly!
                        if (method == "fs/read_text_file" && msgId != null) {
                            handleReadTextFile(active, writer, msgId, msg.optJSONObject("params"))
                            continue
                        }
                        if (method == "fs/write_text_file" && msgId != null) {
                            handleWriteTextFile(active, writer, msgId, msg.optJSONObject("params"))
                            continue
                        }
                        if (method.startsWith("terminal/") && msgId != null) {
                            handleTerminalRpc(active, method, msgId, msg.optJSONObject("params"))
                            continue
                        }

                        val activeTid = active.currentTurnId
                        if (activeTid == null) {
                            // Worker is idle between turns: forward reactive background wakeups without replaying history.
                            if (method == "session/update" || method == "session/request_permission") {
                                emit(
                                    mapOf(
                                        "kind" to "acp_wakeup",
                                        "sessionId" to (active.sessionId ?: ""),
                                        "stdoutLine" to raw,
                                    )
                                )
                            }
                            continue
                        }

                        // Ignore historical replay notifications from session/load until session/prompt is sent.
                        if (!shouldForwardAcpNotification(method, active.promptSent)) {
                            continue
                        }

                        // Forward notifications, permission requests, and errors to Flutter.
                        emit(
                            mapOf(
                                "kind" to "turn_acp_line",
                                "turnId" to activeTid,
                                "stdoutLine" to raw,
                            )
                        )

                        val numericMsgId = when (msgId) {
                            is Number -> msgId.toInt()
                            is String -> msgId.toIntOrNull()
                            else -> null
                        }
                        if (numericMsgId != null && numericMsgId == active.promptReqId) {
                            sessions.remove(activeTid)
                            active.currentTurnId = null
                            active.promptReqId = -1
                            emitTurnExitOnce(activeTid, 0, active)
                            val sid = active.sessionId
                            if (sid != null && proc.isAlive && !active.cancelled.get()) {
                                // Keep worker alive for incremental follow-ups & background tasks/terminals!
                                putLiveWorker(sid, active)
                                onTasksChanged()
                                continue
                            }
                            break
                        }
                    }
                }

                val danglingTurnId = active.currentTurnId
                if (danglingTurnId != null && !active.cancelled.get()) {
                    try {
                        errFuture.get(2, TimeUnit.SECONDS)
                    } catch (_: Throwable) {}
                    val exitCode = if (proc.waitFor(2, TimeUnit.SECONDS)) proc.exitValue() else {
                        proc.destroyForcibly()
                        1
                    }
                    emitTurnExitOnce(danglingTurnId, exitCode, active)
                }
            } catch (t: Throwable) {
                val activeTid = activeRef?.currentTurnId
                if (activeTid != null && activeRef?.cancelled?.get() != true) {
                    emit(
                        mapOf(
                            "kind" to "turn_stderr",
                            "turnId" to activeTid,
                            "stderrLine" to (t.message ?: t.toString()),
                        )
                    )
                    emitTurnExitOnce(activeTid, 1, activeRef)
                }
            } finally {
                val tid = activeRef?.currentTurnId
                val removed = if (tid != null) sessions.remove(tid) else sessions.remove(turnId)
                val sid = activeRef?.sessionId
                if (sid != null && activeRef != null) {
                    synchronized(liveWorkers) {
                        if (liveWorkers[sid] === activeRef) {
                            liveWorkers.remove(sid)
                        }
                    }
                }
                (removed ?: activeRef)?.terminals?.values?.forEach { term ->
                    try {
                        term.process.destroyForcibly()
                    } catch (_: Throwable) {}
                }
                onTasksChanged()
                try {
                    activeRef?.writer?.close()
                } catch (_: Throwable) {}
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
        active.cancelled.set(true)
        active.currentTurnId = null
        val sid = active.sessionId
        if (!sid.isNullOrBlank()) {
            synchronized(liveWorkers) {
                if (liveWorkers[sid] === active) liveWorkers.remove(sid)
            }
        }
        active.terminals.values.forEach { term ->
            try {
                term.process.destroyForcibly()
            } catch (_: Throwable) {}
        }
        onTasksChanged()
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
        try {
            active.writer.close()
        } catch (_: Throwable) {}
        active.process.destroyForcibly()
        emitTurnExitOnce(turnId, 130, active)
    }

    fun forceStopAll(): Int {
        val keys = sessions.keys.toList()
        var count = 0
        for (turnId in keys) {
            val active = sessions.remove(turnId) ?: continue
            active.cancelled.set(true)
            active.currentTurnId = null
            count++
            active.terminals.values.forEach { term ->
                try {
                    term.process.destroyForcibly()
                } catch (_: Throwable) {}
            }
            try {
                active.writer.close()
            } catch (_: Throwable) {}
            try {
                active.process.destroyForcibly()
            } catch (_: Throwable) {}
            emitTurnExitOnce(turnId, 137, active)
        }
        val workersToStop = synchronized(liveWorkers) {
            val list = liveWorkers.values.toList()
            liveWorkers.clear()
            list
        }
        for (worker in workersToStop) {
            worker.cancelled.set(true)
            count++
            worker.terminals.values.forEach { term ->
                try {
                    term.process.destroyForcibly()
                } catch (_: Throwable) {}
            }
            try {
                worker.writer.close()
            } catch (_: Throwable) {}
            try {
                worker.process.destroyForcibly()
            } catch (_: Throwable) {}
        }
        if (count > 0) onTasksChanged()
        return count
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
                    val argStrings = mutableListOf<String>()
                    if (argsArr != null) {
                        for (i in 0 until argsArr.length()) {
                            argStrings.add(argsArr.optString(i, ""))
                        }
                    }
                    val safety = CommandSafetyGuard.evaluateCommand(command, argStrings)
                    if (!safety.allowed) {
                        log("Harness Safety Guard blocked command: ${safety.reason}")
                        sendJson(
                            active.writer,
                            JSONObject()
                                .put("jsonrpc", "2.0")
                                .put("id", id)
                                .put(
                                    "error",
                                    JSONObject()
                                        .put("code", -32003)
                                        .put("message", safety.reason)
                                )
                        )
                        return
                    }
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
                        cmdList.addAll(argStrings)
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
                        if (tp.exitCode == null) {
                            tp.exitCode = try {
                                proc.waitFor()
                            } catch (_: Throwable) {
                                -1
                            }
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
                    val rawOut = tp?.output?.toString() ?: ""
                    val offloaded = CommandSafetyGuard.offloadIfLarge(
                        outputDir = outputOffloadDir,
                        callId = termId.ifBlank { "term" },
                        rawOutput = rawOut,
                    )
                    val res = JSONObject()
                        .put("output", offloaded.text)
                        .put("truncated", (tp?.output?.length ?: 0) >= 262_144 || offloaded.offloaded)
                    if (offloaded.filePath != null) {
                        res.put("offloadedPath", offloaded.filePath)
                    }
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
                    executor.submit {
                        try {
                            val code = tp?.process?.waitFor() ?: tp?.exitCode ?: 0
                            if (tp != null && tp.exitCode == null) {
                                tp.exitCode = code
                            }
                            onTasksChanged()
                            sendJson(
                                active.writer,
                                JSONObject()
                                    .put("jsonrpc", "2.0")
                                    .put("id", id)
                                    .put("result", JSONObject().put("exitCode", code))
                            )
                        } catch (t: Throwable) {
                            runCatching {
                                sendJson(
                                    active.writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", id)
                                        .put(
                                            "error",
                                            JSONObject().put("code", -32001).put("message", t.message ?: "wait_for_exit failed")
                                        )
                                )
                            }
                        }
                    }
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
        active: ActiveAcp,
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        try {
            val rawFile = File(path)
            val file = if (rawFile.isAbsolute) rawFile else File(active.defaultCwd, path)
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
        active: ActiveAcp,
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        val content = params?.optString("content", "") ?: ""
        val writeDecision = CommandSafetyGuard.evaluateWritePath(path, active.defaultCwd)
        if (!writeDecision.allowed) {
            log("Harness Safety Guard blocked file write: ${writeDecision.reason}")
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put(
                        "error",
                        JSONObject()
                            .put("code", -32003)
                            .put("message", writeDecision.reason)
                    )
            )
            return
        }
        try {
            val rawFile = File(path)
            val file = if (rawFile.isAbsolute) rawFile else File(active.defaultCwd, path)
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

    private fun queueConfigOptions(
        active: ActiveAcp,
        writer: OutputStreamWriter,
        sessionId: String,
        modelId: String?,
        effort: String?,
        modeCli: String?,
        skipPermissions: Boolean,
    ) {
        if (!modelId.isNullOrBlank()) {
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "model")
                            .put("value", modelId)
                    )
            )
        }
        if (!effort.isNullOrBlank() && !(modelId?.lowercase()?.contains("orchestrator") == true)) {
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "effort")
                            .put("value", effort)
                    )
            )
        }
        val safeModeCli = when (modeCli?.lowercase()?.trim()) {
            null, "", "auto" -> if (skipPermissions) null else "default"
            else -> modeCli
        }
        if (!safeModeCli.isNullOrBlank()) {
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "mode")
                            .put("value", safeModeCli)
                    )
            )
        }
    }

    private fun sendPromptRpc(
        writer: OutputStreamWriter,
        reqId: Int,
        sessionId: String,
        prompt: String,
        attachments: List<String>,
    ) {
        val blocks = JSONArray().put(
            JSONObject()
                .put("type", "text")
                .put("text", prompt)
        )
        for (rawPath in attachments) {
            val file = File(rawPath)
            if (!file.isFile) continue
            val ext = file.extension.lowercase()
            val mime = when (ext) {
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "gif" -> "image/gif"
                else -> null
            } ?: continue
            if (file.length() <= 0L || file.length() > 4L * 1024L * 1024L) continue
            runCatching {
                val b64 = Base64.getEncoder().encodeToString(file.readBytes())
                blocks.put(
                    JSONObject()
                        .put("type", "image")
                        .put("mimeType", mime)
                        .put("data", b64)
                )
            }
        }
        sendJson(
            writer,
            JSONObject()
                .put("jsonrpc", "2.0")
                .put("id", reqId)
                .put("method", "session/prompt")
                .put(
                    "params",
                    JSONObject()
                        .put("sessionId", sessionId)
                        .put("prompt", blocks)
                )
        )
    }

    private fun sendJson(writer: OutputStreamWriter, obj: JSONObject) {
        synchronized(writer) {
            writer.write(obj.toString())
            writer.write("\n")
            writer.flush()
        }
    }
}
