package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.phone.PhoneMcpServer
import io.github.dwicao.antigravity_go.runtime.CustomizationsOps
import io.github.dwicao.antigravity_go.runtime.LifecycleHooksManager
import io.github.dwicao.antigravity_go.runtime.WorkspaceOps
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
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

        // Verify gitDiff works on shadow-git workspace with modified + untracked files
        // and excludes runtime convenience symlinks like phone_storage -> /storage/emulated/0.
        runCatching {
            Files.createSymbolicLink(
                File(work, "phone_storage").toPath(),
                Paths.get("/storage/emulated/0"),
            )
        }
        mainFile.writeText("v1\nadded_line\n")
        File(work, "brand_new.kt").writeText("fun hello() {}\n")
        val diffRes = ops.gitDiff(work.absolutePath)
        assertEquals("shadow-checkpoint", diffRes["branch"])
        assertTrue((diffRes["diff"] ?: "").contains("added_line"))
        assertTrue((diffRes["diff"] ?: "").contains("brand_new.kt"))
        assertTrue((diffRes["numstat"] ?: "").contains("brand_new.kt"))
        assertFalse((diffRes["diff"] ?: "").contains("phone_storage"))
        assertFalse((diffRes["diff"] ?: "").contains("/storage/emulated/0"))
        assertFalse((diffRes["numstat"] ?: "").contains("phone_storage"))
        assertFalse((diffRes["status"] ?: "").contains("phone_storage"))

        // Verify pure file deletion in shadow-git reports removal without phantom untracked additions.
        mainFile.writeText("v1\n")
        File(work, "brand_new.kt").delete()
        val toRemove = File(work, "to_remove.kt").apply { writeText("remove_me_1\nremove_me_2\n") }
        val cp2 = ops.createCheckpoint(work.absolutePath)
        assertEquals(true, cp2["ok"])
        // Seed HEAD with toRemove included via a second shadow workspace to test clean deletion.
        val delWork = Files.createTempDirectory("agy-del-work-").toFile().apply { deleteOnExit() }
        val keepFile = File(delWork, "keep.txt").apply { writeText("stay\n") }
        val removeFile = File(delWork, "remove.txt").apply { writeText("gone1\ngone2\n") }
        ops.createCheckpoint(delWork.absolutePath)
        removeFile.delete()
        val delRes = ops.gitDiff(delWork.absolutePath)
        assertTrue((delRes["diff"] ?: "").contains("-gone1"))
        assertTrue((delRes["numstat"] ?: "").contains("0\t2\tremove.txt"))
        assertFalse((delRes["status"] ?: "").contains("keep.txt"))
        assertFalse((delRes["numstat"] ?: "").contains("keep.txt"))
        assertTrue((delRes["status"] ?: "").startsWith(" D remove.txt"))
        assertEquals("stay\n", keepFile.readText())
        toRemove.delete()
    }
}
