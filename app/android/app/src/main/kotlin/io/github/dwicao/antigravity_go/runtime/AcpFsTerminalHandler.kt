package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
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
            val rawText = file.readText()
            val content = if (startLine > 0 || limit > 0) {
                val lines = rawText.lines()
                val from = (startLine - 1).coerceIn(0, lines.size)
                val to = if (limit > 0) (from + limit).coerceAtMost(lines.size) else lines.size
                lines.subList(from, to).joinToString("\n")
            } else if (rawText.length > 24_000) {
                val lines = rawText.lines()
                if (lines.size > 320) {
                    val head = lines.take(220).joinToString("\n")
                    val tail = lines.takeLast(60).joinToString("\n")
                    val omitted = lines.size - 280
                    "$head\n\n... [TRUNCATED $omitted middle lines (${lines.size} lines / ${rawText.length} chars total) — re-call fs/read_text_file with line & limit to inspect specific sections] ...\n\n$tail"
                } else {
                    rawText.take(16_000) + "\n\n... [TRUNCATED ${rawText.length - 20_000} middle chars] ...\n\n" + rawText.takeLast(4_000)
                }
            } else {
                rawText
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
        val content = params?.optString("content", "") ?: ""
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
