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
    val authMarkerFile: File get() = File(homeDir, ".gemini/antigravity-go-auth.json")

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

    private fun writeAuthMarker(
        authenticated: Boolean,
        email: String? = null,
        method: String = "oauth-personal",
    ) {
        authMarkerFile.parentFile?.mkdirs()
        if (!authenticated) {
            authMarkerFile.delete()
            return
        }
        val existingEmail = if (email.isNullOrBlank() && authMarkerFile.exists()) {
            try {
                JSONObject(authMarkerFile.readText()).optString("email").takeIf { it.isNotBlank() }
            } catch (_: Throwable) {
                null
            }
        } else {
            email
        }
        val obj = JSONObject()
            .put("isAuthenticated", true)
            .put("method", method)
            .put("updatedAt", System.currentTimeMillis())
        if (!existingEmail.isNullOrBlank()) {
            obj.put("email", existingEmail)
        }
        authMarkerFile.writeText(obj.toString(2))
    }

    fun checkAuthStatus(): Map<String, Any?> {
        val geminiDir = File(homeDir, ".gemini")
        val configDir = File(homeDir, ".config")
        val localShareDir = File(homeDir, ".local/share")
        val emailRegex = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

        var foundEmail: String? = null
        var hasCreds = false

        // 1. Check our explicit auth marker (set when login succeeds or CLI verifies auth).
        if (authMarkerFile.exists()) {
            try {
                val marker = JSONObject(authMarkerFile.readText())
                if (marker.optBoolean("isAuthenticated", false)) {
                    hasCreds = true
                    foundEmail = marker.optString("email").takeIf { it.isNotBlank() }
                }
            } catch (_: Throwable) {}
        }

        // 2. Scan .gemini, .config, and .local/share for any agy credential/account/state files.
        val searchRoots = listOf(geminiDir, configDir, localShareDir)
        for (root in searchRoots) {
            if (!root.exists()) continue
            root.walkTopDown().maxDepth(3).forEach { f ->
                if (!f.isFile || f.length() <= 2 || f.length() > 512 * 1024) return@forEach
                val lower = f.name.lowercase()
                val looksLikeAuth = lower.contains("cred") ||
                    lower.contains("oauth") ||
                    lower.contains("token") ||
                    lower.contains("account") ||
                    lower.contains("auth") ||
                    lower == "antigravity_state.pbtxt"
                if (looksLikeAuth) {
                    hasCreds = true
                }
                if (foundEmail == null &&
                    (looksLikeAuth || lower == "settings.json" || lower == "config.json")
                ) {
                    try {
                        val text = f.readText()
                        val match = emailRegex.find(text)
                        if (match != null && !match.value.endsWith(".example.com")) {
                            foundEmail = match.value
                        }
                    } catch (_: Throwable) {}
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

    /**
     * Actively probes `agy models` to verify whether cached/keyring/file credentials
     * are valid, updating the auth marker accordingly.
     */
    fun verifyAuth(): Map<String, Any?> {
        val current = checkAuthStatus()
        if (!binaryFile.exists()) return current
        return try {
            val out = runCapture(listOf("models"), null, emptyMap(), 12)
            val lower = out.lowercase()
            val unauth = lower.contains("authentication required") ||
                lower.contains("not signed in") ||
                lower.contains("please sign in")
            val hasModelSlugs = lower.contains("gemini-") ||
                lower.contains("claude-") ||
                lower.contains("orchestrator")
            if (!unauth && hasModelSlugs) {
                val emailMatch = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}").find(out)
                writeAuthMarker(true, email = emailMatch?.value ?: (current["email"] as? String))
                checkAuthStatus()
            } else {
                current
            }
        } catch (_: Throwable) {
            current
        }
    }

    /**
     * Probes `agy` for live usage limits, credits, and model catalog.
     * Falls back to piping `/usage` + `/credits` + `/exit` interactively when `-p` doesn't emit quotas.
     */
    fun probeUsage(): String {
        if (!binaryFile.exists()) return ""
        val sb = StringBuilder()

        val modelsOut = try {
            runCapture(listOf("models"), null, emptyMap(), 12)
        } catch (_: Throwable) {
            ""
        }
        if (modelsOut.isNotBlank()) {
            sb.append(modelsOut).append("\n")
        }

        val printUsage = try {
            runCapture(listOf("-p", "/usage", "--output-format", "text"), null, emptyMap(), 18)
        } catch (_: Throwable) {
            ""
        }
        val printCredits = try {
            runCapture(listOf("-p", "/credits", "--output-format", "text"), null, emptyMap(), 15)
        } catch (_: Throwable) {
            ""
        }
        sb.append(printUsage).append("\n").append(printCredits).append("\n")

        val combinedSoFar = sb.toString().lowercase()
        val hasQuotaNumbers = combinedSoFar.contains("%") &&
            (combinedSoFar.contains("5-hour") || combinedSoFar.contains("5 hour") || combinedSoFar.contains("weekly") || combinedSoFar.contains("gemini"))

        if (!hasQuotaNumbers) {
            // Fallback: drive interactive `agy` via stdin `/usage` -> `/credits` -> `/exit`.
            val interactiveOut = runInteractiveProbe("/usage\n/credits\n/exit\n", 14)
            if (interactiveOut.isNotBlank()) {
                sb.append(interactiveOut).append("\n")
            }
        }
        return sb.toString().trim()
    }

    private fun runInteractiveProbe(stdinCommands: String, timeoutSeconds: Int): String {
        if (!binaryFile.exists()) return ""
        return try {
            val pb = ProcessBuilder(listOf(binaryFile.absolutePath))
            pb.directory(workspaceDir)
            pb.environment().putAll(
                buildEnv(
                    mapOf(
                        "COLUMNS" to "120",
                        "LINES" to "40",
                        "TERM" to "xterm-256color",
                    )
                )
            )
            pb.redirectErrorStream(true)
            val proc = pb.start()
            OutputStreamWriter(proc.outputStream).use { writer ->
                writer.write(stdinCommands)
                writer.flush()
            }
            val out = proc.inputStream.bufferedReader().use { it.readText() }
            proc.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
            if (proc.isAlive) proc.destroyForcibly()
            out
        } catch (_: Throwable) {
            ""
        }
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
                val emailRegex = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
                var capturedEmail: String? = null
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val l = line ?: continue
                    log("[auth] $l")
                    val url = urlRegex.find(l)?.value
                    if (url != null) {
                        emit(mapOf("kind" to "auth_oauth_url", "logLine" to url))
                    }
                    if (capturedEmail == null) {
                        val m = emailRegex.find(l)
                        if (m != null && !m.value.endsWith(".example.com")) {
                            capturedEmail = m.value
                        }
                    }
                }
                val code = proc.waitFor()
                if (code == 0) {
                    writeAuthMarker(
                        authenticated = true,
                        email = capturedEmail,
                        method = if (enterprise) "oauth-business" else "oauth-personal",
                    )
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
        writeAuthMarker(false)
        File(geminiDir, "oauth_creds.json").delete()
        File(geminiDir, "google_accounts.json").delete()
        File(geminiDir, "antigravity-cli/credentials.json").delete()
        File(geminiDir, "antigravity_state.pbtxt").delete()
        if (binaryFile.exists()) {
            try {
                runCapture(listOf("-p", "/logout", "--output-format", "text"), null, emptyMap(), 8)
            } catch (_: Throwable) {}
        }
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
                if (code == 0 && !authMarkerFile.exists()) {
                    writeAuthMarker(true)
                    emit(mapOf("kind" to "auth_completed"))
                }
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
