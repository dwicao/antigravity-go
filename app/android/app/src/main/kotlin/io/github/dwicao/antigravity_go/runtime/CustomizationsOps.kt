package io.github.dwicao.antigravity_go.runtime

import android.os.Environment
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import org.json.JSONObject
import java.io.File

/**
 * Manages `GEMINI.md`, `AGENTS.md`, `SKILL.md` agent skills, `settings.json`,
 * customizations discovery/scaffolding, and `$HOME/.gemini/config/mcp_config.json`.
 */
class CustomizationsOps(
    private val homeDir: File,
    private val workspaceDir: File,
    private val bashFile: File,
    private val tmpDir: File,
    private val settingsFile: File,
    private val atomicWriteText: (File, String) -> Unit,
) {
    private val mcpConfigFile: File get() = File(homeDir, ".gemini/config/mcp_config.json")

    data class SkillFrontmatterMeta(
        val name: String,
        val description: String,
    )

    companion object {
        fun parseSkillFrontmatter(raw: String, fallbackName: String): SkillFrontmatterMeta {
            val normalized = raw.replace("\r\n", "\n").trimStart()
            if (!normalized.startsWith("---")) {
                val firstLine = normalized.lineSequence()
                    .map { it.trim() }
                    .firstOrNull { it.isNotEmpty() && !it.startsWith("#") }
                    ?: "SKILL.md loaded"
                return SkillFrontmatterMeta(name = fallbackName, description = firstLine)
            }
            val afterOpen = normalized.indexOf('\n')
            if (afterOpen < 0) {
                return SkillFrontmatterMeta(name = fallbackName, description = "SKILL.md loaded")
            }
            val rest = normalized.substring(afterOpen + 1)
            val closeMatch = Regex("""^---\s*$""", RegexOption.MULTILINE).find(rest)
                ?: return SkillFrontmatterMeta(name = fallbackName, description = "SKILL.md loaded")
            val yamlBlock = rest.substring(0, closeMatch.range.first)

            var parsedName: String? = null
            var parsedDesc: String? = null
            for (line in yamlBlock.lineSequence()) {
                val idx = line.indexOf(':')
                if (idx <= 0) continue
                val key = line.substring(0, idx).trim().lowercase()
                var value = line.substring(idx + 1).trim()
                if ((value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
                    (value.startsWith('\'') && value.endsWith('\'') && value.length >= 2)
                ) {
                    value = value.substring(1, value.length - 1)
                }
                if (key == "name" && value.isNotEmpty()) parsedName = value
                if (key == "description" && value.isNotEmpty()) parsedDesc = value
            }
            return SkillFrontmatterMeta(
                name = parsedName ?: fallbackName,
                description = parsedDesc ?: "SKILL.md loaded",
            )
        }
    }

    fun syncManagedGeminiMd(allowStorage: Boolean) {
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
            if (v == null) {
                obj.remove(k)
            } else {
                obj.put(k, JSONObject.wrap(v))
            }
        }
        atomicWriteText(settingsFile, obj.toString(2))
    }

    /**
     * Synchronizes `$HOME/.gemini/config/mcp_config.json` with the live local
     * [PhoneControlCoordinator] HTTP MCP server when enabled, preserving user entries.
     */
    fun syncPhoneMcpRegistration() {
        try {
            val endpoint = PhoneControlCoordinator.currentMcpEndpoint()
            val root = if (mcpConfigFile.exists()) {
                runCatching { JSONObject(mcpConfigFile.readText()) }.getOrElse { JSONObject() }
            } else {
                JSONObject()
            }
            val servers = root.optJSONObject("mcpServers") ?: JSONObject()
            if (endpoint != null) {
                servers.put(
                    "phone-control",
                    JSONObject()
                        .put("disabled", false)
                        .put("serverUrl", endpoint.url)
                        .put(
                            "headers",
                            JSONObject().put("Authorization", "Bearer ${endpoint.authToken}"),
                        ),
                )
            } else {
                servers.remove("phone-control")
            }
            root.put("mcpServers", servers)
            atomicWriteText(mcpConfigFile, root.toString(2))
        } catch (_: Throwable) {}
    }

    fun createSkill(
        name: String,
        description: String,
        scope: String,
        cwd: String?,
        content: String? = null,
    ): String {
        val slug = name.trim()
            .lowercase()
            .replace(Regex("[^a-z0-9_-]+"), "-")
            .trim('-')
            .ifEmpty { "custom-skill" }
        val projectDir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val skillsRoot = if (scope.equals("Global", ignoreCase = true)) {
            File(homeDir, ".gemini/skills")
        } else {
            File(projectDir, ".agents/skills")
        }
        val skillFile = File(skillsRoot, "$slug/SKILL.md")
        skillFile.parentFile?.mkdirs()
        val body = content?.takeIf { it.isNotBlank() } ?: """
            |---
            |name: $slug
            |description: ${description.trim().ifEmpty { "Describe when and how the agent should use this skill." }}
            |---
            |
            |# $slug
            |
            |## Instructions
            |1. Inspect relevant files in the workspace first.
            |2. Follow instructions in `AGENTS.md` and `GEMINI.md`.
            |3. Verify changes before concluding.
            |""".trimMargin()
        atomicWriteText(skillFile, body)
        return skillFile.absolutePath
    }

    fun listCustomizations(cwd: String?): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        val projectDir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val seenPaths = HashSet<String>()

        fun addRuleFile(
            file: File,
            name: String,
            scope: String,
            description: String,
            includeWhenMissing: Boolean = false,
        ) {
            val canonical = runCatching { file.canonicalPath }.getOrDefault(file.absolutePath)
            if (!seenPaths.add(canonical)) return
            val exists = file.isFile
            if (!exists && !includeWhenMissing) return
            items.add(
                mapOf(
                    "kind" to "rule",
                    "name" to name,
                    "scope" to scope,
                    "path" to file.absolutePath,
                    "description" to description,
                    "enabled" to exists,
                    "content" to if (exists) runCatching { file.readText() }.getOrDefault("") else "",
                )
            )
        }

        // Global rules (GEMINI.md + AGENTS.md)
        addRuleFile(
            file = File(homeDir, ".gemini/GEMINI.md"),
            name = "Global Rules (GEMINI.md)",
            scope = "Global",
            description = "Global Antigravity instructions applied to every conversation",
            includeWhenMissing = true,
        )
        val globalAgentsCandidates = listOf(
            File(homeDir, ".agents/AGENTS.md"),
            File(homeDir, ".gemini/AGENTS.md"),
            File(homeDir, ".gemini/antigravity-cli/AGENTS.md"),
        )
        val hasAnyGlobalAgents = globalAgentsCandidates.any { it.isFile }
        addRuleFile(
            file = globalAgentsCandidates.first(),
            name = "Global Agents (AGENTS.md)",
            scope = "Global",
            description = "Cross-agent global instructions (AGENTS.md)",
            includeWhenMissing = !hasAnyGlobalAgents,
        )
        for (extraGlobalAgents in globalAgentsCandidates.drop(1)) {
            addRuleFile(
                file = extraGlobalAgents,
                name = "Global Agents (AGENTS.md)",
                scope = "Global",
                description = "Cross-agent global instructions (AGENTS.md)",
            )
        }

        // Project AGENTS.md & workspace rules
        addRuleFile(
            file = File(projectDir, "AGENTS.md"),
            name = "Project Agents (AGENTS.md)",
            scope = "Project",
            description = "Repository-level agent instructions & conventions (AGENTS.md)",
            includeWhenMissing = true,
        )
        addRuleFile(
            file = File(projectDir, "AGENTS.override.md"),
            name = "Project Agents Override (AGENTS.override.md)",
            scope = "Project",
            description = "Local override instructions (AGENTS.override.md)",
        )
        addRuleFile(
            file = File(projectDir, ".agents/AGENTS.md"),
            name = "Workspace .agents/AGENTS.md",
            scope = "Project",
            description = "Workspace agent instructions (.agents/AGENTS.md)",
        )
        addRuleFile(
            file = File(projectDir, ".gemini/AGENTS.md"),
            name = "Workspace .gemini/AGENTS.md",
            scope = "Project",
            description = "Workspace agent instructions (.gemini/AGENTS.md)",
        )

        for (rulesDir in listOf(
            File(projectDir, ".agents/rules"),
            File(projectDir, ".gemini/rules"),
        )) {
            if (rulesDir.exists() && rulesDir.isDirectory) {
                rulesDir.listFiles()?.filter { it.isFile }?.sortedBy { it.name }?.forEach { f ->
                    addRuleFile(
                        file = f,
                        name = f.name,
                        scope = "Project",
                        description = "Workspace rule",
                    )
                }
            }
        }

        // Skills (SKILL.md) across Project, Global, and Built-in directories
        val seenSkills = HashSet<String>()
        for ((scope, root) in listOf(
            "Project" to File(projectDir, ".agents/skills"),
            "Project" to File(projectDir, ".gemini/skills"),
            "Project" to File(projectDir, ".claude/skills"),
            "Global" to File(homeDir, ".gemini/antigravity-cli/skills"),
            "Global" to File(homeDir, ".gemini/skills"),
            "Global" to File(homeDir, ".agents/skills"),
            "Built-in" to File(homeDir, ".gemini/antigravity-cli/builtin/skills"),
        )) {
            if (!root.exists() || !root.isDirectory) continue
            root.listFiles()?.filter { it.isDirectory }?.sortedBy { it.name }?.forEach { dir ->
                val skillMd = File(dir, "SKILL.md")
                val canonical = runCatching { skillMd.canonicalPath }.getOrDefault(skillMd.absolutePath)
                if (!seenPaths.add(canonical)) return@forEach
                val exists = skillMd.isFile
                val rawContent = if (exists) runCatching { skillMd.readText() }.getOrDefault("") else ""
                val meta = if (exists) {
                    parseSkillFrontmatter(rawContent, dir.name)
                } else {
                    SkillFrontmatterMeta(name = dir.name, description = "Skill folder (missing SKILL.md)")
                }
                val dedupKey = "${scope.lowercase()}:${meta.name.lowercase()}"
                if (!seenSkills.add(dedupKey)) return@forEach
                items.add(
                    mapOf(
                        "kind" to "skill",
                        "name" to meta.name,
                        "scope" to scope,
                        "path" to skillMd.absolutePath,
                        "description" to meta.description,
                        "enabled" to exists,
                        "content" to rawContent,
                    )
                )
            }
        }

        // Collect MCP servers from both settings.json and ~/.gemini/config/mcp_config.json
        val seenMcp = HashSet<String>()
        fun addMcpFromObj(mcpObj: JSONObject?, scopeLabel: String) {
            if (mcpObj == null) return
            for (key in mcpObj.keys()) {
                if (!seenMcp.add(key)) continue
                val cfg = mcpObj.optJSONObject(key)
                items.add(
                    mapOf(
                        "kind" to "mcpServer",
                        "name" to key,
                        "scope" to scopeLabel,
                        "path" to (
                            cfg?.optString("command")?.takeIf { it.isNotBlank() }
                                ?: cfg?.optString("serverUrl")?.takeIf { it.isNotBlank() }
                                ?: cfg?.optString("url")?.takeIf { it.isNotBlank() }
                                ?: "configured"
                            ),
                        "description" to "Model Context Protocol server",
                        "enabled" to !(cfg?.optBoolean("disabled", false) ?: false),
                    )
                )
            }
        }

        if (mcpConfigFile.exists()) {
            runCatching {
                val cfg = JSONObject(mcpConfigFile.readText())
                addMcpFromObj(cfg.optJSONObject("mcpServers"), "Global")
            }
        }
        val settings = readSettings()
        addMcpFromObj(settings["mcpServers"] as? JSONObject, "Global")
        return items
    }
}
