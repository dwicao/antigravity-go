package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

enum class RuntimePhase {
    uninstalled,
    installing,
    stopped,
    starting,
    running,
    error,
}

/**
 * Pure state machine & process manager for the on-device Antigravity CLI (`agy`).
 */
class RuntimeController private constructor(private val appContext: Context) {

    companion object {
        @Volatile
        private var instance: RuntimeController? = null

        fun get(context: Context): RuntimeController {
            return instance ?: synchronized(this) {
                instance ?: RuntimeController(context.applicationContext).also { instance = it }
            }
        }
    }

    private val executor = Executors.newCachedThreadPool()
    private val listeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()
    private val logs = CopyOnWriteArrayList<String>()
    private val activeTurns = ConcurrentHashMap<String, Process>()

    @Volatile
    private var loginProcess: Process? = null

    @Volatile
    private var loginWriter: OutputStreamWriter? = null

    @Volatile
    private var phase: RuntimePhase = RuntimePhase.uninstalled

    @Volatile
    private var installProgress: Double = 0.0

    @Volatile
    private var statusMessage: String = "Not installed"

    @Volatile
    private var errorMessage: String? = null

    @Volatile
    private var safeMode: Boolean = false

    val runtimeDir: File get() = File(appContext.filesDir, "runtime")
    val binaryFile: File get() = File(runtimeDir, "bin/agy")
    val homeDir: File get() = File(runtimeDir, "home")
    val workspaceDir: File get() = File(runtimeDir, "workspace")
    val settingsFile: File get() = File(homeDir, ".gemini/antigravity-cli/settings.json")

    init {
        runtimeDir.mkdirs()
        homeDir.mkdirs()
        workspaceDir.mkdirs()
        refreshInitialPhase()
    }

    private fun refreshInitialPhase() {
        if (binaryFile.exists() && binaryFile.canExecute()) {
            phase = RuntimePhase.stopped
            statusMessage = "Installed (ready to start)"
        } else {
            phase = RuntimePhase.uninstalled
            statusMessage = "Not installed"
        }
    }

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    private fun emit(payload: Map<String, Any?>) {
        for (l in listeners) {
            try {
                l(payload)
            } catch (_: Throwable) {}
        }
    }

    private fun log(msg: String) {
        logs.add(msg)
        while (logs.size > 250) {
            logs.removeAt(0)
        }
        emit(mapOf("kind" to "log", "logLine" to msg))
    }

    fun getLogs(): List<String> = logs.toList()

    fun statusMap(): Map<String, Any?> {
        val versionFile = File(runtimeDir, "version.txt")
        val version = if (versionFile.exists()) versionFile.readText().trim() else null
        return mapOf(
            "phase" to phase.name,
            "agyVersion" to version,
            "binaryPath" to if (binaryFile.exists()) binaryFile.absolutePath else null,
            "workspaceRoot" to workspaceDir.absolutePath,
            "installProgress" to installProgress,
            "statusMessage" to statusMessage,
            "errorMessage" to errorMessage,
            "safeMode" to safeMode,
        )
    }

    private fun emitStatus() {
        emit(mapOf("kind" to "status", "status" to statusMap()))
    }

    fun install(customManifestUrl: String? = null) {
        if (phase == RuntimePhase.installing) return
        phase = RuntimePhase.installing
        installProgress = 0.0
        errorMessage = null
        statusMessage = "Installing Antigravity CLI…"
        emitStatus()

        executor.submit {
            try {
                val res = RuntimeInstaller.install(
                    runtimeDir = runtimeDir,
                    abis = Build.SUPPORTED_ABIS,
                    customManifestUrl = customManifestUrl,
                ) { prog, msg ->
                    installProgress = prog
                    statusMessage = msg
                    log(msg)
                    emitStatus()
                }
                phase = RuntimePhase.stopped
                statusMessage = "Installed agy ${res.version}"
                emitStatus()
            } catch (t: Throwable) {
                phase = RuntimePhase.error
                errorMessage = t.message ?: t.toString()
                statusMessage = "Install failed"
                log("Install error: $errorMessage")
                emitStatus()
            }
        }
    }

