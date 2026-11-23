package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Workspace filesystem browsing, Git diff/commit/checkpoint, and `.agy-harness` helpers
 * extracted from [RuntimeController].
 */
internal class WorkspaceOps(
    private val workspaceDir: File,
    private val tmpDir: File,
    private val atomicWriteText: (File, String) -> Unit,
    private val runShell: (command: String, cwd: String?) -> String,
    private val runCapturedArgs: (args: List<String>, cwd: File, extraEnv: Map<String, String>, timeoutSeconds: Long) -> Pair<Int, String>,
) {
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

    fun gitDiff(cwd: String?): Map<String, String> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val status = runShell("git status --short 2>&1 || true", dir.absolutePath)
        val diff = runShell("git diff 2>&1 || true", dir.absolutePath)
        val numstat = runShell("git diff --numstat 2>&1 || true", dir.absolutePath)
        val stagedNumstat = runShell("git diff --cached --numstat 2>&1 || true", dir.absolutePath)
        val branch = runShell("git rev-parse --abbrev-ref HEAD 2>/dev/null || true", dir.absolutePath).trim()
        val combinedNumstat = listOf(numstat.trim(), stagedNumstat.trim())
            .filter { it.isNotEmpty() }
            .joinToString("\n")
        return mapOf(
            "status" to status,
            "diff" to diff,
            "numstat" to combinedNumstat,
            "branch" to branch,
        )
    }

    fun gitCommitAndPush(
        cwd: String?,
        message: String,
        stageAll: Boolean,
        push: Boolean,
    ): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val safeMsg = message.trim().ifEmpty { "Update workspace changes" }
        val (_, branchRaw) = runCapturedArgs(listOf("git", "rev-parse", "--abbrev-ref", "HEAD"), dir, emptyMap(), 30)
        val branch = branchRaw.trim()
        val out = StringBuilder()
        var commitOk = true
        if (stageAll) {
            val (_, addOut) = runCapturedArgs(listOf("git", "add", "-A"), dir, emptyMap(), 30)
            if (addOut.isNotBlank()) out.appendLine(addOut.trim())
        }
        val (commitCode, commitOut) = runCapturedArgs(listOf("git", "commit", "-m", safeMsg), dir, emptyMap(), 30)
        if (commitOut.isNotBlank()) out.appendLine(commitOut.trim())
        if (commitCode != 0) {
            commitOk = commitOut.contains("nothing to commit", ignoreCase = true)
        }
        val (_, headRaw) = runCapturedArgs(listOf("git", "rev-parse", "--short", "HEAD"), dir, emptyMap(), 30)
        val headHash = headRaw.trim()
        val (_, numstat) = runCapturedArgs(listOf("git", "show", "--numstat", "--format="), dir, emptyMap(), 30)
        val (_, nameStatus) = runCapturedArgs(listOf("git", "show", "--name-status", "--format="), dir, emptyMap(), 30)
        val (_, commitDiffRaw) = runCapturedArgs(listOf("git", "show", "--format="), dir, emptyMap(), 30)
        val commitDiff = commitDiffRaw.lineSequence().take(800).joinToString("\n")
        var pushOk = !push
        if (push && commitOk) {
            val (pushCode, pushOut) = runCapturedArgs(listOf("git", "push"), dir, emptyMap(), 60)
            if (pushOut.isNotBlank()) out.appendLine(pushOut.trim())
            pushOk = pushCode == 0
        }
        return mapOf(
            "ok" to (commitOk && pushOk),
            "pushed" to (push && pushOk),
            "branch" to branch,
            "commitHash" to headHash,
            "output" to out.toString().trim(),
            "numstat" to numstat,
            "nameStatus" to nameStatus,
            "commitDiff" to commitDiff,
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
        val maxBytes = 2 * 1024 * 1024L
        val sample = ByteArray(512)
        val sampleLen = f.inputStream().use { it.read(sample) }
        if (sampleLen > 0) {
            for (i in 0 until sampleLen) {
                if (sample[i] == 0.toByte()) {
                    return "[Binary file (${f.length()} bytes) — preview not available as text]"
                }
            }
        }
        if (f.length() <= maxBytes) return f.readText()
        return f.inputStream().bufferedReader().use { reader ->
            val buf = CharArray(512 * 1024)
            val n = reader.read(buf)
            val head = if (n > 0) String(buf, 0, n) else ""
            "$head\n\n...[truncated file > 2MB: ${f.length()} bytes]..."
        }
    }

    fun createDirectory(path: String): Boolean = try {
        File(path).mkdirs()
    } catch (_: Throwable) {
        false
    }

    fun deleteWorkspaceEntry(path: String): Boolean = try {
        val f = File(path)
        if (!f.exists()) false
        else if (f.isDirectory) f.deleteRecursively() else f.delete()
    } catch (_: Throwable) {
        false
    }

    fun createCheckpoint(cwd: String?): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val (insideCode, insideOut) = runCapturedArgs(
            listOf("git", "rev-parse", "--is-inside-work-tree"),
            dir,
            emptyMap(),
            30,
        )
        if (insideCode != 0 || insideOut.trim() != "true") {
            return mapOf("ok" to false, "reason" to "Not a git repository")
        }
        val (headCode, headOut) = runCapturedArgs(
            listOf("git", "rev-parse", "--verify", "HEAD"),
            dir,
            emptyMap(),
            30,
        )
        val headSha = headOut.trim()
        if (headCode != 0 || headSha.isEmpty()) {
            return mapOf("ok" to false, "reason" to "Repository has no commits yet")
        }
        val tmpIdx = File(tmpDir, "agy-cp-${System.nanoTime()}.idx")
        return try {
            val env = mapOf("GIT_INDEX_FILE" to tmpIdx.absolutePath)
            runCapturedArgs(listOf("git", "read-tree", headSha), dir, env, 30)
            runCapturedArgs(listOf("git", "add", "-A"), dir, env, 30)
            val (treeCode, treeOut) = runCapturedArgs(listOf("git", "write-tree"), dir, env, 30)
            val treeSha = treeOut.trim()
            if (treeCode != 0 || treeSha.isEmpty()) {
                return mapOf("ok" to true, "ref" to headSha, "head" to headSha, "dirty" to false)
            }
            val (headTreeCode, headTreeOut) = runCapturedArgs(
                listOf("git", "rev-parse", "${headSha}^{tree}"),
                dir,
                emptyMap(),
                30,
            )
            if (headTreeCode == 0 && headTreeOut.trim() == treeSha) {
                return mapOf("ok" to true, "ref" to headSha, "head" to headSha, "dirty" to false)
            }
            val (commitCode, commitOut) = runCapturedArgs(
                listOf("git", "commit-tree", treeSha, "-p", headSha, "-m", "agy-checkpoint"),
                dir,
                emptyMap(),
                30,
            )
            val commitSha = commitOut.trim()
            val ref = if (commitCode == 0 && commitSha.isNotEmpty()) commitSha else headSha
            mapOf(
                "ok" to true,
                "ref" to ref,
                "head" to headSha,
                "dirty" to (ref != headSha),
            )
        } finally {
            runCatching { if (tmpIdx.exists()) tmpIdx.delete() }
        }
    }

    fun restoreCheckpoint(cwd: String?, ref: String): Map<String, Any?> {
        val cleanRef = ref.trim()
        if (!cleanRef.matches(Regex("""^[0-9a-fA-F]{7,64}$"""))) {
            return mapOf("ok" to false, "message" to "Invalid checkpoint ref")
        }
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val (verifyCode, verifyOut) = runCapturedArgs(
            listOf("git", "rev-parse", "--verify", "$cleanRef^{commit}"),
            dir,
            emptyMap(),
            30,
        )
        if (verifyCode != 0 || verifyOut.trim().isEmpty()) {
            return mapOf("ok" to false, "message" to "Checkpoint commit no longer exists")
        }

        val (_, subjectOut) = runCapturedArgs(
            listOf("git", "log", "-1", "--format=%s", cleanRef),
            dir,
            emptyMap(),
            30,
        )
        val isSnapshot = subjectOut.trim() == "agy-checkpoint"

        if (isSnapshot) {
            val (parentCode, parentOut) = runCapturedArgs(
                listOf("git", "rev-parse", "--verify", "$cleanRef^1"),
                dir,
                emptyMap(),
                30,
            )
            val baseHead = if (parentCode == 0 && parentOut.trim().isNotEmpty()) {
                parentOut.trim()
            } else {
                cleanRef
            }
            val (resetCode, resetOut) = runCapturedArgs(
                listOf("git", "reset", "--hard", baseHead),
                dir,
                emptyMap(),
                30,
            )
            if (resetCode != 0) {
                return mapOf("ok" to false, "ref" to cleanRef, "output" to resetOut.trim())
            }
            val (readTreeCode, readTreeOut) = runCapturedArgs(
                listOf("git", "read-tree", "--reset", "-u", cleanRef),
                dir,
                emptyMap(),
                30,
            )
            if (readTreeCode != 0) {
                return mapOf("ok" to false, "ref" to cleanRef, "output" to readTreeOut.trim())
            }
            val (_, snapFilesRaw) = runCapturedArgs(
                listOf("git", "ls-tree", "-r", "--name-only", cleanRef),
                dir,
                emptyMap(),
                30,
            )
            val snapFiles = snapFilesRaw.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
            val (_, untrackedRaw) = runCapturedArgs(
                listOf("git", "ls-files", "--others", "--exclude-standard"),
                dir,
                emptyMap(),
                30,
            )
            for (rel in untrackedRaw.lineSequence()) {
                val p = rel.trim()
                if (p.isNotEmpty() && p !in snapFiles) {
                    runCatching { File(dir, p).delete() }
                }
            }
            runCapturedArgs(listOf("git", "reset", "--mixed", baseHead), dir, emptyMap(), 30)
            return mapOf("ok" to true, "ref" to cleanRef, "output" to "Restored snapshot $cleanRef")
        }

        val (resetCode, resetOut) = runCapturedArgs(
            listOf("git", "reset", "--hard", cleanRef),
            dir,
            emptyMap(),
            30,
        )
        runCapturedArgs(listOf("git", "clean", "-fd"), dir, emptyMap(), 30)
        return mapOf(
            "ok" to (resetCode == 0),
            "ref" to cleanRef,
            "output" to resetOut.trim(),
        )
    }

    fun initHarnessFiles(
        cwd: String?,
        featureJson: String,
        progressTxt: String,
    ): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val harnessDir = File(dir, ".agy-harness")
        return try {
            harnessDir.mkdirs()
            val featFile = File(harnessDir, "feature_list.json")
            val progFile = File(harnessDir, "progress.txt")
            if (!featFile.exists() && featureJson.isNotBlank()) {
                atomicWriteText(featFile, featureJson)
            }
            if (!progFile.exists() && progressTxt.isNotBlank()) {
                atomicWriteText(progFile, progressTxt)
            }
            readHarnessFiles(dir.absolutePath)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to (t.message ?: t.toString()))
        }
    }

    fun readHarnessFiles(cwd: String?): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        val harnessDir = File(dir, ".agy-harness")
        val featFile = File(harnessDir, "feature_list.json")
        val progFile = File(harnessDir, "progress.txt")
        val pubspec = File(dir, "pubspec.yaml")
        val isFlutter = pubspec.exists() && try {
            pubspec.readText().contains("flutter:")
        } catch (_: Throwable) {
            false
        }
        val rootGradlew = File(dir, "gradlew").exists()
        val appGradlew = File(dir, "app/gradlew").exists()
        val gradlewCommand = when {
            rootGradlew -> "./gradlew test"
            appGradlew -> "./app/gradlew test"
            else -> null
        }
        return mapOf(
            "ok" to true,
            "workspace" to dir.absolutePath,
            "initialized" to (featFile.exists() || progFile.exists()),
            "featureList" to if (featFile.exists()) featFile.readText() else "",
            "progressLog" to if (progFile.exists()) progFile.readText() else "",
            "hasPubspec" to pubspec.exists(),
            "isFlutter" to isFlutter,
            "hasPackageJson" to File(dir, "package.json").exists(),
            "hasPyproject" to (File(dir, "pyproject.toml").exists() || File(dir, "pytest.ini").exists()),
            "hasCargoToml" to File(dir, "Cargo.toml").exists(),
            "hasGradlew" to (rootGradlew || appGradlew),
            "gradlewCommand" to gradlewCommand,
        )
    }

    fun writeHarnessFile(
        cwd: String?,
        relativeName: String,
        content: String,
    ): Boolean {
        val allowed = setOf("feature_list.json", "progress.txt")
        if (relativeName !in allowed) return false
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        return try {
            val target = File(File(dir, ".agy-harness"), relativeName)
            atomicWriteText(target, content)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
