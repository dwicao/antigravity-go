package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Evaluates user-configured `PreToolUse` and `PostToolUse` lifecycle hooks
 * synchronized from Flutter's Harness settings.
 */
object LifecycleHooksManager {
    data class HookRule(
        val id: String,
        val name: String,
        val phase: String,
        val toolMatcher: String,
        val pathPattern: String,
        val action: String,
        val enabled: Boolean,
        val command: String,
        val reason: String,
    ) {
        fun matchesTool(tool: String): Boolean {
            val m = toolMatcher.trim().lowercase()
            return m == "*" || m.isEmpty() || m == tool.trim().lowercase()
        }

        fun matchesTarget(target: String): Boolean {
            val raw = pathPattern.trim()
            if (raw.isEmpty() || raw == "*") return true
            val normalized = target.replace('\\', '/').lowercase()
            val fileName = normalized.substringAfterLast('/')
            for (part in raw.split(',')) {
                val tok = part.trim().lowercase()
                if (tok.isEmpty()) continue
                if (globMatches(tok, normalized) || globMatches(tok, fileName)) {
                    return true
                }
                if (!tok.contains('*') && normalized.contains(tok)) {
                    return true
                }
            }
            return false
        }

        private fun globMatches(pattern: String, value: String): Boolean {
            val sb = StringBuilder("^")
            for (ch in pattern) {
                when (ch) {
                    '*' -> sb.append(".*")
                    '.', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|', '\\' -> {
                        sb.append('\\').append(ch)
                    }
                    else -> sb.append(ch)
                }
            }
            sb.append('$')
            return Regex(sb.toString(), RegexOption.IGNORE_CASE).matches(value)
        }
    }

    @Volatile
    private var rules: List<HookRule> = emptyList()

    fun updateFromJson(rawJson: String) {
        if (rawJson.isBlank()) {
            rules = emptyList()
            return
        }
        val parsed = mutableListOf<HookRule>()
        runCatching {
            val arr = JSONArray(rawJson)
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val id = obj.optString("id", "").trim()
                if (id.isEmpty()) continue
                parsed.add(
                    HookRule(
                        id = id,
                        name = obj.optString("name", "Custom Hook"),
                        phase = obj.optString("phase", "preToolUse"),
                        toolMatcher = obj.optString("toolMatcher", "*"),
                        pathPattern = obj.optString("pathPattern", "*"),
                        action = obj.optString("action", "block"),
                        enabled = obj.optBoolean("enabled", true),
                        command = obj.optString("command", ""),
                        reason = obj.optString("reason", ""),
                    )
                )
            }
        }
        rules = parsed
    }

    fun evaluatePreToolUse(tool: String, target: String): CommandSafetyGuard.GuardDecision {
        val current = rules
        for (rule in current) {
            if (!rule.enabled || rule.phase != "preToolUse" || rule.action != "block") {
                continue
            }
            if (rule.matchesTool(tool) && rule.matchesTarget(target)) {
                val msg = rule.reason.ifBlank {
                    "Blocked by PreToolUse lifecycle hook \"${rule.name}\"."
                }
                return CommandSafetyGuard.GuardDecision(allowed = false, reason = msg)
            }
        }
        return CommandSafetyGuard.GuardDecision(allowed = true)
    }

    fun runPostToolUse(
        tool: String,
        filePath: String,
        cwd: File,
        env: Map<String, String>,
        log: (String) -> Unit,
    ) {
        val current = rules
        val quotedPath = "'${filePath.replace("'", "'\\''")}'"
        for (rule in current) {
            if (!rule.enabled || rule.phase != "postToolUse" || rule.action != "command") {
                continue
            }
            if (rule.command.isBlank() || !rule.matchesTool(tool) || !rule.matchesTarget(filePath)) {
                continue
            }
            val cmd = rule.command.replace("{file}", quotedPath)
            runCatching {
                val shell = env["SHELL"] ?: "/system/bin/sh"
                val pb = ProcessBuilder(shell, "-c", cmd).apply {
                    directory(cwd)
                    environment().putAll(env)
                    redirectErrorStream(true)
                }
                val proc = pb.start()
                val out = proc.inputStream.bufferedReader().readText().trim()
                if (!proc.waitFor(12, TimeUnit.SECONDS)) {
                    proc.destroyForcibly()
                    log("[PostToolUse:${rule.id}] timed out after 12s")
                } else {
                    log("[PostToolUse:${rule.id}] exit=${proc.exitValue()} ${out.take(240)}")
                }
            }.onFailure { e ->
                log("[PostToolUse:${rule.id}] failed: ${e.message}")
            }
        }
    }
}