    fun startService() {
        if (!binaryFile.exists()) {
            phase = RuntimePhase.uninstalled
            emitStatus()
            return
        }
        phase = RuntimePhase.starting
        statusMessage = "Starting Antigravity foreground harness…"
        emitStatus()

        val intent = Intent(appContext, AgyService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
        phase = RuntimePhase.running
        statusMessage = if (safeMode) "Running (Safe Mode)" else "Running on device"
        log(statusMessage)
        emitStatus()
    }

    fun stopService() {
        for ((_, proc) in activeTurns) {
            proc.destroyForcibly()
        }
        activeTurns.clear()
        appContext.stopService(Intent(appContext, AgyService::class.java))
        phase = if (binaryFile.exists()) RuntimePhase.stopped else RuntimePhase.uninstalled
        statusMessage = "Stopped"
        log("Runtime stopped")
        emitStatus()
    }

    fun resetRuntime() {
        stopService()
        File(runtimeDir, "bin").deleteRecursively()
        File(runtimeDir, "staging").deleteRecursively()
        File(runtimeDir, "version.txt").delete()
        phase = RuntimePhase.uninstalled
        installProgress = 0.0
        errorMessage = null
        statusMessage = "Runtime reset"
        log("Runtime reset")
        emitStatus()
    }

    fun setSafeMode(enabled: Boolean) {
        safeMode = enabled
        log("Safe mode ${if (enabled) "enabled" else "disabled"}")
        emitStatus()
    }

    private fun buildEnv(extra: Map<String, String> = emptyMap()): Map<String, String> {
        val env = HashMap<String, String>(System.getenv())
        env["HOME"] = homeDir.absolutePath
        env["XDG_CONFIG_HOME"] = File(homeDir, ".config").absolutePath
        env["XDG_CACHE_HOME"] = File(homeDir, ".cache").absolutePath
        val binPath = File(runtimeDir, "bin").absolutePath
        val oldPath = env["PATH"] ?: "/system/bin:/system/xbin"
        env["PATH"] = "$binPath:$oldPath"
        env.putAll(extra)
        return env
    }

    fun readSettings(): Map<String, Any?> {
        if (!settingsFile.exists()) return emptyMap()
        return try {
            val obj = JSONObject(settingsFile.readText())
            val map = mutableMapOf<String, Any?>()
            for (k in obj.keys()) {
                map[k] = obj.get(k)
            }
            map
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    fun writeSettings(patch: Map<String, Any?>) {
        settingsFile.parentFile?.mkdirs()
        val obj = if (settingsFile.exists()) {
            try {
                JSONObject(settingsFile.readText())
            } catch (_: Throwable) {
                JSONObject()
            }
        } else {
            JSONObject()
        }
        for ((k, v) in patch) {
            obj.put(k, JSONObject.wrap(v))
        }
        settingsFile.writeText(obj.toString(2))
    }

    fun checkAuthStatus(): Map<String, Any?> {
        val geminiDir = File(homeDir, ".gemini")
        val credsCandidates = listOf(
            File(geminiDir, "oauth_creds.json"),
            File(geminiDir, "antigravity-cli/credentials.json"),
            File(geminiDir, "google_accounts.json"),
        )
        var foundEmail: String? = null
        var hasCreds = false
        for (f in credsCandidates) {
            if (f.exists() && f.length() > 2) {
                hasCreds = true
                val text = f.readText()
                val match = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}").find(text)
                if (match != null && foundEmail == null) {
                    foundEmail = match.value
                }
            }
        }
        val settings = readSettings()
        val gcp = settings["gcp"] as? JSONObject
        return mapOf(
            "isAuthenticated" to hasCreds,
            "email" to foundEmail,
            "method" to if (gcp != null) "oauth-business" else "oauth-personal",
            "gcpProject" to gcp?.optString("project"),
            "gcpLocation" to gcp?.optString("location"),
        )
    }

    fun startGoogleLogin(enterprise: Boolean) {
        if (!binaryFile.exists()) {
            emit(mapOf("kind" to "auth_error", "logLine" to "agy binary is not installed"))
            return
        }
        executor.submit {
            try {
                loginProcess?.destroyForcibly()
                val cmd = mutableListOf(binaryFile.absolutePath, "acp", "--login")
                if (enterprise) {
                    log("Starting Gemini Enterprise login…")
                } else {
                    log("Starting Google Account login via `agy acp --login`…")
                }
                val pb = ProcessBuilder(cmd)
                pb.directory(workspaceDir)
                pb.environment().putAll(buildEnv())
                pb.redirectErrorStream(true)
                val proc = pb.start()
                loginProcess = proc
                loginWriter = OutputStreamWriter(proc.outputStream)

                val reader = BufferedReader(InputStreamReader(proc.inputStream))
                val urlRegex = Regex("https://accounts\\.google\\.com/[^\\s\\)\\]>\"']+")
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val l = line ?: continue
                    log("[auth] $l")
                    val url = urlRegex.find(l)?.value
                    if (url != null) {
                        emit(mapOf("kind" to "auth_oauth_url", "logLine" to url))
                    }
                }
                val code = proc.waitFor()
                if (code == 0) {
                    emit(mapOf("kind" to "auth_completed"))
                } else {
                    emit(mapOf("kind" to "auth_error", "logLine" to "Login exited with code $code"))
                }
            } catch (t: Throwable) {
                emit(mapOf("kind" to "auth_error", "logLine" to (t.message ?: t.toString())))
            } finally {
                loginProcess = null
                loginWriter = null
            }
        }
    }

    fun submitLoginCode(code: String) {
        executor.submit {
            try {
                loginWriter?.apply {
                    write(code)
                    write("\n")
                    flush()
                }
            } catch (t: Throwable) {
                log("Failed writing auth code: ${t.message}")
            }
        }
    }

    fun logout() {
        val geminiDir = File(homeDir, ".gemini")
        File(geminiDir, "oauth_creds.json").delete()
        File(geminiDir, "google_accounts.json").delete()
        File(geminiDir, "antigravity-cli/credentials.json").delete()
        log("Cleared cached Google credentials")
    }

    fun runCapture(
        args: List<String>,
        cwd: String?,
        extraEnv: Map<String, String>,
        timeoutSeconds: Int,
    ): String {
        if (!binaryFile.exists()) return ""
        val cmd = listOf(binaryFile.absolutePath) + args
        val pb = ProcessBuilder(cmd)
        pb.directory(if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir)
        pb.environment().putAll(buildEnv(extraEnv))
        pb.redirectErrorStream(true)
        val proc = pb.start()
        val out = proc.inputStream.bufferedReader().use { it.readText() }
        proc.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
        if (proc.isAlive) proc.destroyForcibly()
        return out
    }

    fun runShell(command: String, cwd: String?): String {
        val pb = ProcessBuilder("/system/bin/sh", "-c", command)
        pb.directory(if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir)
        pb.environment().putAll(buildEnv())
        pb.redirectErrorStream(true)
        val proc = pb.start()
        val out = proc.inputStream.bufferedReader().use { it.readText() }
        proc.waitFor(30, TimeUnit.SECONDS)
        if (proc.isAlive) proc.destroyForcibly()
        return out
    }

    fun startTurn(
        turnId: String,
        prompt: String,
        cwd: String?,
        conversationId: String?,
        model: String?,
        effort: String?,
        mode: String?,
        skipPermissions: Boolean,
        geminiApiKey: String?,
    ) {
        if (!binaryFile.exists()) {
            emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to 127))
            return
        }
        executor.submit {
            try {
                val cmd = mutableListOf(
                    binaryFile.absolutePath,
                    "-p",
                    prompt,
                    "--output-format",
                    "stream-json",
                )
                if (!mode.isNullOrBlank()) {
                    cmd.addAll(listOf("--mode", mode))
                }
                if (!model.isNullOrBlank()) {
                    cmd.addAll(listOf("--model", model))
                }
                if (!effort.isNullOrBlank() &&
                    !(model?.lowercase()?.contains("orchestrator") == true)
                ) {
                    cmd.addAll(listOf("--effort", effort))
                }
                if (!conversationId.isNullOrBlank()) {
                    cmd.addAll(listOf("--conversation", conversationId))
                }
                if (skipPermissions) {
                    cmd.add("--dangerously-skip-permissions")
                }

                val extraEnv = mutableMapOf<String, String>()
                if (!geminiApiKey.isNullOrBlank()) {
                    extraEnv["GEMINI_API_KEY"] = geminiApiKey
                }

                val pb = ProcessBuilder(cmd)
                pb.directory(if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir)
                pb.environment().putAll(buildEnv(extraEnv))
                val proc = pb.start()
                activeTurns[turnId] = proc

                val errFuture = executor.submit {
                    BufferedReader(InputStreamReader(proc.errorStream)).use { errReader ->
                        var errLine: String?
                        while (errReader.readLine().also { errLine = it } != null) {
                            emit(
                                mapOf(
                                    "kind" to "turn_stderr",
                                    "turnId" to turnId,
                                    "stderrLine" to (errLine ?: ""),
                                )
                            )
                        }
                    }
                }

                BufferedReader(InputStreamReader(proc.inputStream)).use { outReader ->
                    var outLine: String?
                    while (outReader.readLine().also { outLine = it } != null) {
                        emit(
                            mapOf(
                                "kind" to "turn_stdout",
                                "turnId" to turnId,
                                "stdoutLine" to (outLine ?: ""),
                            )
                        )
                    }
                }

                errFuture.get(5, TimeUnit.SECONDS)
                val code = proc.waitFor()
                emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to code))
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
                activeTurns.remove(turnId)
            }
        }
    }

    fun cancelTurn(turnId: String) {
        activeTurns.remove(turnId)?.destroyForcibly()
    }

    fun listWorkspace(path: String?): List<Map<String, String>> {
        val target = if (path.isNullOrBlank()) workspaceDir else File(path)
        if (!target.exists() || !target.isDirectory) return emptyList()
        val files = target.listFiles() ?: return emptyList()
        return files
            .sortedWith(compareBy<File>({ !it.isDirectory }, { it.name.lowercase() }))
            .map { f ->
                mapOf(
                    "name" to f.name,
                    "path" to f.absolutePath,
                    "type" to if (f.isDirectory) "dir" else "file",
                    "size" to if (f.isDirectory) "folder" else "${f.length()} B",
                )
            }
    }

    fun readFile(path: String): String {
        val f = File(path)
        if (!f.exists() || !f.isFile) return ""
        return f.readText()
    }
}
