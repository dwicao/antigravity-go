package io.github.dwicao.antigravity_go.runtime

import android.os.Environment
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import org.json.JSONObject
import java.io.File

/**
 * Manages managed `GEMINI.md` context, `settings.json`, customizations listing, and
 * `$HOME/.gemini/config/mcp_config.json` synchronization (e.g. `phone-control` MCP).
 */
internal class CustomizationsOps(
    private val homeDir: File,
    private val workspaceDir: File,
    private val bashFile: File,
    private val tmpDir: File,
    private val settingsFile: File,
    private val atomicWriteText: (File, String) -> Unit,
) {
    private val mcpConfigFile: File get() = File(homeDir, ".gemini/config/mcp_config.json")

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

    fun listCustomizations(cwd: String?): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        val projectDir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir

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
