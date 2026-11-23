package io.github.dwicao.antigravity_go.runtime

import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService

/**
 * Manages interactive user terminal sessions, using the bundled static `pty-host` (`libpty.so`)
 * for kernel PTY + `TIOCSWINSZ` resize support when available and falling back gracefully to
 * pipe-backed `bash -i`.
 */
internal class TerminalSessionManager(
    private val executor: ExecutorService,
    private val workspaceDir: File,
    private val tmpDir: File,
    private val bashFile: File,
    private val ptyHostFile: File,
    private val buildEnv: (Map<String, String>) -> Map<String, String>,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val sessions = ConcurrentHashMap<String, Process>()
    private val writers = ConcurrentHashMap<String, OutputStreamWriter>()
    private val ctrlFifos = ConcurrentHashMap<String, File>()
    private val isPtyMode = ConcurrentHashMap<String, Boolean>()

    fun startSession(
        sessionId: String,
        cwd: String?,
        cols: Int = 80,
        rows: Int = 24,
    ) {
        closeSession(sessionId)
        executor.submit {
            val safeCols = cols.coerceIn(20, 400)
            val safeRows = rows.coerceIn(8, 200)
            val usePty = ptyHostFile.exists() && ptyHostFile.canExecute()
            val ctrlFifo = if (usePty) File(tmpDir, "pty_${sessionId.replace(Regex("[^A-Za-z0-9_-]"), "_")}.winsz") else null
            try {
                ctrlFifo?.let { runCatching { if (it.exists()) it.delete() } }
                val env = buildEnv(
                    mapOf(
                        "TERM" to "xterm-256color",
                        "PS1" to "\\w \\$ ",
                        "COLUMNS" to safeCols.toString(),
                        "LINES" to safeRows.toString(),
                    )
                )
                val shell = if (bashFile.canExecute()) bashFile.absolutePath else "/system/bin/sh"
                val cmd = if (usePty && ctrlFifo != null) {
                    listOf(
                        ptyHostFile.absolutePath,
                        safeCols.toString(),
                        safeRows.toString(),
                        ctrlFifo.absolutePath,
                        shell,
                        "-i",
                    )
                } else {
                    listOf(shell, "-i")
                }

                val pb = ProcessBuilder(cmd)
                val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
                if (!dir.exists()) dir.mkdirs()
                pb.directory(dir)
                pb.environment().putAll(env)
                pb.redirectErrorStream(true)
                val proc = pb.start()
                sessions[sessionId] = proc
                writers[sessionId] = OutputStreamWriter(proc.outputStream, Charsets.UTF_8)
                isPtyMode[sessionId] = usePty
                if (ctrlFifo != null) {
                    ctrlFifos[sessionId] = ctrlFifo
                }

                val reader = BufferedReader(InputStreamReader(proc.inputStream, Charsets.UTF_8))
                val buf = CharArray(2048)
                var n: Int
                while (reader.read(buf).also { n = it } >= 0) {
                    if (n > 0) {
                        emit(
                            mapOf(
                                "kind" to "terminal_output",
                                "sessionId" to sessionId,
                                "stdoutLine" to String(buf, 0, n),
                                "isPty" to usePty,
                            )
                        )
                    }
                }
                val code = runCatching { proc.waitFor() }.getOrDefault(0)
                emit(
                    mapOf(
                        "kind" to "terminal_exit",
                        "sessionId" to sessionId,
                        "exitCode" to code,
                    )
                )
            } catch (t: Throwable) {
                emit(
                    mapOf(
                        "kind" to "terminal_output",
                        "sessionId" to sessionId,
                        "stdoutLine" to "\r\n[terminal error: ${t.message}]\r\n",
                        "isPty" to false,
                    )
                )
                emit(
                    mapOf(
                        "kind" to "terminal_exit",
                        "sessionId" to sessionId,
                        "exitCode" to 1,
                    )
                )
            } finally {
                sessions.remove(sessionId)
                writers.remove(sessionId)?.let { runCatching { it.close() } }
                isPtyMode.remove(sessionId)
                ctrlFifos.remove(sessionId)?.let { runCatching { it.delete() } }
            }
        }
    }

    fun writeInput(sessionId: String, input: String): Boolean {
        val writer = writers[sessionId] ?: return false
        return try {
            synchronized(writer) {
                writer.write(input)
                writer.flush()
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun resizeSession(sessionId: String, cols: Int, rows: Int): Boolean {
        val fifo = ctrlFifos[sessionId] ?: return false
        if (!fifo.exists()) return false
        val safeCols = cols.coerceIn(20, 400)
        val safeRows = rows.coerceIn(8, 200)
        return try {
            FileOutputStream(fifo, true).use { fos ->
                fos.write("$safeCols $safeRows\n".toByteArray(Charsets.US_ASCII))
                fos.flush()
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun closeSession(sessionId: String) {
        writers.remove(sessionId)?.let { runCatching { it.close() } }
        sessions.remove(sessionId)?.let { runCatching { it.destroyForcibly() } }
        isPtyMode.remove(sessionId)
        ctrlFifos.remove(sessionId)?.let { runCatching { it.delete() } }
    }

    fun closeAll() {
        for (sid in sessions.keys.toList()) {
            closeSession(sid)
        }
    }
}
