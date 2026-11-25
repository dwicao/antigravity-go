package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.phone.PhoneMcpServer
import io.github.dwicao.antigravity_go.runtime.CustomizationsOps
import io.github.dwicao.antigravity_go.runtime.LifecycleHooksManager
import io.github.dwicao.antigravity_go.runtime.WorkspaceOps
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NewHarnessNativeTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun lifecycleHooksBlocksMatchingPreToolUseTargets() {
        LifecycleHooksManager.updateFromJson(
            """
            [
              {
                "id": "block-env",
                "name": "Block env",
                "phase": "preToolUse",
                "toolMatcher": "write_file",
                "pathPattern": "*.env,.env.*",
                "action": "block",
                "enabled": true,
                "reason": "Blocked env secret"
              }
            ]
            """.trimIndent()
        )
        val blocked = LifecycleHooksManager.evaluatePreToolUse("write_file", "/proj/.env.local")
        assertFalse(blocked.allowed)
        assertEquals("Blocked env secret", blocked.reason)

        val allowed = LifecycleHooksManager.evaluatePreToolUse("write_file", "/proj/Main.kt")
        assertTrue(allowed.allowed)
        LifecycleHooksManager.updateFromJson("[]")
    }

    @Test
    fun customizationsOpsAddsHttpMcpServer() {
        val home = tempFolder.newFolder("home")
        val ws = tempFolder.newFolder("ws")
        val tmp = tempFolder.newFolder("tmp")
        val ops = CustomizationsOps(
            homeDir = home,
            workspaceDir = ws,
            bashFile = File("/bin/sh"),
            tmpDir = tmp,
            settingsFile = File(home, ".gemini/antigravity-cli/settings.json"),
            atomicWriteText = { f, s ->
                f.parentFile?.mkdirs()
                f.writeText(s)
            },
        )
        val ok = ops.addHttpMcpServer("github-mcp", "https://mcp.example.com/sse", "Bearer tok123")
        assertTrue(ok)
        val cfg = File(home, ".gemini/config/mcp_config.json").readText()
        assertTrue(cfg.contains("github-mcp"))
        assertTrue(cfg.contains("https://mcp.example.com/sse"))
    }

    @Test
    fun phoneMcpServerPublishesExtendedShizukuTools() {
        val tools = PhoneMcpServer.toolDefinitions().toString()
        assertTrue(tools.contains("phone_shizuku_logcat"))
        assertTrue(tools.contains("phone_shizuku_install"))
        assertTrue(tools.contains("phone_shizuku_ui_dump"))
    }

    @Test
    fun workspaceOpsShadowGitCreatesAndRestoresSnapshotWithoutDotGit() {
        val work = tempFolder.newFolder("non_git_project")
        val tmp = tempFolder.newFolder("tmp")
        val mainFile = File(work, "hello.txt").apply { writeText("v1\n") }

        val ops = WorkspaceOps(
            workspaceDir = work,
            tmpDir = tmp,
            atomicWriteText = { f, s ->
                f.parentFile?.mkdirs()
                f.writeText(s)
            },
            runShell = { _, _ -> "" },
            runCapturedArgs = { args, cwd, extraEnv, _ ->
                val pb = ProcessBuilder(args).directory(cwd).redirectErrorStream(true)
                pb.environment().putAll(extraEnv)
                val p = pb.start()
                val out = p.inputStream.bufferedReader().readText()
                val code = p.waitFor()
                code to out
            },
        )

        val cp = ops.createCheckpoint(work.absolutePath)
        assertEquals(true, cp["ok"])
        assertEquals(true, cp["shadow"])
        val ref = cp["ref"] as String
        assertFalse(File(work, ".git").exists())

        mainFile.writeText("v2_broken\n")
        val extraFile = File(work, "unwanted.txt").apply { writeText("junk") }

        val restored = ops.restoreCheckpoint(work.absolutePath, ref)
        assertEquals(true, restored["ok"])
        assertEquals("v1\n", mainFile.readText())
        assertFalse(extraFile.exists())
    }
}
