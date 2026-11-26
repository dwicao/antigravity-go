package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.system.Os
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
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
 * Process manager & state coordinator for the on-device Antigravity CLI (`agy`).
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
    private val logs = ArrayDeque<String>()
    private val runTail = ArrayDeque<String>()
    private val activeTurns = ConcurrentHashMap<String, Process>()
    private val cancelledTurns = ConcurrentHashMap.newKeySet<String>()
    private val nonAcpTurnMeta = ConcurrentHashMap<String, Pair<String, Long>>()
    private val toolchainLock = Any()

    @Volatile
    private var busyboxHealthy: Boolean = false

    @Volatile
    private var bashHealthy: Boolean = false

    @Volatile
    private var toolchainInitialized: Boolean = false

    @Volatile
    private var lastToolchainStorageAccess: Boolean? = null

    val runtimeDir: File get() = File(appContext.filesDir, "runtime")
    val binDir: File get() = File(runtimeDir, "bin")
    val tmpDir: File get() = File(runtimeDir, "tmp")
    val binaryFile: File get() = File(runtimeDir, "bin/agy")
    val bashFile: File get() = File(binDir, "bash")
    val ptyHostFile: File get() = File(binDir, "pty-host")
    val homeDir: File get() = File(runtimeDir, "home")
    val accountsDir: File get() = File(runtimeDir, "accounts")
    val workspaceDir: File get() = File(runtimeDir, "workspace")
    val settingsFile: File get() = File(homeDir, ".gemini/antigravity-cli/settings.json")
    val authMarkerFile: File get() = File(homeDir, ".gemini/antigravity-go-auth.json")

    private val acpManager = AcpSessionManager(
        executor = executor,
        emit = { payload -> handleAcpOrProcessEvent(payload) },
        log = { msg -> log(msg) },
        onTasksChanged = { emitBackgroundTasks() },
        outputOffloadDir = File(tmpDir, "tool-outputs"),
    )

    private val customizationsOps = CustomizationsOps(
        homeDir = homeDir,
        workspaceDir = workspaceDir,
        bashFile = bashFile,
        tmpDir = tmpDir,
        settingsFile = settingsFile,
        atomicWriteText = ::atomicWriteText,
    )

    private val workspaceOps = WorkspaceOps(
        workspaceDir = workspaceDir,
        tmpDir = tmpDir,
        atomicWriteText = ::atomicWriteText,
        runShell = ::runShell,
        runCapturedArgs = ::runCapturedArgs,
    )

    private val terminalManager = TerminalSessionManager(
        executor = executor,
        workspaceDir = workspaceDir,
        tmpDir = tmpDir,
        bashFile = bashFile,
        ptyHostFile = ptyHostFile,
        buildEnv = ::buildEnv,
        emit = ::emit,
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
            runCatching { l(payload) }
        }
    }

    private fun log(msg: String) {
        val clean = LogRedactor.redact(msg)
        synchronized(logs) {
            logs.addLast(clean)
            while (logs.size > 250) logs.removeFirst()
        }
        synchronized(runTail) {
            runTail.addLast(clean)
            while (runTail.size > CrashClassifier.TAIL_LINES) runTail.removeFirst()
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
        val wasCancelled = cancelledTurns.remove(turnId)
        activeTurns.remove(turnId)
        nonAcpTurnMeta.remove(turnId)
        emitBackgroundTasks()
        if (AgyService.running) {
            AgyService.updateTurnStatus(appContext, "On-device Antigravity CLI harness active")
        }
        if (exitCode == 0 || wasCancelled) {
            if (exitCode == 0) {
                if (safeState == SafeState.PROBATION && (upMs == null || upMs >= SafePolicy.HEALTHY_MS || receivedOut)) {
                    safeState = SafeState.OFF
                }
                consecutiveStrikes = 0
            }
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

    fun getLogs(): List<String> = synchronized(logs) { logs.toList() }

    fun listBackgroundTasks(): List<Map<String, Any?>> {
        val tasks = mutableListOf<Map<String, Any?>>()
        tasks.addAll(acpManager.listBackgroundTasks())
        for ((turnId, meta) in nonAcpTurnMeta) {
            if (activeTurns.containsKey(turnId)) {
                tasks.add(
                    mapOf(
                        "id" to "turn:$turnId",
                        "turnId" to turnId,
                        "kind" to "turn",
                        "title" to meta.first,
                        "status" to "running",
                        "startedAtMs" to meta.second,
                    )
                )
            }
        }
        tasks.sortBy { (it["startedAtMs"] as? Long) ?: 0L }
        return tasks
    }

    private fun emitBackgroundTasks() {
        val tasks = listBackgroundTasks()
        emit(mapOf("kind" to "background_tasks", "tasks" to tasks))
        if (AgyService.running) {
            val terminalCount = tasks.count { it["kind"] == "terminal" }
            val turnCount = tasks.count { it["kind"] == "turn" }
            val statusText = when {
                terminalCount > 0 ->
                    "Running $terminalCount background command${if (terminalCount == 1) "" else "s"}…"
                turnCount > 0 ->
                    "Agent running ($turnCount active)…"
                else ->
                    "On-device Antigravity CLI harness active"
            }
            AgyService.updateTurnStatus(appContext, statusText)
        }
    }

    fun cancelBackgroundTask(taskId: String): Boolean {
        if (taskId.startsWith("turn:")) {
            cancelTurn(taskId.removePrefix("turn:"))
            return true
        }
        if (acpManager.cancelTerminal(taskId)) return true
        if (activeTurns.containsKey(taskId)) {
            cancelTurn(taskId)
            return true
        }
        return forceStopAllBackgroundTasks() > 0
    }

    fun forceStopAllBackgroundTasks(): Int {
        var count = acpManager.forceStopAll()
        for (tid in activeTurns.keys.toList()) {
            val proc = activeTurns.remove(tid)
            nonAcpTurnMeta.remove(tid)
            if (proc != null) {
                count++
                runCatching { proc.destroyForcibly() }
                emit(mapOf("kind" to "turn_exit", "turnId" to tid, "exitCode" to 137))
            }
        }
        emitBackgroundTasks()
        return count
    }

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
        if (phase == RuntimePhase.running && AgyService.running) {
            emitStatus()
            return
        }
        phase = RuntimePhase.starting
        statusMessage = "Starting Antigravity foreground harness…"
        emitStatus()

        val intent = Intent(appContext, AgyService::class.java)
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
        }
        if (started.isFailure) {
            phase = RuntimePhase.stopped
            errorMessage = started.exceptionOrNull()?.message
            statusMessage = "Tap Start to launch foreground service"
            log("Deferred foreground service start: ${errorMessage ?: "not allowed"}")
            emitStatus()
            return
        }
        errorMessage = null
        phase = RuntimePhase.running
        statusMessage = if (safeMode) "Running (Safe Mode)" else "Running on device"
        log(statusMessage)
        emitStatus()
    }

    fun stopService() {
        acpManager.forceStopAll()
        runCatching { loginProcess?.destroyForcibly() }
        loginProcess = null
        loginWriter = null
        for ((_, proc) in activeTurns) {
            runCatching { proc.destroyForcibly() }
        }
        activeTurns.clear()
        nonAcpTurnMeta.clear()
        terminalManager.closeAll()
        appContext.stopService(Intent(appContext, AgyService::class.java))
        phase = if (binaryFile.exists()) RuntimePhase.stopped else RuntimePhase.uninstalled
        statusMessage = "Stopped"
        log("Runtime stopped")
        emitBackgroundTasks()
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

    private fun isBusyboxHealthy(busyboxBin: File): Boolean {
        if (!busyboxBin.isFile) return false
        val busyboxLink = File(binDir, "busybox")
        return try {
            // BusyBox resolves applets from argv[0]; invoke via the `busybox` symlink
            // rather than `libbusybox.so` directly so applet dispatch succeeds.
            ensureSymlink(busyboxLink, busyboxBin.absolutePath)
            val probe = ProcessBuilder(busyboxLink.absolutePath, "true")
                .directory(tmpDir)
                .redirectErrorStream(true)
                .start()
            if (!probe.waitFor(3, TimeUnit.SECONDS)) {
                probe.destroyForcibly()
                return false
            }
            if (probe.exitValue() != 0) return false

            val lsProbe = ProcessBuilder(busyboxLink.absolutePath, "ls", tmpDir.absolutePath)
                .directory(tmpDir)
                .redirectErrorStream(true)
                .start()
            if (!lsProbe.waitFor(3, TimeUnit.SECONDS)) {
                lsProbe.destroyForcibly()
                return false
            }
            lsProbe.exitValue() == 0
        } catch (_: Throwable) {
            false
        }
    }

    private fun isBashHealthy(bashBin: File): Boolean {
        if (!bashBin.isFile) return false
        return try {
            // Exercise PATH lookup (`command -v sh`) and `test -d` so Android seccomp
            // issues (e.g. SIGSYS / 159 on faccessat2) are caught before wiring SHELL.
            val pb = ProcessBuilder(
                bashBin.absolutePath,
                "-c",
                "command -v sh >/dev/null && test -d \"\$1\"",
                "bash",
                tmpDir.absolutePath,
            )
            pb.directory(tmpDir)
            pb.environment()["PATH"] = "${binDir.absolutePath}:/system/bin:/system/xbin"
            pb.redirectErrorStream(true)
            val probe = pb.start()
            if (!probe.waitFor(3, TimeUnit.SECONDS)) {
                probe.destroyForcibly()
                return false
            }
            probe.exitValue() == 0
        } catch (_: Throwable) {
            false
        }
    }

    private fun writeFallbackShWrapper() {
        val currentTarget = runCatching { Os.readlink(bashFile.absolutePath) }.getOrNull()
        if (currentTarget != null) {
            runCatching { bashFile.delete() }
        }
        bashFile.writeText("#!/system/bin/sh\nexec /system/bin/sh \"\$@\"\n")
        bashFile.setExecutable(true, false)
    }

    private fun clearBusyboxSymlinks() {
        for (name in (busyboxApplets + "busybox")) {
            if (name == "agy" || name == "bash" || name == "pty-host") continue
            val linkFile = File(binDir, name)
            val target = runCatching { Os.readlink(linkFile.absolutePath) }.getOrNull()
            if (target != null && (target.contains("libbusybox.so") || target.endsWith("/busybox"))) {
                runCatching { linkFile.delete() }
            }
        }
    }

    fun ensureShellToolchain(force: Boolean = false) {
        synchronized(toolchainLock) {
            val storageAccessNow = hasStorageAccess()
            if (!force &&
                toolchainInitialized &&
                lastToolchainStorageAccess == storageAccessNow &&
                bashFile.exists()
            ) {
                return
            }
            try {
                binDir.mkdirs()
                tmpDir.mkdirs()
                val nativeLibDir = appContext.applicationInfo?.nativeLibraryDir
                val bundledBash = nativeLibDir?.let { File(it, "libbash.so") }?.takeIf { it.isFile }
                val bundledBusybox = nativeLibDir?.let { File(it, "libbusybox.so") }?.takeIf { it.isFile }
                val bundledPty = nativeLibDir?.let { File(it, "libpty.so") }?.takeIf { it.isFile }

                if (bundledBash != null && isBashHealthy(bundledBash)) {
                    bashHealthy = true
                    ensureSymlink(bashFile, bundledBash.absolutePath)
                } else {
                    bashHealthy = false
                    writeFallbackShWrapper()
                }

                if (bundledPty != null) {
                    ensureSymlink(ptyHostFile, bundledPty.absolutePath)
                }

                if (bundledBusybox != null && isBusyboxHealthy(bundledBusybox)) {
                    busyboxHealthy = true
                    ensureSymlink(File(binDir, "busybox"), bundledBusybox.absolutePath)
                    for (applet in busyboxApplets) {
                        if (applet == "agy" || applet == "bash" || applet == "pty-host") continue
                        ensureSymlink(File(binDir, applet), bundledBusybox.absolutePath)
                    }
                } else {
                    busyboxHealthy = false
                    clearBusyboxSymlinks()
                }

                ensureHelperScripts()

                val sdcardLink = File(homeDir, "sdcard")
                val wsStorageLink = File(workspaceDir, "phone_storage")
                if (hasStorageAccess()) {
                    val extRoot = Environment.getExternalStorageDirectory()?.absolutePath
                        ?: "/storage/emulated/0"
                    if (File(extRoot).canRead()) {
                        ensureSymlink(sdcardLink, extRoot)
                        ensureSymlink(wsStorageLink, extRoot)
                    }
                } else {
                    runCatching { if (sdcardLink.exists()) sdcardLink.delete() }
                    runCatching { if (wsStorageLink.exists()) wsStorageLink.delete() }
                }
                toolchainInitialized = true
                lastToolchainStorageAccess = storageAccessNow
            } catch (_: Throwable) {}
        }
    }

    private fun writeHelperScript(name: String, content: String) {
        val target = File(binDir, name)
        runCatching {
            if (!target.exists() || target.readText() != content) {
                target.writeText(content)
            }
            target.setExecutable(true, false)
        }
    }

    private fun ensureHelperScripts() {
        val shBang = if (bashFile.canExecute()) "#!${bashFile.absolutePath}" else "#!/system/bin/sh"
        writeHelperScript(
            "cs",
            "$shBang\n# Placeholder stub for CLI environment probes\nexit 0\n",
        )
        writeHelperScript(
            "torch",
            """$shBang
state="${'$'}{1:-on}"
case "${'$'}state" in
  off|0|false) en=false ;;
  on|1|true) en=true ;;
  *) echo "usage: torch [on|off]" >&2; exit 2 ;;
esac
am broadcast -n ${appContext.packageName}/.runtime.TorchReceiver -a ${TorchReceiver.ACTION_TORCH} --ez enabled "${'$'}en" >/dev/null 2>&1 || true
echo "torch: ${'$'}state"
""",
        )
        writeHelperScript(
            "agy-notify",
            """$shBang
TITLE="Antigravity"
MESSAGE=""
TAG="agy_cli"
while [ "${'$'}#" -gt 0 ]; do
  case "${'$'}1" in
    post) shift ;;
    -t|--title) TITLE="${'$'}{2:-Antigravity}"; shift 2 ;;
    -m|--message) MESSAGE="${'$'}{2:-}"; shift 2 ;;
    --tag) TAG="${'$'}{2:-agy_cli}"; shift 2 ;;
    *) [ -z "${'$'}MESSAGE" ] && MESSAGE="${'$'}1"; shift ;;
  esac
done
if [ -n "${'$'}{AGY_PHONE_MCP_URL:-}" ] && command -v curl >/dev/null 2>&1; then
  payload="{\"action\":\"notify\",\"title\":\"${'$'}TITLE\",\"message\":\"${'$'}MESSAGE\",\"tag\":\"${'$'}TAG\"}"
  curl -fsSL -H "Authorization: Bearer ${'$'}{AGY_PHONE_MCP_TOKEN:-}" -H "Content-Type: application/json" -d "${'$'}payload" "${'$'}AGY_PHONE_MCP_URL" >/dev/null 2>&1 && exit 0
fi
cmd notification post -S bigtext -t "${'$'}TITLE" "${'$'}TAG" "${'$'}MESSAGE" >/dev/null 2>&1 || echo "[agy-notify] ${'$'}TITLE: ${'$'}MESSAGE"
""",
        )
        writeHelperScript(
            "agy-fix-paths",
            """$shBang
PREFIX_DIR="${'$'}{PREFIX:-${runtimeDir.absolutePath}}"
SH_PATH="${'$'}{SHELL:-/system/bin/sh}"
count=0
for root in "${'$'}{@:-${'$'}PREFIX_DIR}"; do
  [ -e "${'$'}root" ] || continue
  while IFS= read -r f; do
    [ -f "${'$'}f" ] || continue
    tmp="${'$'}f.agyfix.$$"
    sed -E "1s@^#! */usr/bin/env[[:space:]]+([^[:space:]]+)@#!${'$'}PREFIX_DIR/bin/\\1@" "${'$'}f" > "${'$'}tmp" 2>/dev/null || { rm -f "${'$'}tmp"; continue; }
    if cmp -s "${'$'}f" "${'$'}tmp"; then rm -f "${'$'}tmp"; else mv -f "${'$'}tmp" "${'$'}f"; chmod +x "${'$'}f" 2>/dev/null || true; count=$((count + 1)); fi
  done < <(grep -rl '^#! */usr/bin/env' "${'$'}root" 2>/dev/null || true)
done
echo "agy-fix-paths: updated ${'$'}count file(s) -> ${'$'}PREFIX_DIR"
""",
        )
        val browserShim = """$shBang
url="${'$'}{1:-}"
[ -n "${'$'}url" ] || exit 0
am start -a android.intent.action.VIEW -d "${'$'}url" >/dev/null 2>&1 || echo "[open] ${'$'}url"
"""
        writeHelperScript("xdg-open", browserShim)
        writeHelperScript("open", browserShim)
    }

    private fun ensureSymlink(linkFile: File, targetPath: String) {
        try {
            val currentTarget = runCatching { Os.readlink(linkFile.absolutePath) }.getOrNull()
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

    fun syncPhoneMcpRegistration() = customizationsOps.syncPhoneMcpRegistration()

    private fun buildEnv(extra: Map<String, String> = emptyMap()): Map<String, String> {
        PhoneControlCoordinator.bindContext(appContext)
        ensureShellToolchain()
        val env = LinkedHashMap<String, String>()
        env.putAll(System.getenv())
        env["HOME"] = homeDir.absolutePath
        env["PREFIX"] = runtimeDir.absolutePath
        env["XDG_CONFIG_HOME"] = File(homeDir, ".config").absolutePath
        env["XDG_CACHE_HOME"] = File(homeDir, ".cache").absolutePath
        env["TMPDIR"] = tmpDir.absolutePath
        env["TERM"] = env["TERM"]?.takeIf { it.isNotBlank() } ?: "xterm-256color"
        env["ANDROID_DATA"] = env["ANDROID_DATA"]?.takeIf { it.isNotBlank() } ?: "/data"
        env["RISH_APPLICATION_ID"] = appContext.packageName
        env["SHELL"] = if (bashFile.canExecute()) bashFile.absolutePath else "/system/bin/sh"
        env["CONFIG_SHELL"] = env["SHELL"]!!
        env["ANDROID_STORAGE"] = Environment.getExternalStorageDirectory()?.absolutePath ?: "/sdcard"
        val basePath = System.getenv("PATH") ?: "/system/bin:/system/xbin"
        env["PATH"] = "${binDir.absolutePath}:$basePath"
        PhoneControlCoordinator.currentMcpEndpoint()?.let { ep ->
            env["AGY_PHONE_MCP_URL"] = ep.url
            env["AGY_PHONE_MCP_TOKEN"] = ep.authToken
        }
        env.putAll(extra)
        return env
    }

    fun readSettings(): Map<String, Any?> = customizationsOps.readSettings()
    fun writeSettings(patch: Map<String, Any?>) = customizationsOps.writeSettings(patch)

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
            runCatching {
                JSONObject(authMarkerFile.readText()).optString("email").takeIf { it.isNotBlank() }
            }.getOrNull()
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

        if (authMarkerFile.exists()) {
            runCatching {
                val marker = JSONObject(authMarkerFile.readText())
                if (marker.optBoolean("isAuthenticated", false)) {
                    hasCreds = true
                    foundEmail = marker.optString("email").takeIf { it.isNotBlank() }
                }
            }
        }

        for (root in listOf(geminiDir, configDir, localShareDir)) {
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
                if (looksLikeAuth) hasCreds = true
                if (foundEmail == null &&
                    (looksLikeAuth || lower == "settings.json" || lower == "config.json")
                ) {
                    runCatching {
                        val match = emailRegex.find(f.readText())
                        if (match != null && !match.value.endsWith(".example.com")) {
                            foundEmail = match.value
                        }
                    }
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

    private fun isGlogBootstrapNoise(line: String): Boolean {
        val t = line.trim()
        return t.startsWith("ERROR: logging before google.Init:") ||
            Regex("^[IWEF]\\d{4}\\s+\\d{2}:\\d{2}:\\d{2}\\.\\d+.*server_zerog\\.go").containsMatchIn(t)
    }

    private fun stripGlogNoise(text: String): String =
        text.lineSequence()
            .filterNot { isGlogBootstrapNoise(it) }
            .joinToString("\n")
            .trim()

    private fun runStdoutPreferringCapture(args: List<String>, timeoutSeconds: Int): String {
        if (!binaryFile.exists()) return ""
        val pb = ProcessBuilder(listOf(binaryFile.absolutePath) + args)
        pb.directory(workspaceDir)
        pb.environment().putAll(buildEnv())
        pb.redirectErrorStream(false)
        val proc = pb.start()
        val outFuture = executor.submit<String> { proc.inputStream.bufferedReader().use { it.readText() } }
        val errFuture = executor.submit<String> { proc.errorStream.bufferedReader().use { it.readText() } }
        if (!proc.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)) proc.destroyForcibly()
        val stdout = runCatching { stripGlogNoise(outFuture.get(2, TimeUnit.SECONDS)) }.getOrDefault("")
        if (stdout.isNotBlank()) return stdout
        return runCatching { stripGlogNoise(errFuture.get(2, TimeUnit.SECONDS)) }.getOrDefault("")
    }

    fun probeUsage(): String {
        if (!binaryFile.exists()) return ""
        val sb = StringBuilder()
        val modelsOut = runCatching { runStdoutPreferringCapture(listOf("models"), 12) }.getOrDefault("")
        if (modelsOut.isNotBlank()) sb.append(modelsOut).append("\n")

        var printUsage = runCatching {
            runStdoutPreferringCapture(listOf("-p", "/usage", "--output-format", "json"), 18)
        }.getOrDefault("")
        if (!printUsage.contains("remaining_fraction") && !printUsage.contains("%")) {
            printUsage = runCatching {
                runStdoutPreferringCapture(listOf("-p", "/usage", "--output-format", "text"), 18)
            }.getOrDefault("")
        }
        var printCredits = runCatching {
            runStdoutPreferringCapture(listOf("-p", "/credits", "--output-format", "json"), 15)
        }.getOrDefault("")
        if (!printCredits.contains("remaining_credits") && !printCredits.lowercase().contains("credit")) {
            printCredits = runCatching {
                runStdoutPreferringCapture(listOf("-p", "/credits", "--output-format", "text"), 15)
            }.getOrDefault("")
        }
        if (printUsage.isNotBlank()) sb.append(printUsage).append("\n")
        if (printCredits.isNotBlank()) sb.append(printCredits).append("\n")

        val combinedSoFar = sb.toString().lowercase()
        val hasQuotaNumbers = combinedSoFar.contains("remaining_fraction") ||
            (combinedSoFar.contains("%") &&
                (combinedSoFar.contains("5-hour") || combinedSoFar.contains("5 hour") || combinedSoFar.contains("weekly") || combinedSoFar.contains("gemini")))
        if (!hasQuotaNumbers) {
            val interactiveOut = stripGlogNoise(runInteractiveProbe("/usage\n/credits\n/exit\n", 14))
            if (interactiveOut.isNotBlank()) sb.append(interactiveOut).append("\n")
        }
        return sb.toString().trim()
    }

    private fun runInteractiveProbe(stdinCommands: String, timeoutSeconds: Int): String {
        if (!binaryFile.exists()) return ""
        return try {
            val pb = ProcessBuilder(listOf(binaryFile.absolutePath))
            pb.directory(workspaceDir)
            pb.environment().putAll(
                buildEnv(mapOf("COLUMNS" to "120", "LINES" to "40", "TERM" to "xterm-256color"))
            )
            pb.redirectErrorStream(true)
            val proc = pb.start()
            OutputStreamWriter(proc.outputStream).use { writer ->
                writer.write(stdinCommands)
                writer.flush()
            }
            val readFuture = executor.submit<String> { proc.inputStream.bufferedReader().use { it.readText() } }
            if (!proc.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)) proc.destroyForcibly()
            runCatching { readFuture.get(2, TimeUnit.SECONDS) }.getOrDefault("")
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
                log(if (enterprise) "Starting Gemini Enterprise login…" else "Starting Google Account login via `agy acp --login`…")
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
                    urlRegex.find(l)?.value?.let { url ->
                        emit(mapOf("kind" to "auth_oauth_url", "logLine" to url))
                    }
                    if (capturedEmail == null) {
                        val m = emailRegex.find(l)
                        if (m != null && !m.value.endsWith(".example.com")) capturedEmail = m.value
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
        acpManager.closeAllLiveWorkers()
        MultiAccountVault.clearActiveAccountOnLogout(homeDir, accountsDir)
        writeAuthMarker(false)
        if (binaryFile.exists()) {
            runCatching { runCapture(listOf("-p", "/logout", "--output-format", "text"), null, emptyMap(), 8) }
        }
        log("Cleared cached Google credentials")
    }

    fun exportCredentials(
        passphrase: String,
        geminiApiKey: String? = null,
        authProfileJson: String? = null,
        accountId: String? = null,
    ): String {
        val bundle = MultiAccountVault.exportAccount(
            homeDir = homeDir,
            accountsDir = accountsDir,
            accountId = accountId,
            passphrase = passphrase,
            fallbackGeminiApiKey = geminiApiKey,
            fallbackAuthProfileJson = authProfileJson,
        )
        log("Exported encrypted credentials bundle")
        return bundle
    }

    fun importCredentials(
        bundleJson: String,
        passphrase: String,
        activate: Boolean = true,
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): Map<String, Any?> {
        val res = MultiAccountVault.importEncryptedBundle(
            homeDir = homeDir,
            accountsDir = accountsDir,
            bundleJson = bundleJson,
            passphrase = passphrase,
            activate = activate,
            currentAuthProfileJson = currentAuthProfileJson,
            currentGeminiApiKey = currentGeminiApiKey,
        )
        if (activate) {
            acpManager.closeAllLiveWorkers()
        }
        val count = res["restoredFiles"] ?: 0
        log("Imported encrypted credentials bundle ($count file(s) restored, activate=$activate)")
        return res
    }

    fun listAccounts(
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): List<Map<String, Any?>> =
        MultiAccountVault.listAccounts(
            homeDir = homeDir,
            accountsDir = accountsDir,
            currentAuthProfileJson = currentAuthProfileJson,
            currentGeminiApiKey = currentGeminiApiKey,
        )

    fun syncActiveAccount(
        authProfileJson: String? = null,
        geminiApiKey: String? = null,
    ): Map<String, Any?>? =
        MultiAccountVault.syncActiveAccount(
            homeDir = homeDir,
            accountsDir = accountsDir,
            authProfileJson = authProfileJson,
            geminiApiKey = geminiApiKey,
        )

    fun switchAccount(
        accountId: String,
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): Map<String, Any?> {
        val res = MultiAccountVault.switchAccount(
            homeDir = homeDir,
            accountsDir = accountsDir,
            accountId = accountId,
            currentAuthProfileJson = currentAuthProfileJson,
            currentGeminiApiKey = currentGeminiApiKey,
        )
        acpManager.closeAllLiveWorkers()
        val acct = res["account"] as? Map<*, *>
        log("Switched active account to ${acct?.get("displayName") ?: accountId}")
        return res
    }

    fun removeAccount(accountId: String): Map<String, Any?> {
        val res = MultiAccountVault.removeAccount(
            homeDir = homeDir,
            accountsDir = accountsDir,
            accountId = accountId,
        )
        if (res["wasActive"] == true) {
            acpManager.closeAllLiveWorkers()
        }
        log("Removed saved account $accountId")
        return res
    }

    fun runCapture(
        args: List<String>,
        cwd: String?,
        extraEnv: Map<String, String>,
        timeoutSeconds: Int,
    ): String {
        if (!binaryFile.exists()) return ""
        val pb = ProcessBuilder(listOf(binaryFile.absolutePath) + args)
        pb.directory(if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir)
        pb.environment().putAll(buildEnv(extraEnv))
        pb.redirectErrorStream(true)
        val proc = pb.start()
        val readFuture = executor.submit<String> { proc.inputStream.bufferedReader().use { it.readText() } }
        if (!proc.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)) proc.destroyForcibly()
        return runCatching { readFuture.get(2, TimeUnit.SECONDS) }.getOrDefault("")
    }

    fun runHeadlessPrompt(prompt: String, modelId: String?, cwd: String?): Pair<Int, String> {
        if (!binaryFile.exists()) return 127 to "agy not installed"
        val cmd = mutableListOf(binaryFile.absolutePath, "-p", prompt, "--output-format", "text")
        if (!modelId.isNullOrBlank()) cmd.addAll(listOf("--model", modelId))
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        return runCapturedArgs(cmd, dir, emptyMap(), 120)
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
        val readFuture = executor.submit<String> { proc.inputStream.bufferedReader().use { it.readText() } }
        if (!proc.waitFor(30, TimeUnit.SECONDS)) proc.destroyForcibly()
        return runCatching { readFuture.get(2, TimeUnit.SECONDS) }.getOrDefault("")
    }

    private fun resolveExecutable(cmd: String): String {
        if (cmd.contains('/')) return cmd
        val inBin = File(binDir, cmd)
        if (inBin.canExecute()) return inBin.absolutePath
        if (cmd == "git") {
            val optGit = File(runtimeDir, "opt/git/data/data/com.termux/files/usr/bin/git")
            if (optGit.canExecute()) return optGit.absolutePath
        }
        return cmd
    }

    private fun runCapturedArgs(
        args: List<String>,
        cwd: File,
        extraEnv: Map<String, String> = emptyMap(),
        timeoutSeconds: Long = 30,
    ): Pair<Int, String> {
        if (args.isEmpty()) return 1 to ""
        if (!cwd.exists() || !cwd.isDirectory) return 1 to ""
        val resolvedCmd = resolveExecutable(args.first())
        val effectiveArgs = listOf(resolvedCmd) + args.drop(1)
        return try {
            val pb = ProcessBuilder(effectiveArgs)
            pb.directory(cwd)
            val env = buildEnv(extraEnv).toMutableMap()
            if (args.first() == "git" && resolvedCmd.contains("/opt/git/")) {
                val usr = File(runtimeDir, "opt/git/data/data/com.termux/files/usr")
                val ld = env["LD_LIBRARY_PATH"].orEmpty()
                val usrLib = File(usr, "lib").absolutePath
                env["LD_LIBRARY_PATH"] = if (ld.isBlank()) usrLib else "$usrLib:$ld"
                env.putIfAbsent("GIT_EXEC_PATH", File(usr, "libexec/git-core").absolutePath)
                env.putIfAbsent("GIT_TEMPLATE_DIR", File(usr, "share/git-core/templates").absolutePath)
                env.putIfAbsent("GIT_CONFIG_NOSYSTEM", "1")
                env.putIfAbsent("GIT_ATTR_NOSYSTEM", "1")
            }
            pb.environment().putAll(env)
            pb.redirectErrorStream(true)
            val proc = pb.start()
            val readFuture = executor.submit<String> { proc.inputStream.bufferedReader().use { it.readText() } }
            val finished = proc.waitFor(timeoutSeconds, TimeUnit.SECONDS)
            val code = if (finished) proc.exitValue() else {
                proc.destroyForcibly()
                124
            }
            val out = runCatching { readFuture.get(2, TimeUnit.SECONDS) }.getOrDefault("")
            code to out
        } catch (t: Throwable) {
            127 to (t.message ?: t.toString())
        }
    }

    fun startTerminalSession(sessionId: String, cwd: String?, cols: Int = 80, rows: Int = 24) =
        terminalManager.startSession(sessionId, cwd, cols, rows)

    fun resizeTerminalSession(sessionId: String, cols: Int, rows: Int): Boolean =
        terminalManager.resizeSession(sessionId, cols, rows)

    fun writeTerminalInput(sessionId: String, input: String): Boolean =
        terminalManager.writeInput(sessionId, input)

    fun closeTerminalSession(sessionId: String) =
        terminalManager.closeSession(sessionId)

    fun diagnoseRuntime(): Map<String, Any?> {
        ensureShellToolchain(force = true)
        val env = buildEnv()
        val bashWorks = runCatching {
            runShell(
                "for t in bash ls find grep sed awk; do p=\$(command -v \"\$t\" 2>/dev/null || true); echo \"\$t: \${p:-MISSING}\"; done",
                null,
            ).trim()
        }.getOrElse { "error: ${it.message}" }
        val storageProbe = if (hasStorageAccess()) {
            runCatching { runShell("ls -la /sdcard/Download 2>&1 | /system/bin/head -n 10", null).trim() }
                .getOrElse { "error: ${it.message}" }
        } else {
            "All Files Access not granted"
        }
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val batteryExempt = pm?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
        return mapOf(
            "agyExists" to (binaryFile.exists() && binaryFile.canExecute()),
            "bashPath" to bashFile.absolutePath,
            "bashExecutable" to bashFile.canExecute(),
            "bashHealthy" to bashHealthy,
            "ptyHostExecutable" to ptyHostFile.canExecute(),
            "busyboxExecutable" to File(binDir, "busybox").canExecute(),
            "busyboxHealthy" to busyboxHealthy,
            "allFilesAccess" to hasStorageAccess(),
            "batteryOptimizationExempt" to batteryExempt,
            "shizukuAvailable" to io.github.dwicao.antigravity_go.phone.DeviceGatewayHelper.isShizukuAvailable(appContext),
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
            appContext.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED &&
                appContext.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private fun defaultExtraDirs(requested: List<String>): List<String> {
        val out = LinkedHashSet<String>()
        for (d in requested) if (d.isNotBlank()) out.add(d)
        if (hasStorageAccess()) {
            val ext = Environment.getExternalStorageDirectory()?.absolutePath ?: "/storage/emulated/0"
            out.add(ext)
            out.add("/sdcard")
        }
        return out.toList()
    }

    fun setGuardrailsEnabled(enabled: Boolean) {
        CommandSafetyGuard.enabled = enabled
    }

    private fun appVersionName(): String = runCatching {
        appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName ?: "1.0.32"
    }.getOrDefault("1.0.32")

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
        agent: String? = null,
        printTimeoutSeconds: Int? = null,
        disableSlashCommands: Boolean = false,
        continueLast: Boolean = false,
        remoteAgent: String? = null,
        attachments: List<String> = emptyList(),
    ) {
        if (!binaryFile.exists()) {
            emit(mapOf("kind" to "turn_exit", "turnId" to turnId, "exitCode" to 127))
            return
        }

        cancelledTurns.remove(turnId)
        turnStartedAt[turnId] = System.currentTimeMillis()
        turnReceivedOutput[turnId] = false
        synchronized(runTail) { runTail.clear() }
        AgyService.refreshWakeLock(appContext)
        if (AgyService.running) {
            AgyService.updateTurnStatus(appContext, "Agent thinking…")
        }

        val storageGranted = hasStorageAccess()
        val storageEnabled = allowNonWorkspaceAccess && storageGranted
        if (!safeMode) {
            customizationsOps.syncManagedGeminiMd(allowStorage = storageEnabled)
        }
        customizationsOps.syncPhoneMcpRegistration()

        try {
            val currentSettings = readSettings()
            val patch = mutableMapOf<String, Any?>("allowNonWorkspaceAccess" to storageEnabled)
            if (skipPermissions) {
                patch["toolPermission"] = "always-proceed"
                patch["permissions"] = mapOf(
                    "allow" to listOf("command(*)", "read_file(*)", "write_file(*)"),
                )
            } else {
                val curPerm = currentSettings["toolPermission"]?.toString()
                if (curPerm == "auto" || curPerm == "always-proceed") {
                    patch["toolPermission"] = "default"
                }
                if (currentSettings.containsKey("permissions")) {
                    patch["permissions"] = null
                }
            }
            writeSettings(patch)
        } catch (_: Throwable) {}

        val effectiveCwd = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (!effectiveCwd.exists()) runCatching { effectiveCwd.mkdirs() }
        val mergedDirs = defaultExtraDirs(extraDirs)
        val safeCliMode = when (mode?.lowercase()?.trim()) {
            null, "", "auto" -> if (skipPermissions) null else "default"
            else -> mode
        }
        val extraEnv = mutableMapOf<String, String>()
        if (!geminiApiKey.isNullOrBlank()) {
            extraEnv["GEMINI_API_KEY"] = geminiApiKey
        }

        val useAcpForTurn = useAcp &&
            printTimeoutSeconds == null &&
            !disableSlashCommands &&
            !continueLast &&
            remoteAgent.isNullOrBlank()

        if (useAcpForTurn) {
            acpManager.startTurn(
                turnId = turnId,
                binaryPath = binaryFile.absolutePath,
                cwd = effectiveCwd,
                env = buildEnv(extraEnv),
                prompt = prompt,
                extraDirs = mergedDirs,
                existingSessionId = conversationId,
                modelId = model,
                effort = effort,
                modeCli = safeCliMode,
                skipPermissions = skipPermissions,
                agent = agent?.takeIf { it.isNotBlank() },
                attachments = attachments,
                clientVersion = appVersionName(),
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
                    if (File(dir).exists()) cmd.addAll(listOf("--add-dir", dir))
                }
                if (!safeCliMode.isNullOrBlank()) cmd.addAll(listOf("--mode", safeCliMode))
                if (!model.isNullOrBlank()) cmd.addAll(listOf("--model", model))
                if (!effort.isNullOrBlank() && !(model?.lowercase()?.contains("orchestrator") == true)) {
                    cmd.addAll(listOf("--effort", effort))
                }
                if (!conversationId.isNullOrBlank()) cmd.addAll(listOf("--conversation", conversationId))
                if (!agent.isNullOrBlank()) cmd.addAll(listOf("--agent", agent))
                if (printTimeoutSeconds != null && printTimeoutSeconds > 0) {
                    cmd.addAll(listOf("--print-timeout", printTimeoutSeconds.toString()))
                }
                if (disableSlashCommands) cmd.add("--disable-slash-commands")
                if (continueLast) cmd.add("--continue")
                if (!remoteAgent.isNullOrBlank()) cmd.addAll(listOf("--remote-agent", remoteAgent))
                if (skipPermissions) cmd.add("--dangerously-skip-permissions")

                val pb = ProcessBuilder(cmd)
                pb.directory(effectiveCwd)
                pb.environment().putAll(buildEnv(extraEnv))
                val proc = pb.start()
                activeTurns[turnId] = proc
                nonAcpTurnMeta[turnId] = Pair(
                    AcpSessionManager.summarizeCommand(prompt, maxLen = 64),
                    System.currentTimeMillis(),
                )
                emitBackgroundTasks()

                val errFuture = executor.submit {
                    val redactor = LogRedactor()
                    BufferedReader(InputStreamReader(proc.errorStream)).use { errReader ->
                        var errLine: String?
                        while (errReader.readLine().also { errLine = it } != null) {
                            val rawErr = errLine ?: ""
                            if (isGlogBootstrapNoise(rawErr)) continue
                            handleAcpOrProcessEvent(
                                mapOf(
                                    "kind" to "turn_stderr",
                                    "turnId" to turnId,
                                    "stderrLine" to redactor.line(rawErr),
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

                runCatching { errFuture.get(5, TimeUnit.SECONDS) }
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
                activeTurns.remove(turnId)?.let { p ->
                    if (p.isAlive) runCatching { p.destroyForcibly() }
                }
                nonAcpTurnMeta.remove(turnId)
                emitBackgroundTasks()
            }
        }
    }

    fun respondPermission(turnId: String, requestId: Any, optionId: String) =
        acpManager.respondToPermission(turnId, requestId, optionId)

    fun handleNotificationPermissionAction(
        turnId: String,
        requestId: Any,
        optionId: String,
        approved: Boolean,
    ) {
        acpManager.respondToPermission(turnId, requestId, optionId)
        emit(
            mapOf(
                "kind" to "notification_permission_action",
                "turnId" to turnId,
                "requestId" to requestId.toString(),
                "optionId" to optionId,
                "approved" to approved,
            )
        )
    }

    fun setLifecycleHooks(rawJson: String) {
        LifecycleHooksManager.updateFromJson(rawJson)
    }

    fun revertPatch(cwd: String?, patchText: String): Map<String, Any?> =
        workspaceOps.revertPatch(cwd, patchText)

    fun cancelTurn(turnId: String) {
        cancelledTurns.add(turnId)
        acpManager.cancel(turnId)
        activeTurns.remove(turnId)?.destroyForcibly()
        nonAcpTurnMeta.remove(turnId)
        emitBackgroundTasks()
    }

    fun closeSessionWorker(sessionId: String): Boolean = acpManager.closeWorker(sessionId)

    fun writeTextFile(path: String, content: String): Boolean = workspaceOps.writeTextFile(path, content)
    fun listCustomizations(cwd: String?): List<Map<String, Any?>> = customizationsOps.listCustomizations(cwd)
    fun createSkill(
        name: String,
        description: String,
        scope: String,
        cwd: String?,
        content: String? = null,
    ): String = customizationsOps.createSkill(name, description, scope, cwd, content)
    fun addHttpMcpServer(name: String, url: String, authHeader: String? = null): Boolean =
        customizationsOps.addHttpMcpServer(name, url, authHeader)
    fun gitDiff(cwd: String?): Map<String, String> = workspaceOps.gitDiff(cwd)
    fun gitCommitAndPush(cwd: String?, message: String, stageAll: Boolean, push: Boolean): Map<String, Any?> =
        workspaceOps.gitCommitAndPush(cwd, message, stageAll, push)
    fun listWorkspace(path: String?): List<Map<String, String>> = workspaceOps.listWorkspace(path)
    fun readFile(path: String): String = workspaceOps.readFile(path)
    fun createDirectory(path: String): Boolean = workspaceOps.createDirectory(path)
    fun deleteWorkspaceEntry(path: String): Boolean = workspaceOps.deleteWorkspaceEntry(path)
    fun createCheckpoint(cwd: String?): Map<String, Any?> = workspaceOps.createCheckpoint(cwd)
    fun restoreCheckpoint(cwd: String?, ref: String): Map<String, Any?> = workspaceOps.restoreCheckpoint(cwd, ref)
    fun initHarnessFiles(cwd: String?, featureJson: String, progressTxt: String): Map<String, Any?> =
        workspaceOps.initHarnessFiles(cwd, featureJson, progressTxt)
    fun readHarnessFiles(cwd: String?): Map<String, Any?> = workspaceOps.readHarnessFiles(cwd)
    fun writeHarnessFile(cwd: String?, relativeName: String, content: String): Boolean =
        workspaceOps.writeHarnessFile(cwd, relativeName, content)
}
