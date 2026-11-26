package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

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
    outputOffloadDir: File? = null,
) {
    private val sessions = ConcurrentHashMap<String, ActiveAcp>()
    private val liveWorkers = LinkedHashMap<String, ActiveAcp>(4, 0.75f, true)
    private val standbyLock = Any()

    @Volatile
    private var standbyWorker: ActiveAcp? = null
    private val fsTerminalHandler = AcpFsTerminalHandler(
        executor = executor,
        log = log,
        onTasksChanged = onTasksChanged,
        outputOffloadDir = outputOffloadDir,
    )

    private fun takeStandbyWorker(expectedSignature: String): ActiveAcp? {
        synchronized(standbyLock) {
            val w = standbyWorker ?: return null
            if (w.process.isAlive && w.standbyReady && w.workerSignature == expectedSignature) {
                standbyWorker = null
                return w
            }
            return null
        }
    }

    private fun closeStandbyWorker() {
        val old: ActiveAcp?
        synchronized(standbyLock) {
            old = standbyWorker
            standbyWorker = null
        }
        if (old != null) {
            old.cancelled.set(true)
            old.claimSignal.complete("__CANCELLED__")
            old.terminals.values.forEach { t -> runCatching { t.process.destroyForcibly() } }
            runCatching { old.writer.close() }
            runCatching { old.process.destroyForcibly() }
        }
    }

    private fun emitTurnExitOnce(turnId: String, exitCode: Int, active: ActiveAcp? = null) {
        if (active != null && active.exitEmittedTurnIds.putIfAbsent(turnId, true) != null) {
            return
        }
        emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to exitCode))
    }

    private fun takeLiveWorker(
        sessionId: String?,
        agent: String?,
        expectedSignature: String,
    ): ActiveAcp? {
        if (sessionId.isNullOrBlank()) return null
        val stale: ActiveAcp?
        synchronized(liveWorkers) {
            val worker = liveWorkers[sessionId] ?: return null
            if (worker.agent == agent && worker.workerSignature == expectedSignature) {
                liveWorkers.remove(sessionId)
                return worker
            }
            stale = liveWorkers.remove(sessionId)
        }
        if (stale != null) {
            stale.terminals.values.forEach { t -> runCatching { t.process.destroyForcibly() } }
            runCatching { stale.writer.close() }
            runCatching { stale.process.destroyForcibly() }
            onTasksChanged()
        }
        return null
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

        fun summarizeCommand(raw: String, maxLen: Int = 80): String =
            AcpConfigAndPromptHelper.summarizeCommand(raw, maxLen)

        fun buildWorkerSignature(
            cwd: File,
            extraDirs: List<String>,
            skipPermissions: Boolean,
            agent: String?,
        ): String {
            val dirs = extraDirs.filter { it.isNotBlank() }.distinct().sorted().joinToString("|")
            return "${cwd.absolutePath}#$skipPermissions#${agent.orEmpty()}#$dirs"
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

    fun prewarm(
        binaryPath: String,
        cwd: File,
        env: Map<String, String>,
        extraDirs: List<String>,
        skipPermissions: Boolean,
        agent: String? = null,
        clientVersion: String = "1.0.45",
        onAuthenticated: () -> Unit,
    ) {
        executor.submit {
            val workerSig = buildWorkerSignature(cwd, extraDirs, skipPermissions, agent)
            synchronized(standbyLock) {
                val cur = standbyWorker
                if (cur != null && cur.process.isAlive && cur.workerSignature == workerSig) {
                    return@submit
                }
            }
            if (sessions.isNotEmpty() || synchronized(liveWorkers) { liveWorkers.isNotEmpty() }) {
                return@submit
            }
            closeStandbyWorker()
            var proc: Process? = null
            var activeRef: ActiveAcp? = null
            try {
                val cmd = mutableListOf(binaryPath, "acp")
                for (dir in extraDirs) {
                    if (dir.isNotBlank() && File(dir).exists()) {
                        cmd.addAll(listOf("--add-dir", dir))
                    }
                }
                if (!agent.isNullOrBlank()) cmd.addAll(listOf("--agent", agent))
                if (skipPermissions) cmd.add("--dangerously-skip-permissions")
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
                    workerSignature = workerSig,
                    promptSummary = "Standby ACP worker",
                    currentTurnId = null,
                )
                activeRef = active
                val errFuture = executor.submit {
                    BufferedReader(InputStreamReader(proc.errorStream)).use { err ->
                        var line: String?
                        while (err.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            if (l.trimStart().startsWith("ERROR: logging before google.Init:")) continue
                            val targetTid = active.currentTurnId
                            if (targetTid != null) {
                                emit(mapOf("kind" to "turn_stderr", "turnId" to targetTid, "stderrLine" to l))
                            }
                        }
                    }
                }
                val initId = active.nextId.getAndIncrement()
                AcpConfigAndPromptHelper.sendJson(
                    writer,
                    JSONObject()
                        .put("jsonrpc", "2.0")
                        .put("id", initId)
                        .put("method", "initialize")
                        .put(
                            "params",
                            JSONObject()
                                .put("protocolVersion", 1)
                                .put("clientInfo", JSONObject().put("name", "antigravity-go").put("version", clientVersion))
                                .put(
                                    "clientCapabilities",
                                    JSONObject()
                                        .put("fs", JSONObject().put("readTextFile", true).put("writeTextFile", true))
                                        .put("terminal", true)
                                        .put("terminal-auth", true)
                                )
                        )
                )
                BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                    var initDone = false
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        val raw = line?.trim() ?: continue
                        if (!raw.startsWith("{")) continue
                        val msg = try { JSONObject(raw) } catch (_: Throwable) { continue }
                        val msgId = msg.opt("id")
                        if (!initDone && msgId is Number && msgId.toInt() == initId) {
                            if (msg.has("error")) return@submit
                            initDone = true
                            onAuthenticated()
                            active.standbyReady = true
                            synchronized(standbyLock) {
                                if (standbyWorker == null && !active.cancelled.get()) {
                                    standbyWorker = active
                                } else {
                                    active.claimSignal.complete("__CANCELLED__")
                                }
                            }
                            val claimedTid = runCatching { active.claimSignal.get(120, TimeUnit.SECONDS) }.getOrNull()
                            if (claimedTurnCancelled(claimedTid, active)) {
                                return@submit
                            }
                            break
                        }
                    }
                    if (!initDone || active.currentTurnId == null) return@submit
                    runPostInitReadLoop(
                        active = active,
                        proc = proc,
                        writer = writer,
                        reader = reader,
                        errFuture = errFuture,
                        cwd = cwd,
                        existingSessionId = null,
                        skipPermissions = skipPermissions,
                    )
                }
            } catch (_: Throwable) {
            } finally {
                synchronized(standbyLock) {
                    if (standbyWorker === activeRef) standbyWorker = null
                }
                val tid = activeRef?.currentTurnId
                if (tid != null) {
                    sessions.remove(tid)
                }
                val sid = activeRef?.sessionId
                if (sid != null && activeRef != null) {
                    synchronized(liveWorkers) {
                        if (liveWorkers[sid] === activeRef) liveWorkers.remove(sid)
                    }
                }
                activeRef?.terminals?.values?.forEach { term ->
                    runCatching { term.process.destroyForcibly() }
                }
                onTasksChanged()
                runCatching { activeRef?.writer?.close() }
                runCatching { proc?.destroy() }
            }
        }
    }

    private fun runPostInitReadLoop(
        active: ActiveAcp,
        proc: Process,
        writer: OutputStreamWriter,
        reader: BufferedReader,
        errFuture: java.util.concurrent.Future<*>,
        cwd: File,
        existingSessionId: String?,
        skipPermissions: Boolean,
    ) {
        var acpSessionId: String? = null
        var triedLoadFallback = false
        var triedNewFallback = false
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

            if (msgId is Number && msgId.toInt() == active.newSessionReqId) {
                if (msg.has("error") && !existingSessionId.isNullOrBlank() && !triedLoadFallback) {
                    triedLoadFallback = true
                    val errObj = msg.optJSONObject("error")
                    val errCode = errObj?.optInt("code", 0) ?: 0
                    val nextId = active.nextId.getAndIncrement()
                    active.newSessionReqId = nextId
                    val fallbackMethod = if (errCode == -32601) "session/load" else "session/new"
                    val fallbackParams = if (fallbackMethod == "session/load") {
                        JSONObject()
                            .put("sessionId", existingSessionId)
                            .put("cwd", cwd.absolutePath)
                    } else {
                        JSONObject()
                            .put("cwd", cwd.absolutePath)
                            .put("mcpServers", AcpConfigAndPromptHelper.buildMcpServersArray())
                    }
                    AcpConfigAndPromptHelper.sendJson(
                        writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", nextId)
                            .put("method", fallbackMethod)
                            .put("params", fallbackParams)
                    )
                    continue
                }
                if (msg.has("error") && triedLoadFallback && !triedNewFallback && acpSessionId == null) {
                    triedNewFallback = true
                    val nextId = active.nextId.getAndIncrement()
                    active.newSessionReqId = nextId
                    AcpConfigAndPromptHelper.sendJson(
                        writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", nextId)
                            .put("method", "session/new")
                            .put(
                                "params",
                                JSONObject()
                                    .put("cwd", cwd.absolutePath)
                                    .put("mcpServers", AcpConfigAndPromptHelper.buildMcpServersArray())
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
                    AcpConfigAndPromptHelper.queueConfigOptions(
                        active = active,
                        writer = writer,
                        sessionId = acpSessionId,
                        modelId = active.pendingModelId,
                        effort = active.pendingEffort,
                        modeCli = active.pendingModeCli,
                        skipPermissions = skipPermissions,
                    )

                    if (active.pendingConfigReqIds.isEmpty()) {
                        val nextPid = active.nextId.getAndIncrement()
                        active.promptReqId = nextPid
                        active.promptSent = true
                        val pText = active.pendingPromptText ?: ""
                        val pAtt = active.pendingPromptAttachments
                        active.pendingPromptText = null
                        active.pendingPromptAttachments = emptyList()
                        AcpConfigAndPromptHelper.sendPromptRpc(
                            writer = writer,
                            reqId = nextPid,
                            sessionId = acpSessionId,
                            prompt = pText,
                            attachments = pAtt,
                        )
                    }
                } else {
                    break
                }
                continue
            }

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
                    val pText = active.pendingPromptText ?: ""
                    val pAtt = active.pendingPromptAttachments
                    active.pendingPromptText = null
                    active.pendingPromptAttachments = emptyList()
                    AcpConfigAndPromptHelper.sendPromptRpc(
                        writer = writer,
                        reqId = nextPid,
                        sessionId = activeSid,
                        prompt = pText,
                        attachments = pAtt,
                    )
                }
                continue
            }

            if (method == "fs/read_text_file" && msgId != null) {
                fsTerminalHandler.handleReadTextFile(active, writer, msgId, msg.optJSONObject("params"))
                continue
            }
            if (method == "fs/write_text_file" && msgId != null) {
                fsTerminalHandler.handleWriteTextFile(active, writer, msgId, msg.optJSONObject("params"))
                continue
            }
            if (method.startsWith("terminal/") && msgId != null) {
                fsTerminalHandler.handleTerminalRpc(active, method, msgId, msg.optJSONObject("params"))
                continue
            }

            val activeTid = active.currentTurnId
            if (activeTid == null) {
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

            if (!shouldForwardAcpNotification(method, active.promptSent)) {
                continue
            }

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
                    putLiveWorker(sid, active)
                    onTasksChanged()
                    continue
                }
                break
            }
        }

        val danglingTurnId = active.currentTurnId
        if (danglingTurnId != null && !active.cancelled.get()) {
            runCatching { errFuture.get(2, TimeUnit.SECONDS) }
            val exitCode = if (proc.waitFor(2, TimeUnit.SECONDS)) proc.exitValue() else {
                proc.destroyForcibly()
                1
            }
            emitTurnExitOnce(danglingTurnId, exitCode, active)
        }
    }

    private fun claimedTurnCancelled(claimedTid: String?, active: ActiveAcp): Boolean {
        return claimedTid.isNullOrBlank() || claimedTid == "__CANCELLED__" || active.cancelled.get()
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
        clientVersion: String = "1.0.16",
        onAuthenticated: () -> Unit,
    ) {
        executor.submit {
            val workerSig = buildWorkerSignature(cwd, extraDirs, skipPermissions, agent)
            val reused = takeLiveWorker(existingSessionId, agent, workerSig)
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
                    AcpConfigAndPromptHelper.queueConfigOptions(
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
                        AcpConfigAndPromptHelper.sendPromptRpc(
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
                    runCatching { reused.process.destroyForcibly() }
                }
            }

            val standby = if (existingSessionId.isNullOrBlank()) takeStandbyWorker(workerSig) else null
            if (standby != null && standby.process.isAlive) {
                try {
                    standby.promptSummary = summarizeCommand(prompt, maxLen = 64)
                    standby.cancelled.set(false)
                    standby.currentTurnId = turnId
                    standby.pendingConfigReqIds.clear()
                    standby.promptReqId = -1
                    standby.promptSent = false
                    standby.pendingPromptText = prompt
                    standby.pendingPromptAttachments = attachments
                    standby.pendingModelId = modelId
                    standby.pendingEffort = effort
                    standby.pendingModeCli = modeCli
                    val newId = standby.nextId.getAndIncrement()
                    standby.newSessionReqId = newId
                    sessions[turnId] = standby
                    onTasksChanged()
                    standby.claimSignal.complete(turnId)
                    AcpConfigAndPromptHelper.sendJson(
                        standby.writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", newId)
                            .put("method", "session/new")
                            .put(
                                "params",
                                JSONObject()
                                    .put("cwd", cwd.absolutePath)
                                    .put("mcpServers", AcpConfigAndPromptHelper.buildMcpServersArray())
                            )
                    )
                    return@submit
                } catch (t: Throwable) {
                    log("Standby ACP worker failed, falling back to fresh spawn: ${t.message}")
                    sessions.remove(turnId)
                    standby.currentTurnId = null
                    standby.cancelled.set(true)
                    standby.claimSignal.complete("__CANCELLED__")
                    runCatching { standby.process.destroyForcibly() }
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
                    workerSignature = workerSig,
                    promptSummary = summarizeCommand(prompt, maxLen = 64),
                    currentTurnId = turnId,
                    pendingPromptText = prompt,
                    pendingPromptAttachments = attachments,
                    pendingModelId = modelId,
                    pendingEffort = effort,
                    pendingModeCli = modeCli,
                )
                activeRef = active
                sessions[turnId] = active
                onTasksChanged()

                val errFuture = executor.submit {
                    BufferedReader(InputStreamReader(proc.errorStream)).use { err ->
                        var line: String?
                        while (err.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            if (l.trimStart().startsWith("ERROR: logging before google.Init:")) {
                                continue
                            }
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

                val initId = active.nextId.getAndIncrement()
                AcpConfigAndPromptHelper.sendJson(
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

                BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                    var initDone = false
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
                        if (msgId is Number && msgId.toInt() == initId) {
                            if (msg.has("error")) {
                                emit(
                                    mapOf(
                                        "kind" to "turn_acp_line",
                                        "turnId" to turnId,
                                        "stdoutLine" to raw,
                                    )
                                )
                                return@submit
                            }
                            initDone = true
                            onAuthenticated()
                            val nextNewId = active.nextId.getAndIncrement()
                            active.newSessionReqId = nextNewId
                            if (!existingSessionId.isNullOrBlank()) {
                                AcpConfigAndPromptHelper.sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", nextNewId)
                                        .put("method", "session/resume")
                                        .put(
                                            "params",
                                            JSONObject()
                                                .put("sessionId", existingSessionId)
                                                .put("cwd", cwd.absolutePath)
                                        )
                                )
                            } else {
                                AcpConfigAndPromptHelper.sendJson(
                                    writer,
                                    JSONObject()
                                        .put("jsonrpc", "2.0")
                                        .put("id", nextNewId)
                                        .put("method", "session/new")
                                        .put(
                                            "params",
                                            JSONObject()
                                                .put("cwd", cwd.absolutePath)
                                                .put("mcpServers", AcpConfigAndPromptHelper.buildMcpServersArray())
                                        )
                                )
                            }
                            break
                        }
                    }
                    if (initDone) {
                        runPostInitReadLoop(
                            active = active,
                            proc = proc,
                            writer = writer,
                            reader = reader,
                            errFuture = errFuture,
                            cwd = cwd,
                            existingSessionId = existingSessionId,
                            skipPermissions = skipPermissions,
                        )
                    }
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
                    runCatching { term.process.destroyForcibly() }
                }
                onTasksChanged()
                runCatching { activeRef?.writer?.close() }
                runCatching { proc?.destroy() }
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
                AcpConfigAndPromptHelper.sendJson(active.writer, resp)
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
            runCatching { term.process.destroyForcibly() }
        }
        onTasksChanged()
        if (!sid.isNullOrBlank()) {
            runCatching {
                AcpConfigAndPromptHelper.sendJson(
                    active.writer,
                    JSONObject()
                        .put("jsonrpc", "2.0")
                        .put("method", "session/cancel")
                        .put("params", JSONObject().put("sessionId", sid))
                )
            }
        }
        runCatching { active.writer.close() }
        active.process.destroyForcibly()
        emitTurnExitOnce(turnId, 130, active)
    }

    fun forceStopAll(): Int {
        closeStandbyWorker()
        val keys = sessions.keys.toList()
        var count = 0
        for (turnId in keys) {
            val active = sessions.remove(turnId) ?: continue
            active.cancelled.set(true)
            active.currentTurnId = null
            count++
            active.terminals.values.forEach { term ->
                runCatching { term.process.destroyForcibly() }
            }
            runCatching { active.writer.close() }
            runCatching { active.process.destroyForcibly() }
            emitTurnExitOnce(turnId, 137, active)
        }
        count += closeAllLiveWorkers(notifyTasks = false)
        if (count > 0) onTasksChanged()
        return count
    }

    fun closeAllLiveWorkers(notifyTasks: Boolean = true): Int {
        closeStandbyWorker()
        val workersToStop = synchronized(liveWorkers) {
            val list = liveWorkers.values.toList()
            liveWorkers.clear()
            list
        }
        for (worker in workersToStop) {
            worker.cancelled.set(true)
            worker.terminals.values.forEach { term ->
                runCatching { term.process.destroyForcibly() }
            }
            runCatching { worker.writer.close() }
            runCatching { worker.process.destroyForcibly() }
        }
        if (notifyTasks && workersToStop.isNotEmpty()) onTasksChanged()
        return workersToStop.size
    }
}
