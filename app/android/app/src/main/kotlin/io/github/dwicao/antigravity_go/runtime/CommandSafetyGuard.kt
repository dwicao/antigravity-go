package io.github.dwicao.antigravity_go.runtime

import java.io.File

/**
 * Deterministic pre/post-tool harness guardrails:
 * 1. [evaluateCommand]: blocks catastrophic shell commands (root/storage wipes, raw device writes, fork bombs).
 * 2. [evaluateWritePath]: blocks writes to system partitions or sensitive credential files.
 * 3. [offloadIfLarge]: offloads verbose terminal output (>12 KB) to scratch log files and returns
 *    a compact head+tail preview with a file pointer to prevent context rot.
 */
object CommandSafetyGuard {

    const val DEFAULT_OFFLOAD_THRESHOLD_CHARS = 6_000
    private const val HEAD_PREVIEW_CHARS = 1_500
    private const val TAIL_PREVIEW_CHARS = 2_500

    @Volatile
    var enabled: Boolean = true

    data class GuardDecision(
        val allowed: Boolean,
        val reason: String = "",
    )

    data class OffloadResult(
        val offloaded: Boolean,
        val text: String,
        val filePath: String? = null,
        val totalChars: Int = 0,
    )

    private val forkBombRegex = Regex(""":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;?\s*:""")

    private val rmCommandRegex = Regex(
        """(?:^|[;&|\n(\s`]|sudo\s+|busybox\s+|command\s+|env\s+|xargs\s+|-exec\s+)(?:/usr/bin/|/bin/)?rm\s+([^\n;|&)`]+)""",
        RegexOption.IGNORE_CASE,
    )

    private val mkfsRegex = Regex(
        """(?:^|[;&|\s])mkfs(?:\.[a-z0-9_]+)?\s+[^\n]*?/dev/""",
        RegexOption.IGNORE_CASE,
    )

    private val ddBlockRegex = Regex(
        """\bdd\b[^\n]*\bof=["']?/dev/(?!null\b|zero\b|stdout\b|stderr\b)""",
        RegexOption.IGNORE_CASE,
    )

    private val rawBlockRedirectRegex = Regex(
        """(?:>|tee\s+(?:-a\s+)?)["']?/dev/(?:sd[a-z]|nvme|mmcblk|block/)""",
        RegexOption.IGNORE_CASE,
    )

    private val protectedWritePrefixes = listOf(
        "/system/",
        "/vendor/",
        "/product/",
        "/apex/",
        "/data/system/",
        "/proc/",
        "/sys/",
        "/dev/block/",
    )

    private val protectedFilenames = setOf(
        "oauth_creds.json",
        "antigravity-go-auth.json",
        "google_accounts.json",
        "credentials.json",
        "antigravity_state.pbtxt",
    )

    fun evaluateCommand(
        command: String,
        args: List<String> = emptyList(),
    ): GuardDecision {
        if (!enabled) return GuardDecision(true)
        val full = if (args.isEmpty()) {
            command.trim()
        } else {
            "${command.trim()} ${args.joinToString(" ")}".trim()
        }
        if (full.isEmpty()) return GuardDecision(true)

        if (forkBombRegex.containsMatchIn(full)) {
            return GuardDecision(
                allowed = false,
                reason = "Fork bomb pattern detected and blocked by Harness Safety Guard.",
            )
        }
        if (mkfsRegex.containsMatchIn(full)) {
            return GuardDecision(
                allowed = false,
                reason = "Filesystem format (`mkfs`) against a device node is blocked.",
            )
        }
        if (ddBlockRegex.containsMatchIn(full) || rawBlockRedirectRegex.containsMatchIn(full)) {
            return GuardDecision(
                allowed = false,
                reason = "Raw block-device write is blocked by Harness Safety Guard.",
            )
        }

        for (match in rmCommandRegex.findAll(full)) {
            val tail = match.groupValues[1]
            val tokens = tail.trim().split(Regex("""\s+"""))
            val hasRecursive = tokens.any { tok ->
                tok.startsWith("-") && (tok.contains('r') || tok.contains('R') || tok == "--recursive")
            }
            if (!hasRecursive) continue

            val targets = tokens.filterNot { it.startsWith("-") }
            for (rawTarget in targets) {
                val target = rawTarget.trim('"', '\'', ' ')
                if (isCatastrophicRmTarget(target)) {
                    return GuardDecision(
                        allowed = false,
                        reason = "Destructive recursive delete on critical path `$target` blocked by Harness Safety Guard.",
                    )
                }
            }
        }

        return GuardDecision(true)
    }

