package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.RandomAccessFile
import java.util.concurrent.ExecutorService

/**
 * Handles client-side ACP `fs/read_text_file`, `fs/write_text_file`, and `terminal` RPC calls
 * guarded by [CommandSafetyGuard].
 */
internal class AcpFsTerminalHandler(
    private val executor: ExecutorService,
    private val log: (String) -> Unit,
    private val onTasksChanged: () -> Unit,
    private val outputOffloadDir: File?,
    private val emitVarSaved: (
        turnId: String?,
        name: String,
        toolName: String,
        target: String,
        rawValue: String,
    ) -> Unit = { _, _, _, _, _ -> },
) {
    fun handleTerminalRpc(
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
                    val fullCmd = if (argStrings.isEmpty()) command else "$command ${argStrings.joinToString(" ")}"
                    val hookDecision = if (safety.allowed) {
                        LifecycleHooksManager.evaluatePreToolUse("shell", fullCmd)
                    } else {
                        safety
                    }
                    if (!hookDecision.allowed) {
                        log("Harness Safety Guard blocked command: ${hookDecision.reason}")
                        AcpConfigAndPromptHelper.sendJson(
                            active.writer,
                            JSONObject()
                                .put("jsonrpc", "2.0")
                                .put("id", id)
                                .put(
                                    "error",
                                    JSONObject()
                                        .put("code", -32003)
                                        .put("message", hookDecision.reason)
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
                    val displayCmd = AcpConfigAndPromptHelper.summarizeCommand(
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

                    AcpConfigAndPromptHelper.sendJson(
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
                    val rawUnfiltered = tp?.output?.toString() ?: ""
                    val rawOut = CommandSafetyGuard.compressTerminalOutput(rawUnfiltered)
                    val offloaded = CommandSafetyGuard.offloadIfLarge(
                        outputDir = outputOffloadDir,
                        callId = termId.ifBlank { "term" },
                        rawOutput = rawOut,
                    )
                    var finalOut = offloaded.text
                    var savedVarName: String? = null
                    if (SessionVariableStore.enabled && rawOut.isNotEmpty()) {
                        val entry = SessionVariableStore.shared.save(
                            toolName = "terminal",
                            rawOutput = rawOut,
                            target = tp?.command ?: termId,
                        )
                        savedVarName = entry.name
                        emitVarSaved(
                            active.currentTurnId,
                            entry.name,
                            "terminal",
                            tp?.command ?: termId,
                            rawOut,
                        )
                        if (rawOut.length > 1_200) {
                            finalOut = SessionVariableStore.shared.formatCompactHandle(
                                entry = entry,
                                offloadedPath = offloaded.filePath,
                            )
                        }
                    }
                    val res = JSONObject()
                        .put("output", finalOut)
                        .put("truncated", (tp?.output?.length ?: 0) >= 262_144 || offloaded.offloaded || (SessionVariableStore.enabled && rawOut.length > 1_200))
                    if (savedVarName != null) {
                        res.put("variable", "\$$savedVarName")
                    }
                    if (offloaded.filePath != null) {
                        res.put("offloadedPath", offloaded.filePath)
                    }
                    tp?.exitCode?.let { code ->
                        res.put("exitStatus", JSONObject().put("exitCode", code))
                    }
                    AcpConfigAndPromptHelper.sendJson(
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
                            AcpConfigAndPromptHelper.sendJson(
                                active.writer,
                                JSONObject()
                                    .put("jsonrpc", "2.0")
                                    .put("id", id)
                                    .put("result", JSONObject().put("exitCode", code))
                            )
                        } catch (t: Throwable) {
                            runCatching {
                                AcpConfigAndPromptHelper.sendJson(
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
                    AcpConfigAndPromptHelper.sendJson(
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
                    AcpConfigAndPromptHelper.sendJson(
                        active.writer,
                        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", JSONObject())
                    )
                }

                else -> {
                    AcpConfigAndPromptHelper.sendJson(
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
            AcpConfigAndPromptHelper.sendJson(
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

    companion object {
        private const val LARGE_FILE_STREAM_THRESHOLD_BYTES = 512L * 1024L

        internal fun readBoundedFileContent(
            file: File,
            startLine: Int = 0,
            limit: Int = 0,
        ): String {
            if (startLine > 0 || limit > 0) {
                val from = (startLine - 1).coerceAtLeast(0)
                val maxLines = if (limit > 0) limit else Int.MAX_VALUE
                val selected = ArrayList<String>(limit.coerceIn(16, 512))
                var totalChars = 0
                var truncatedPartial = false
                file.bufferedReader(Charsets.UTF_8).use { br ->
                    var lineIdx = 0
                    while (true) {
                        val l = br.readLine() ?: break
                        if (lineIdx >= from) {
                            if (totalChars + l.length + 1 > 24_000 && selected.isNotEmpty()) {
                                truncatedPartial = true
                                break
                            }
                            selected.add(
                                if (l.length > 24_000) {
                                    truncatedPartial = true
                                    l.take(24_000)
                                } else {
                                    l
                                },
                            )
                            totalChars += l.length + 1
                            if (selected.size >= maxLines || totalChars >= 24_000) {
                                break
                            }
                        }
                        lineIdx++
                    }
                }
                val joined = selected.joinToString("\n")
                return if (truncatedPartial) {
                    "$joined\n... [TRUNCATED partial read at 24,000 chars — narrow line/limit range]"
                } else {
                    joined
                }
            }

            val fileBytes = file.length()
            if (fileBytes > LARGE_FILE_STREAM_THRESHOLD_BYTES) {
                val headBytes = ByteArray(16_000)
                val tailBytes = ByteArray(4_000)
                var headLen = 0
                var tailLen = 0
                RandomAccessFile(file, "r").use { raf ->
                    headLen = raf.read(headBytes).coerceAtLeast(0)
                    val tailStart = (fileBytes - tailBytes.size).coerceAtLeast(0L)
                    raf.seek(tailStart)
                    tailLen = raf.read(tailBytes).coerceAtLeast(0)
                }
                val head = String(headBytes, 0, headLen, Charsets.UTF_8)
                val tail = String(tailBytes, 0, tailLen, Charsets.UTF_8)
                return "$head\n\n... [TRUNCATED large file ($fileBytes bytes total) — re-call fs/read_text_file with line & limit to inspect specific sections] ...\n\n$tail"
            }

            val rawText = file.readText()
            if (rawText.length > 24_000) {
                val lines = rawText.lines()
                return if (lines.size > 320) {
                    val head = lines.take(220).joinToString("\n")
                    val tail = lines.takeLast(60).joinToString("\n")
                    val omitted = lines.size - 280
                    "$head\n\n... [TRUNCATED $omitted middle lines (${lines.size} lines / ${rawText.length} chars total) — re-call fs/read_text_file with line & limit to inspect specific sections] ...\n\n$tail"
                } else {
                    rawText.take(16_000) + "\n\n... [TRUNCATED ${rawText.length - 20_000} middle chars] ...\n\n" + rawText.takeLast(4_000)
                }
            }
            return rawText
        }
    }

    fun handleReadTextFile(
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
            val forceReread = params?.optBoolean("force_reread", false) ?: false
            val canonPath = runCatching { file.canonicalPath }.getOrDefault(file.absolutePath)
            var content = readBoundedFileContent(file, startLine = startLine, limit = limit)
            val mtimeMs = file.lastModified()
            if (SessionVariableStore.enabled && !forceReread && content.length > 2_000) {
                val hit = SessionVariableStore.shared.checkFileRead(
                    path = canonPath,
                    startLine = startLine,
                    limit = limit,
                    currentContent = content,
                    modifiedMs = mtimeMs,
                )
                if (hit != null) {
                    content = "[READ-ONCE CACHE HIT: $path is unchanged (${hit.lineCount} lines, stored in \$${hit.varName}). Call var_inspect or re-read with line/limit or force_reread:true if full text needed.]"
                    AcpConfigAndPromptHelper.sendJson(
                        writer,
                        JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put("result", JSONObject().put("content", content))
                    )
                    return
                }
            }
            if (SessionVariableStore.enabled && file.length() <= 2L * 1024L * 1024L && content.length > 2_000) {
                val fullText = if (startLine == 0 && limit == 0 && file.length() > 24_000L) {
                    runCatching { file.readText() }.getOrNull() ?: content
                } else {
                    content
                }
                val entry = SessionVariableStore.shared.save(
                    toolName = "read_file",
                    rawOutput = fullText,
                    target = path,
                )
                SessionVariableStore.shared.recordFileRead(
                    path = canonPath,
                    startLine = startLine,
                    limit = limit,
                    content = content,
                    varName = entry.name,
                    modifiedMs = mtimeMs,
                )
                emitVarSaved(
                    active.currentTurnId,
                    entry.name,
                    "read_file",
                    path,
                    fullText,
                )
                content = if (startLine == 0 && limit == 0 && SessionVariableStore.isLockOrGeneratedFile(path)) {
                    SessionVariableStore.shared.formatCompactHandle(
                        entry = entry,
                        thresholdChars = 400,
                        headChars = 220,
                        tailChars = 120,
                    )
                } else if (startLine == 0 && limit == 0 && file.length() > 24_000L) {
                    "[VAR STORED: \$${entry.name} (${entry.summary}) — pass \$${entry.name} or \$v_last in write_file/MCP args/reply]\n$content"
                } else {
                    content
                }
            }
            AcpConfigAndPromptHelper.sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject().put("content", content))
            )
        } catch (t: Throwable) {
            AcpConfigAndPromptHelper.sendJson(
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

    fun handleWriteTextFile(
        active: ActiveAcp,
        writer: OutputStreamWriter,
        id: Any,
        params: JSONObject?,
    ) {
        val path = params?.optString("path", "") ?: ""
        val rawContent = params?.optString("content", "") ?: ""
        val content = if (SessionVariableStore.enabled) {
            SessionVariableStore.shared.resolveText(rawContent)
        } else {
            rawContent
        }
        val rawDecision = CommandSafetyGuard.evaluateWritePath(path, active.defaultCwd)
        val writeDecision = if (rawDecision.allowed) {
            val targetForHook = try {
                val rf = File(path)
                if (rf.isAbsolute) rf.canonicalPath else File(active.defaultCwd, path).canonicalPath
            } catch (_: Throwable) {
                path
            }
            LifecycleHooksManager.evaluatePreToolUse("write_file", targetForHook)
        } else {
            rawDecision
        }
        if (!writeDecision.allowed) {
            log("Harness Safety Guard blocked file write: ${writeDecision.reason}")
            AcpConfigAndPromptHelper.sendJson(
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
            SessionVariableStore.shared.invalidateFilePath(
                runCatching { file.canonicalPath }.getOrDefault(file.absolutePath),
            )
            executor.submit {
                LifecycleHooksManager.runPostToolUse(
                    tool = "write_file",
                    filePath = file.absolutePath,
                    cwd = active.defaultCwd,
                    env = active.env,
                    log = log,
                )
            }
            AcpConfigAndPromptHelper.sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("result", JSONObject())
            )
        } catch (t: Throwable) {
            AcpConfigAndPromptHelper.sendJson(
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
}
