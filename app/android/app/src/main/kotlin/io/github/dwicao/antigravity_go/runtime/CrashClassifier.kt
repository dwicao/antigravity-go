package io.github.dwicao.antigravity_go.runtime

/**
 * Classifies unexpected `agy` turn/runtime exits so the mobile harness can decide
 * automatically between retry, ACP -> stream-json fallback, safe-mode engagement,
 * or actionable user remediation (modeled on DSH-Go's CrashClassifier.kt).
 */
enum class FailureKind(val wire: String) {
    AUTH_REQUIRED("authRequired"),
    SANDBOX_UNAVAILABLE("sandboxUnavailable"),
    MISSING_TOOL("missingTool"),
    RATE_LIMITED("rateLimited"),
    NETWORK_ERROR("networkError"),
    NO_SPACE("noSpace"),
    LAUNCH_FAILED("launchFailed"),
    STARTUP_FAILED("startupFailed"),
    CRASHED_EARLY("crashedEarly"),
    CRASHED_LATE("crashedLate"),
    KILLED("killed");

    /** Only startup/early crashes count toward automatic Safe Mode strikes. */
    val countsTowardSafeMode: Boolean
        get() = this == STARTUP_FAILED || this == CRASHED_EARLY || this == LAUNCH_FAILED
}

data class RunFailure(
    val kind: FailureKind,
    val exitCode: Int,
    val safeMode: Boolean,
    val summary: String,
    val hint: String,
    val upMillis: Long?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "kind" to kind.wire,
        "exitCode" to exitCode,
        "safeMode" to safeMode,
        "summary" to summary,
        "hint" to hint,
        "upMillis" to upMillis,
    )
}

object CrashClassifier {
    const val EARLY_WINDOW_MS = 30_000L
    const val TAIL_LINES = 250

    fun classify(
        exitCode: Int,
        upMillis: Long?,
        tailLines: List<String>,
        safeMode: Boolean,
        receivedAgentOutput: Boolean,
    ): RunFailure? {
        if (exitCode == 0) return null
        val joined = tailLines.joinToString("\n")
        val lower = joined.lowercase()
        val lastMeaningful = tailLines.lastOrNull { it.isNotBlank() }?.let(LogRedactor::redact)
            ?: "Process exited with code $exitCode"

        return when {
            lower.contains("auto mode is not available") || lower.contains("os terminal sandbox") ->
                RunFailure(
                    kind = FailureKind.SANDBOX_UNAVAILABLE,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Switch permission preset to Turbo or Default (Fast mode); Android does not provide desktop bubblewrap/seatbelt sandboxing.",
                    upMillis = upMillis,
                )

            exitCode == 159 || lower.contains("sigsys") || lower.contains("bad system call") ->
                RunFailure(
                    kind = FailureKind.CRASHED_EARLY,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Child process hit Android seccomp (SIGSYS / exit 159). Update APK or run Settings -> On-Device Runtime -> Run Shell & Storage Self-Test.",
                    upMillis = upMillis,
                )

            lower.contains("authentication required") ||
                lower.contains("not signed in") ||
                lower.contains("please sign in") ||
                lower.contains("invalid_grant") ||
                lower.contains("token expired") ->
                RunFailure(
                    kind = FailureKind.AUTH_REQUIRED,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Reconnect your Google Account from the sidebar or composer account button.",
                    upMillis = upMillis,
                )

            lower.contains("executable file not found in \$path") ||
                lower.contains("enoent") && lower.contains("bash") ->
                RunFailure(
                    kind = FailureKind.MISSING_TOOL,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Run Settings -> On-Device Runtime -> Run Shell & Storage Self-Test to verify bundled bash/busybox links.",
                    upMillis = upMillis,
                )

            lower.contains("enospc") || lower.contains("no space left on device") ->
                RunFailure(
                    kind = FailureKind.NO_SPACE,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Phone storage is full; free space before continuing.",
                    upMillis = upMillis,
                )

            lower.contains("429") || lower.contains("rate limit") || lower.contains("quota exceeded") || lower.contains("resource_exhausted") ->
                RunFailure(
                    kind = FailureKind.RATE_LIMITED,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Model quota reached; check Usage Limits or switch to another model (e.g. Flash or Carbon).",
                    upMillis = upMillis,
                )

            lower.contains("econnreset") || lower.contains("etimedout") || lower.contains("eai_again") ||
                lower.contains("network is unreachable") || lower.contains("connection refused") ->
                RunFailure(
                    kind = FailureKind.NETWORK_ERROR,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Transient network drop detected; tap Regenerate to resume.",
                    upMillis = upMillis,
                )

            exitCode == 127 || exitCode == 126 ->
                RunFailure(
                    kind = FailureKind.LAUNCH_FAILED,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Binary could not be executed; reinstall runtime in Settings -> On-Device Antigravity Runtime.",
                    upMillis = upMillis,
                )

            exitCode == 137 || exitCode == 143 || (tailLines.isEmpty() && exitCode > 128) ->
                RunFailure(
                    kind = FailureKind.KILLED,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = "Interrupted by Android OS (exit $exitCode)",
                    hint = "Android killed the background process; grant Battery Optimization exemption in Settings to keep long tasks alive.",
                    upMillis = upMillis,
                )

            !receivedAgentOutput && (upMillis == null || upMillis < EARLY_WINDOW_MS) ->
                RunFailure(
                    kind = FailureKind.STARTUP_FAILED,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Agent failed before producing output; Safe Mode can bypass broken MCP/GEMINI.md customizations.",
                    upMillis = upMillis,
                )

            upMillis != null && upMillis < EARLY_WINDOW_MS ->
                RunFailure(
                    kind = FailureKind.CRASHED_EARLY,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Agent crashed early; retrying with fallback transport or Safe Mode may isolate failing plugins.",
                    upMillis = upMillis,
                )

            else ->
                RunFailure(
                    kind = FailureKind.CRASHED_LATE,
                    exitCode = exitCode,
                    safeMode = safeMode,
                    summary = lastMeaningful,
                    hint = "Run ended unexpectedly; tap Regenerate to continue.",
                    upMillis = upMillis,
                )
        }
    }
}
