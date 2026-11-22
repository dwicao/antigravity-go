package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.system.Os
import org.json.JSONArray
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
    private val runTail = ArrayDeque<String>()
    private val activeTurns = ConcurrentHashMap<String, Process>()
    private val acpManager = AcpSessionManager(
        executor = executor,
        emit = { payload -> handleAcpOrProcessEvent(payload) },
        log = { msg -> log(msg) },
    )

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

    @Volatile
    private var safeState: SafeState = SafeState.OFF

    @Volatile
    private var consecutiveStrikes: Int = 0

    @Volatile
    private var lastFailure: RunFailure? = null

    @Volatile
    private var networkBlocked: Boolean = false

    private val turnStartedAt = ConcurrentHashMap<String, Long>()
    private val turnReceivedOutput = ConcurrentHashMap<String, Boolean>()

    val runtimeDir: File get() = File(appContext.filesDir, "runtime")
    val binDir: File get() = File(runtimeDir, "bin")
    val tmpDir: File get() = File(runtimeDir, "tmp")
    val binaryFile: File get() = File(runtimeDir, "bin/agy")
    val bashFile: File get() = File(binDir, "bash")
    val homeDir: File get() = File(runtimeDir, "home")
    val workspaceDir: File get() = File(runtimeDir, "workspace")
    val settingsFile: File get() = File(homeDir, ".gemini/antigravity-cli/settings.json")
    val authMarkerFile: File get() = File(homeDir, ".gemini/antigravity-go-auth.json")

    private val busyboxApplets = listOf(
        "sh", "ls", "cat", "find", "grep", "egrep", "fgrep", "sed", "awk",
        "head", "tail", "wc", "sort", "uniq", "cut", "tr", "xargs",
        "mkdir", "rmdir", "rm", "cp", "mv", "touch", "chmod", "ln",
        "stat", "realpath", "readlink", "dirname", "basename", "which",
        "tar", "gzip", "gunzip", "unzip", "ps", "kill", "du", "df",
        "id", "whoami", "uname", "date", "sleep", "env", "pwd",
        "echo", "printf", "test", "[", "tee", "diff", "patch", "wget",
    )

    init {
        runtimeDir.mkdirs()
        binDir.mkdirs()
        tmpDir.mkdirs()
        homeDir.mkdirs()
        workspaceDir.mkdirs()
        ensureShellToolchain()
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
        val clean = LogRedactor.redact(msg)
        logs.add(clean)
        while (logs.size > 250) {
            logs.removeAt(0)
        }
        synchronized(runTail) {
            runTail.addLast(clean)
            while (runTail.size > CrashClassifier.TAIL_LINES) {
                runTail.removeFirst()
            }
        }
        emit(mapOf("kind" to "log", "logLine" to clean))
    }

    fun noteNetworkChange(note: String) {
        networkBlocked = false
        log(note)
    }

    fun noteNetworkBlocked(blocked: Boolean) {
        networkBlocked = blocked
        log(if (blocked) "Android network policy blocked background access" else "Network access restored")
    }

    private fun handleAcpOrProcessEvent(payload: Map<String, Any?>) {
        val kind = payload["kind"] as? String
        val turnId = payload["turnId"] as? String
        when (kind) {
            "turn_acp_line", "turn_stdout" -> {
                if (turnId != null) {
                    val line = (payload["stdoutLine"] as? String).orEmpty()
                    if (line.contains("agent_message_chunk") || line.contains("agent_thought_chunk") || line.contains("\"response\"")) {
                        turnReceivedOutput[turnId] = true
                    }
                    if (line.contains("tool_call") && AgyService.running) {
                        AgyService.updateTurnStatus(appContext, "Agent running tool step…")
                    }
                }
            }
            "turn_stderr" -> {
                val err = LogRedactor.redact((payload["stderrLine"] as? String).orEmpty())
                if (err.isNotBlank()) {
                    synchronized(runTail) {
                        runTail.addLast(err)
                        while (runTail.size > CrashClassifier.TAIL_LINES) runTail.removeFirst()
                    }
                }
            }
            "turn_exit" -> {
                val exitCode = (payload["exitCode"] as? Number)?.toInt() ?: 0
                if (turnId != null) {
                    onTurnFinished(turnId, exitCode)
                }
            }
        }
        emit(payload)
    }

    private fun onTurnFinished(turnId: String, exitCode: Int) {
        val started = turnStartedAt.remove(turnId)
        val upMs = started?.let { System.currentTimeMillis() - it }
        val receivedOut = turnReceivedOutput.remove(turnId) ?: false
        if (AgyService.running) {
            AgyService.updateTurnStatus(appContext, "On-device Antigravity CLI harness active")
        }
        if (exitCode == 0) {
            if (safeState == SafeState.PROBATION && (upMs == null || upMs >= SafePolicy.HEALTHY_MS || receivedOut)) {
                safeState = SafeState.OFF
            }
            consecutiveStrikes = 0
            return
        }
        val tailSnapshot = synchronized(runTail) { runTail.toList() }
        val failure = CrashClassifier.classify(
            exitCode = exitCode,
            upMillis = upMs,
            tailLines = tailSnapshot,
            safeMode = safeMode,
            receivedAgentOutput = receivedOut,
        ) ?: return
        lastFailure = failure
        log("[classifier] ${failure.kind.wire}: ${failure.summary} | hint: ${failure.hint}")
        emit(
            mapOf(
                "kind" to "turn_stderr",
                "turnId" to turnId,
                "stderrLine" to "${failure.summary}\nHint: ${failure.hint}",
            )
        )
        val outcome = SafePolicy.onFailure(
            state = safeState,
            strikes = consecutiveStrikes,
            failure = failure,
        )
        safeState = outcome.state
        consecutiveStrikes = outcome.strikes
        if (outcome.engagedSafeMode && !safeMode) {
            safeMode = true
            statusMessage = "Safe Mode engaged automatically"
            outcome.notice?.let(::log)
            emitStatus()
        }
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
        safeState = SafePolicy.onManualModeChange(safeState, enabled)
        if (!enabled) consecutiveStrikes = 0
        log("Safe mode ${if (enabled) "enabled" else "disabled"} (state=${safeState.wire})")
        emitStatus()
    }

    private fun atomicWriteText(target: File, content: String) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, ".${target.name}.agy-tmp")
        try {
            tmp.writeText(content)
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    /**
     * Links bundled native static `libbash.so` & `libbusybox.so` into `runtime/bin/`
     * (refreshing symlink targets whenever an APK upgrade relocates `nativeLibraryDir`)
     * so `agy` tools always find `bash`, `sh`, `ls`, `find`, `grep`, `sed`, `awk`, etc.
     */
    fun ensureShellToolchain() {
        try {
            binDir.mkdirs()
            tmpDir.mkdirs()
            val nativeLibDir = appContext.applicationInfo?.nativeLibraryDir
            val bundledBash = nativeLibDir?.let { File(it, "libbash.so") }?.takeIf { it.isFile }
            val bundledBusybox = nativeLibDir?.let { File(it, "libbusybox.so") }?.takeIf { it.isFile }

            if (bundledBash != null) {
                ensureSymlink(bashFile, bundledBash.absolutePath)
            } else {
                // Fallback executable wrapper when native JNI binaries are omitted (e.g. dev debug).
                if (!bashFile.exists() || !bashFile.canExecute()) {
                    bashFile.writeText("#!/system/bin/sh\nexec /system/bin/sh \"\$@\"\n")
                    bashFile.setExecutable(true, false)
                }
            }

            if (bundledBusybox != null) {
                ensureSymlink(File(binDir, "busybox"), bundledBusybox.absolutePath)
                for (applet in busyboxApplets) {
                    if (applet == "agy" || applet == "bash") continue
                    ensureSymlink(File(binDir, applet), bundledBusybox.absolutePath)
                }
            }

            // DSH-go style storage shortcuts inside HOME & default workspace.
            if (hasStorageAccess()) {
                val extRoot = Environment.getExternalStorageDirectory()?.absolutePath
                    ?: "/storage/emulated/0"
                if (File(extRoot).canRead()) {
                    ensureSymlink(File(homeDir, "sdcard"), extRoot)
                    ensureSymlink(File(workspaceDir, "phone_storage"), extRoot)
                }
            }
        } catch (_: Throwable) {
        }
    }

    private fun ensureSymlink(linkFile: File, targetPath: String) {
        try {
            val currentTarget = try {
                Os.readlink(linkFile.absolutePath)
            } catch (_: Throwable) {
                null
            }
            if (currentTarget == targetPath) return
            if (linkFile.exists() || currentTarget != null) {
                linkFile.delete()
            }
            Os.symlink(targetPath, linkFile.absolutePath)
        } catch (_: Throwable) {
            try {
                val src = File(targetPath)
                if (src.isFile && (!linkFile.exists() || linkFile.length() != src.length())) {
                    src.copyTo(linkFile, overwrite = true)
                    linkFile.setExecutable(true, false)
                }
            } catch (_: Throwable) {}
        }
    }

    /**
     * DSH-go style managed `$HOME/.gemini/GEMINI.md`: informs `agy` about the Android
     * runtime (`bash` + BusyBox tools, no OS terminal sandbox, and `/sdcard` storage paths)
     * unless the user removes the managed marker comment.
     */
    private fun syncManagedGeminiMd(allowStorage: Boolean) {
        try {
            val geminiMd = File(homeDir, ".gemini/GEMINI.md")
            val marker = "<!-- antigravity-go:managed"
            if (geminiMd.exists()) {
                val existing = geminiMd.readText()
                if (!existing.startsWith(marker)) return
            }
            geminiMd.parentFile?.mkdirs()
            val storageSection = if (allowStorage) {
                val extRoot = Environment.getExternalStorageDirectory()?.absolutePath
                    ?: "/storage/emulated/0"
                "- Phone Storage (All Files Access GRANTED): Internal storage is directly accessible at `/sdcard`, `$extRoot`, and `~/sdcard` (Downloads: `/sdcard/Download`, Photos: `/sdcard/DCIM`). Explain changes before editing or deleting personal user files."
            } else {
                "- Phone Storage: All Files Access is not currently granted. Only workspace files (`${workspaceDir.absolutePath}`) are writable; if the user asks for `/sdcard` or Downloads, remind them to enable All Files Access in Settings."
            }
            val managedContent = """
                |$marker — Remove this line to stop Antigravity Go from auto-updating runtime context -->
                |# Antigravity Go — Android Runtime Context
                |
                |- You are running natively on Android (no root required). There is **no OS terminal sandbox** (bubblewrap/landlock); never select or require `auto` sandbox mode.
                |- Shell commands run via bundled `bash` and BusyBox POSIX tools (`ls`, `find`, `grep`, `sed`, `awk`, `cat`, `head`, `tail`, `wc`, `tar`, `gzip`, `unzip`, etc.) preloaded in `${'$'}PATH` (`SHELL=${bashFile.absolutePath}`, `TMPDIR=${tmpDir.absolutePath}`).
                |- Default workspace: `${workspaceDir.absolutePath}`.
                |$storageSection
                |- Keep replies well-structured for mobile and Samsung DeX screens.
                |""".trimMargin()
            if (!geminiMd.exists() || geminiMd.readText() != managedContent) {
                geminiMd.writeText(managedContent)
            }
        } catch (_: Throwable) {}
    }

    private fun buildEnv(extra: Map<String, String> = emptyMap()): Map<String, String> {
        ensureShellToolchain()
        val env = HashMap<String, String>(System.getenv())
        env["HOME"] = homeDir.absolutePath
        env["XDG_CONFIG_HOME"] = File(homeDir, ".config").absolutePath
        env["XDG_CACHE_HOME"] = File(homeDir, ".cache").absolutePath
        env["TMPDIR"] = tmpDir.absolutePath
        env["TMP"] = tmpDir.absolutePath
        env["TEMP"] = tmpDir.absolutePath
        env["SHELL"] = bashFile.absolutePath
        env["CONFIG_SHELL"] = bashFile.absolutePath
        env["ANDROID_STORAGE"] = "/sdcard"
        val binPath = binDir.absolutePath
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
        atomicWriteText(settingsFile, obj.toString(2))
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
        val env = buildEnv()
        val shell = if (bashFile.canExecute()) bashFile.absolutePath else "/system/bin/sh"
        val pb = ProcessBuilder(shell, "-c", command)
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (!dir.exists()) dir.mkdirs()
        pb.directory(dir)
        pb.environment().putAll(env)
        pb.redirectErrorStream(true)
        val proc = pb.start()
        val out = proc.inputStream.bufferedReader().use { it.readText() }
        proc.waitFor(30, TimeUnit.SECONDS)
        if (proc.isAlive) proc.destroyForcibly()
        return out
    }

    fun diagnoseRuntime(): Map<String, Any?> {
        val env = buildEnv()
        val bashWorks = try {
            runShell("which bash ls find grep sed awk | head -n 6", null).trim()
        } catch (t: Throwable) {
            "error: ${t.message}"
        }
        val storageProbe = if (hasStorageAccess()) {
            try {
                runShell("ls -la /sdcard/Download 2>&1 | head -n 10", null).trim()
            } catch (t: Throwable) {
                "error: ${t.message}"
            }
        } else {
            "All Files Access not granted"
        }
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val batteryExempt = pm?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
        return mapOf(
            "agyExists" to (binaryFile.exists() && binaryFile.canExecute()),
            "bashPath" to bashFile.absolutePath,
            "bashExecutable" to bashFile.canExecute(),
            "busyboxExecutable" to File(binDir, "busybox").canExecute(),
            "allFilesAccess" to hasStorageAccess(),
            "batteryOptimizationExempt" to batteryExempt,
            "safeState" to safeState.wire,
            "networkBlocked" to networkBlocked,
            "lastFailure" to lastFailure?.toMap(),
            "tmpDir" to env["TMPDIR"],
            "shellProbe" to bashWorks,
            "downloadProbe" to storageProbe,
        )
    }

    private fun hasStorageAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    private fun defaultExtraDirs(requested: List<String>): List<String> {
        val out = LinkedHashSet<String>()
        for (d in requested) {
            if (d.isNotBlank()) out.add(d)
        }
        if (hasStorageAccess()) {
            val ext = Environment.getExternalStorageDirectory()?.absolutePath ?: "/storage/emulated/0"
            out.add(ext)
            out.add("/sdcard")
        }
        return out.toList()
    }

    fun startTurn(
        turnId: String,
        prompt: String,
        cwd: String?,
        extraDirs: List<String>,
        conversationId: String?,
        model: String?,
        effort: String?,
        mode: String?,
        skipPermissions: Boolean,
        allowNonWorkspaceAccess: Boolean,
        useAcp: Boolean,
        geminiApiKey: String?,
    ) {
        if (!binaryFile.exists()) {
            emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to 127))
            return
        }

        turnStartedAt[turnId] = System.currentTimeMillis()
        turnReceivedOutput[turnId] = false
        synchronized(runTail) { runTail.clear() }
        if (AgyService.running) {
            AgyService.updateTurnStatus(appContext, "Agent thinking…")
        }

        val storageEnabled = allowNonWorkspaceAccess || hasStorageAccess()
        // In Safe Mode, skip regenerating custom GEMINI.md overrides to match DSH-go safe recovery.
        if (!safeMode) {
            syncManagedGeminiMd(allowStorage = storageEnabled)
        }

        // Sync non-workspace & permission settings before running agy.
        // Never allow `auto` sandbox mode to persist in settings.json on Android.
        try {
            val currentSettings = readSettings()
            val patch = mutableMapOf<String, Any?>(
                "allowNonWorkspaceAccess" to storageEnabled,
            )
            if (skipPermissions) {
                patch["toolPermission"] = "always-proceed"
                patch["permissions"] = mapOf(
                    "allow" to listOf("command(*)", "read_file(*)", "write_file(*)"),
                )
            } else if (currentSettings["toolPermission"] == "auto") {
                patch["toolPermission"] = "default"
            }
            writeSettings(patch)
        } catch (_: Throwable) {}

        val effectiveCwd = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (!effectiveCwd.exists()) {
            try {
                effectiveCwd.mkdirs()
            } catch (_: Throwable) {}
        }
        val mergedDirs = defaultExtraDirs(extraDirs)
        val safeCliMode = when (mode?.lowercase()?.trim()) {
            null, "", "auto" -> if (skipPermissions) null else "default"
            else -> mode
        }
        val extraEnv = mutableMapOf<String, String>()
        if (!geminiApiKey.isNullOrBlank()) {
            extraEnv["GEMINI_API_KEY"] = geminiApiKey
        }

        if (useAcp) {
            acpManager.startTurn(
                turnId = turnId,
                binaryPath = binaryFile.absolutePath,
                cwd = effectiveCwd,
                env = buildEnv(extraEnv),
                prompt = prompt,
                extraDirs = mergedDirs,
                existingSessionId = conversationId,
                modelId = model,
                modeCli = safeCliMode,
                skipPermissions = skipPermissions,
                onAuthenticated = {
                    if (!authMarkerFile.exists()) {
                        writeAuthMarker(true)
                        emit(mapOf("kind" to "auth_completed"))
                    }
                },
            )
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
                for (dir in mergedDirs) {
                    if (File(dir).exists()) {
                        cmd.addAll(listOf("--add-dir", dir))
                    }
                }
                if (!safeCliMode.isNullOrBlank()) {
                    cmd.addAll(listOf("--mode", safeCliMode))
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

                val pb = ProcessBuilder(cmd)
                pb.directory(effectiveCwd)
                pb.environment().putAll(buildEnv(extraEnv))
                val proc = pb.start()
                activeTurns[turnId] = proc

                val errFuture = executor.submit {
                    val redactor = LogRedactor()
                    BufferedReader(InputStreamReader(proc.errorStream)).use { errReader ->
                        var errLine: String?
                        while (errReader.readLine().also { errLine = it } != null) {
                            handleAcpOrProcessEvent(
                                mapOf(
                                    "kind" to "turn_stderr",
                                    "turnId" to turnId,
                                    "stderrLine" to redactor.line(errLine ?: ""),
                                )
                            )
                        }
                    }
                }

                BufferedReader(InputStreamReader(proc.inputStream)).use { outReader ->
                    var outLine: String?
                    while (outReader.readLine().also { outLine = it } != null) {
                        handleAcpOrProcessEvent(
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
                handleAcpOrProcessEvent(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to code))
            } catch (t: Throwable) {
                handleAcpOrProcessEvent(
                    mapOf(
                        "kind" to "turn_stderr",
                        "turnId" to turnId,
                        "stderrLine" to (t.message ?: t.toString()),
                    )
                )
                handleAcpOrProcessEvent(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to 1))
            } finally {
                activeTurns.remove(turnId)
            }
        }
    }

    fun respondPermission(turnId: String, requestId: Any, optionId: String) {
        acpManager.respondToPermission(turnId, requestId, optionId)
    }

    fun cancelTurn(turnId: String) {
        acpManager.cancel(turnId)
        activeTurns.remove(turnId)?.destroyForcibly()
    }

    fun writeTextFile(path: String, content: String): Boolean {
        return try {
            val f = File(path)
            f.parentFile?.mkdirs()
            f.writeText(content)
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun listCustomizations(cwd: String?): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        val projectDir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir

        // Rules: global ~/.gemini/GEMINI.md and project .agents/rules/*.md
        val globalGeminiMd = File(homeDir, ".gemini/GEMINI.md")
        items.add(
            mapOf(
                "kind" to "rule",
                "name" to "Global Rules (GEMINI.md)",
                "scope" to "Global",
                "path" to globalGeminiMd.absolutePath,
                "description" to "Global instructions applied to every conversation",
                "enabled" to globalGeminiMd.exists(),
                "content" to if (globalGeminiMd.exists()) globalGeminiMd.readText() else "",
            )
        )
        val projectRulesDir = File(projectDir, ".agents/rules")
        if (projectRulesDir.exists() && projectRulesDir.isDirectory) {
            projectRulesDir.listFiles()?.filter { it.isFile }?.forEach { f ->
                items.add(
                    mapOf(
                        "kind" to "rule",
                        "name" to f.name,
                        "scope" to "Project",
                        "path" to f.absolutePath,
                        "description" to "Workspace rule",
                        "enabled" to true,
                        "content" to f.readText(),
                    )
                )
            }
        }

        // Skills: ~/.gemini/skills/* & <project>/.agents/skills/*
        for ((scope, root) in listOf(
            "Global" to File(homeDir, ".gemini/skills"),
            "Project" to File(projectDir, ".agents/skills"),
        )) {
            if (root.exists() && root.isDirectory) {
                root.listFiles()?.filter { it.isDirectory }?.forEach { dir ->
                    val skillMd = File(dir, "SKILL.md")
                    items.add(
                        mapOf(
                            "kind" to "skill",
                            "name" to dir.name,
                            "scope" to scope,
                            "path" to skillMd.absolutePath,
                            "description" to if (skillMd.exists()) "SKILL.md loaded" else "Skill folder",
                            "enabled" to skillMd.exists(),
                            "content" to if (skillMd.exists()) skillMd.readText() else "",
                        )
                    )
                }
            }
        }

        // MCP Servers & Hooks from settings.json
        val settings = readSettings()
        val mcp = settings["mcpServers"] as? JSONObject
        if (mcp != null) {
            for (key in mcp.keys()) {
                val cfg = mcp.optJSONObject(key)
                items.add(
                    mapOf(
                        "kind" to "mcpServer",
                        "name" to key,
                        "scope" to "Global",
                        "path" to (cfg?.optString("command") ?: cfg?.optString("url") ?: "configured"),
                        "description" to "Model Context Protocol server",
                        "enabled" to true,
                    )
                )
            }
        }
        return items
    }

    fun gitDiff(cwd: String?): Map<String, String> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val status = runShell("git status --short 2>&1 || true", dir.absolutePath)
        val diff = runShell("git diff 2>&1 || true", dir.absolutePath)
        return mapOf(
            "status" to status,
            "diff" to diff,
        )
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