    private fun isCatastrophicRmTarget(target: String): Boolean {
        if (target.isEmpty()) return false
        val cleaned = target.replace("\"", "").replace("'", "").trim()
        val normalized = cleaned.trimEnd('/')
        if (cleaned == "/" || cleaned == "/*" || normalized.isEmpty()) return true
        val roots = setOf(
            "/sdcard",
            "/sdcard/.",
            "/sdcard/*",
            "/storage",
            "/storage/*",
            "/storage/emulated",
            "/storage/emulated/0",
            "/storage/emulated/0/.",
            "/storage/emulated/0/*",
            "/data",
            "/data/*",
            "/system",
            "/vendor",
            "~",
            "~/*",
            "~/sdcard",
            "~/sdcard/*",
            "\$HOME",
            "\$HOME/*",
            "\${HOME}",
            "\${HOME}/*",
        )
        return normalized in roots || cleaned in roots
    }

    fun evaluateWritePath(path: String, cwd: File? = null): GuardDecision {
        if (!enabled) return GuardDecision(true)
        val trimmed = path.trim()
        if (trimmed.isEmpty()) return GuardDecision(true)
        val rawFile = File(trimmed)
        val resolvedFile = if (rawFile.isAbsolute || cwd == null) rawFile else File(cwd, trimmed)
        val normalized = try {
            resolvedFile.canonicalPath
        } catch (_: Throwable) {
            resolvedFile.absolutePath
        }

        for (prefix in protectedWritePrefixes) {
            if (normalized.startsWith(prefix) || trimmed.startsWith(prefix)) {
                return GuardDecision(
                    allowed = false,
                    reason = "Write to protected system path `$trimmed` is blocked by Harness Safety Guard.",
                )
            }
        }

        val name = File(normalized).name
        if (name in protectedFilenames) {
            return GuardDecision(
                allowed = false,
                reason = "Direct overwrite of protected credential file `$name` is blocked.",
            )
        }

        return GuardDecision(true)
    }

    fun offloadIfLarge(
        outputDir: File?,
        callId: String,
        rawOutput: String,
        thresholdChars: Int = DEFAULT_OFFLOAD_THRESHOLD_CHARS,
    ): OffloadResult {
        if (rawOutput.length <= thresholdChars || outputDir == null) {
            return OffloadResult(
                offloaded = false,
                text = rawOutput,
                filePath = null,
                totalChars = rawOutput.length,
            )
        }
        return try {
            if (!outputDir.exists()) outputDir.mkdirs()
            val safeId = callId.replace(Regex("""[^a-zA-Z0-9._-]"""), "_").ifBlank { "term" }
            val outFile = File(outputDir, "$safeId.log")
            outFile.writeText(rawOutput)

            val head = rawOutput.substring(0, HEAD_PREVIEW_CHARS.coerceAtMost(rawOutput.length))
            val tailStart = (rawOutput.length - TAIL_PREVIEW_CHARS).coerceAtLeast(head.length)
            val tail = rawOutput.substring(tailStart)
            val omitted = (tailStart - head.length).coerceAtLeast(0)

            val compact = buildString {
                appendLine("[HARNESS OUTPUT OFFLOADED: ${rawOutput.length} chars ($omitted middle chars omitted)]")
                appendLine("Full log saved at: ${outFile.absolutePath}")
                appendLine("--- HEAD ---")
                appendLine(head)
                if (tail.isNotEmpty()) {
                    appendLine("\n--- TAIL (inspect ${outFile.absolutePath} for middle output) ---")
                    append(tail)
                }
            }
            OffloadResult(
                offloaded = true,
                text = compact,
                filePath = outFile.absolutePath,
                totalChars = rawOutput.length,
            )
        } catch (_: Throwable) {
            OffloadResult(
                offloaded = false,
                text = rawOutput,
                filePath = null,
                totalChars = rawOutput.length,
            )
        }
    }
}
