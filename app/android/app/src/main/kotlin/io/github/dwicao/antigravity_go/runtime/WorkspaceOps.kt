package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

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

    private fun hasStandardGitRoot(dir: File): Boolean {
        var cur: File? = dir
        var depth = 0
        while (cur != null && depth < 16) {
            if (File(cur, ".git").exists()) return true
            cur = cur.parentFile
            depth++
        }
        return false
    }

    private fun parseBranchFromStatusHeader(headerLine: String): String {
        val body = headerLine.removePrefix("## ").trim()
        if (body.startsWith("No commits yet on ")) {
            return body.removePrefix("No commits yet on ").trim()
        }
        if (body.startsWith("Initial commit on ")) {
            return body.removePrefix("Initial commit on ").trim()
        }
        if (body.startsWith("HEAD (no branch)")) return "HEAD"
        val dotsIdx = body.indexOf("...")
        if (dotsIdx >= 0) return body.substring(0, dotsIdx).trim()
        val bracketIdx = body.indexOf(" [")
        if (bracketIdx >= 0) return body.substring(0, bracketIdx).trim()
        return body
    }

    fun gitDiff(cwd: String?): Map<String, String> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (!dir.exists() || !dir.isDirectory) {
            return mapOf(
                "status" to "",
                "diff" to "",
                "numstat" to "",
                "branch" to "",
            )
        }
        val shadowCandidate = shadowGitDir(dir).takeIf { it.exists() }
        if (!hasStandardGitRoot(dir) && shadowCandidate == null) {
            return mapOf(
                "status" to "",
                "diff" to "",
                "numstat" to "",
                "branch" to "",
            )
        }

        val (insideCode, insideOut) = runCapturedArgs(
            gitCmd(null, "rev-parse", "--is-inside-work-tree"),
            dir,
            emptyMap(),
            15,
        )
        val useStandard = insideCode == 0 && insideOut.trim() == "true"
        val shadowDir = if (!useStandard) shadowCandidate else null

        if (!useStandard && shadowDir == null) {
            return mapOf(
                "status" to "",
                "diff" to "",
                "numstat" to "",
                "branch" to "",
            )
        }

        val workEnv = if (shadowDir != null) mapOf("GIT_WORK_TREE" to dir.absolutePath) else emptyMap()
        if (shadowDir != null) {
            ensureShadowExclude(shadowDir)
            syncShadowIndexIfNeeded(dir, shadowDir)
        }
        val pathFilterArgs = shadowExcludeArgs.toTypedArray()
        val (statusCode, statusWithBranchRaw) = runCapturedArgs(
            gitCmd(shadowDir, "status", "--short", "--branch", "-uall", *pathFilterArgs),
            dir,
            workEnv,
            20,
        )
        if (statusCode != 0) {
            val fallbackBranch = if (shadowDir != null) {
                "shadow-checkpoint"
            } else {
                val (_, b) = runCapturedArgs(gitCmd(null, "rev-parse", "--abbrev-ref", "HEAD"), dir, emptyMap(), 15)
                b.trim()
            }
            return mapOf(
                "status" to "",
                "diff" to "",
                "numstat" to "",
                "branch" to fallbackBranch,
                "statusOk" to "false",
            )
        }
        val rawStatusLines = statusWithBranchRaw.lines()
        val firstLine = rawStatusLines.firstOrNull()?.trim() ?: ""
        val hasBranchHeader = firstLine.startsWith("## ")
        val statusLines = if (hasBranchHeader) rawStatusLines.drop(1) else rawStatusLines
        // Preserve leading `' '` in XY porcelain codes like `" D file"` / `" M file"`.
        val statusRaw = statusLines.dropWhile { it.isBlank() }.joinToString("\n").trimEnd()
        val branch = if (shadowDir != null) {
            "shadow-checkpoint"
        } else if (hasBranchHeader) {
            parseBranchFromStatusHeader(firstLine)
        } else {
            val (_, b) = runCapturedArgs(gitCmd(null, "rev-parse", "--abbrev-ref", "HEAD"), dir, emptyMap(), 15)
            b.trim()
        }

        // Fast path: clean repository has nothing to diff or numstat.
        if (statusRaw.isEmpty()) {
            return mapOf(
                "status" to "",
                "diff" to "",
                "numstat" to "",
                "branch" to branch,
                "statusOk" to "true",
            )
        }

        val hasTrackedChanges = statusRaw.lineSequence().any { line ->
            val trimmed = line.trimEnd()
            trimmed.isNotEmpty() && !trimmed.startsWith("?? ")
        }
        val hasHead = if (!hasBranchHeader) {
            val (hasHeadCode, _) = runCapturedArgs(
                gitCmd(shadowDir, "rev-parse", "--verify", "HEAD"),
                dir,
                workEnv,
                15,
            )
            hasHeadCode == 0
        } else {
            val headerBody = firstLine.removePrefix("## ").trim()
            !headerBody.startsWith("No commits yet on ") &&
                !headerBody.startsWith("Initial commit on ")
        }

        val diffText: String
        val numstatText: String
        if (!hasTrackedChanges) {
            diffText = ""
            numstatText = ""
        } else if (shadowDir != null) {
            val (_, d) = runCapturedArgs(
                if (hasHead) {
                    gitCmd(shadowDir, "diff", "HEAD", *pathFilterArgs)
                } else {
                    gitCmd(shadowDir, "diff", *pathFilterArgs)
                },
                dir,
                workEnv,
                25,
            )
            val (_, n) = runCapturedArgs(
                if (hasHead) {
                    gitCmd(shadowDir, "diff", "--numstat", "HEAD", *pathFilterArgs)
                } else {
                    gitCmd(shadowDir, "diff", "--numstat", *pathFilterArgs)
                },
                dir,
                workEnv,
                25,
            )
            diffText = d
            numstatText = n
        } else if (hasHead) {
            val (_, d) = runCapturedArgs(gitCmd(null, "diff", "HEAD", *pathFilterArgs), dir, emptyMap(), 25)
            val (_, n) = runCapturedArgs(gitCmd(null, "diff", "--numstat", "HEAD", *pathFilterArgs), dir, emptyMap(), 25)
            diffText = d
            numstatText = n
        } else {
            val (_, d1) = runCapturedArgs(gitCmd(null, "diff", *pathFilterArgs), dir, emptyMap(), 25)
            val (_, d2) = runCapturedArgs(gitCmd(null, "diff", "--cached", *pathFilterArgs), dir, emptyMap(), 25)
            val (_, n1) = runCapturedArgs(gitCmd(null, "diff", "--numstat", *pathFilterArgs), dir, emptyMap(), 25)
            val (_, n2) = runCapturedArgs(gitCmd(null, "diff", "--cached", "--numstat", *pathFilterArgs), dir, emptyMap(), 25)
            diffText = listOf(d1.trim(), d2.trim()).filter { it.isNotEmpty() }.joinToString("\n")
            numstatText = listOf(n1.trim(), n2.trim()).filter { it.isNotEmpty() }.joinToString("\n")
        }

        // Synthesize GitHub-style unified diffs & numstat for untracked (`??`) text files.
        val extraDiffs = StringBuilder()
        val extraNumstat = StringBuilder()
        for (line in statusRaw.lineSequence()) {
            if (!line.startsWith("?? ")) continue
            var rel = line.substring(3).trim()
            if (rel.startsWith("\"") && rel.endsWith("\"") && rel.length >= 2) {
                rel = rel.substring(1, rel.length - 1)
            }
            if (rel.isEmpty() || rel.endsWith("/") || isIgnoredRuntimeLink(rel)) continue
            val f = File(dir, rel)
            if (runCatching { Files.isSymbolicLink(f.toPath()) }.getOrDefault(false)) continue
            if (!f.isFile || f.length() > 64 * 1024) continue
            val sample = ByteArray(512)
            val n = runCatching { f.inputStream().use { it.read(sample) } }.getOrDefault(0)
            var isBinary = false
            for (i in 0 until n) {
                if (sample[i] == 0.toByte()) {
                    isBinary = true
                    break
                }
            }
            if (isBinary) continue
            val contentLines = runCatching { f.readLines() }.getOrDefault(emptyList())
            val shownLines = contentLines.take(400)
            extraNumstat.append(contentLines.size).append("\t0\t").append(rel).append("\n")
            extraDiffs.append("diff --git a/").append(rel).append(" b/").append(rel).append("\n")
            extraDiffs.append("new file mode 100644\n")
            extraDiffs.append("--- /dev/null\n")
            extraDiffs.append("+++ b/").append(rel).append("\n")
            extraDiffs.append("@@ -0,0 +1,").append(shownLines.size).append(" @@\n")
            for (cl in shownLines) {
                extraDiffs.append("+").append(cl).append("\n")
            }
            if (contentLines.size > 400) {
                extraDiffs.append("... (truncated ${contentLines.size - 400} lines)\n")
            }
        }

        val combinedDiff = listOf(diffText.trim(), extraDiffs.toString().trim())
            .filter { it.isNotEmpty() }
            .joinToString("\n")
        val maxDiffChars = 512 * 1024
        val boundedDiff = if (combinedDiff.length > maxDiffChars) {
            val cut = combinedDiff.lastIndexOf('\n', maxDiffChars).let { if (it > 0) it else maxDiffChars }
            combinedDiff.substring(0, cut) + "\n... (diff output truncated at 512KB for responsiveness)"
        } else {
            combinedDiff
        }
        val combinedNumstat = listOf(numstatText.trim(), extraNumstat.toString().trim())
            .filter { it.isNotEmpty() }
            .joinToString("\n")

        return mapOf(
            "status" to statusRaw,
            "diff" to boundedDiff,
            "numstat" to combinedNumstat,
            "branch" to branch,
            "statusOk" to "true",
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
        val (_, branchRaw) = runCapturedArgs(gitCmd(null, "rev-parse", "--abbrev-ref", "HEAD"), dir, emptyMap(), 30)
        val branch = branchRaw.trim()
        val out = StringBuilder()
        var commitOk = true
        if (stageAll) {
            val (_, addOut) = runCapturedArgs(gitCmd(null, "add", "-A"), dir, emptyMap(), 30)
            if (addOut.isNotBlank()) out.appendLine(addOut.trim())
        }
        val (commitCode, commitOut) = runCapturedArgs(gitCmd(null, "commit", "-m", safeMsg), dir, emptyMap(), 30)
        if (commitOut.isNotBlank()) out.appendLine(commitOut.trim())
        if (commitCode != 0) {
            commitOk = commitOut.contains("nothing to commit", ignoreCase = true)
        }
        val (_, headRaw) = runCapturedArgs(gitCmd(null, "rev-parse", "--short", "HEAD"), dir, emptyMap(), 30)
        val headHash = headRaw.trim()
        val (_, numstat) = runCapturedArgs(gitCmd(null, "show", "--numstat", "--format="), dir, emptyMap(), 30)
        val (_, nameStatus) = runCapturedArgs(gitCmd(null, "show", "--name-status", "--format="), dir, emptyMap(), 30)
        val (_, commitDiffRaw) = runCapturedArgs(gitCmd(null, "show", "--format="), dir, emptyMap(), 30)
        val commitDiff = commitDiffRaw.lineSequence().take(800).joinToString("\n")
        var pushOk = !push
        if (push && commitOk) {
            val (pushCode, pushOut) = runCapturedArgs(gitCmd(null, "push"), dir, emptyMap(), 60)
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
            .asSequence()
            .sortedWith(compareBy<File>({ !it.isDirectory }, { it.name.lowercase() }))
            .take(600)
            .map { f ->
                mapOf(
                    "name" to f.name,
                    "path" to f.absolutePath,
                    "type" to if (f.isDirectory) "dir" else "file",
                    "size" to if (f.isDirectory) "folder" else "${f.length()} B",
                )
            }
            .toList()
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

    private val ignoredRuntimeLinks = setOf("phone_storage", "sdcard")
    private val shadowExcludeArgs = listOf("--", ".", ":(exclude)phone_storage", ":(exclude)sdcard")

    private fun isIgnoredRuntimeLink(relPath: String): Boolean {
        val clean = relPath.trim().trimStart('/').removeSuffix("/")
        return clean in ignoredRuntimeLinks
    }

    private fun ensureShadowExclude(shadowDir: File) {
        runCatching {
            val infoDir = File(shadowDir, "info").apply { mkdirs() }
            File(infoDir, "exclude").writeText(
                ".git/\n.gradle/\nbuild/\nnode_modules/\n.dart_tool/\n.agy-harness/\nphone_storage\nsdcard\n",
            )
        }
    }

    private fun shadowGitDir(workDir: File): File {
        val canonical = runCatching { workDir.canonicalPath }.getOrElse { workDir.absolutePath }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
            .take(20)
        val root = File(tmpDir.parentFile ?: tmpDir, "shadow_git")
        return File(root, digest)
    }

    private fun gitCmd(shadowDir: File?, vararg args: String): List<String> {
        return if (shadowDir != null) {
            listOf("git", "-c", "safe.directory=*", "--git-dir=${shadowDir.absolutePath}") + args.toList()
        } else {
            listOf("git", "-c", "safe.directory=*") + args.toList()
        }
    }

    private fun syncShadowIndexIfNeeded(workDir: File, shadowDir: File) {
        val indexFile = File(shadowDir, "index")
        if (indexFile.exists()) return
        runCapturedArgs(gitCmd(shadowDir, "config", "core.bare", "false"), workDir, emptyMap(), 15)
        val (headCode, _) = runCapturedArgs(
            gitCmd(shadowDir, "rev-parse", "--verify", "HEAD"),
            workDir,
            emptyMap(),
            15,
        )
        if (headCode == 0) {
            val env = mapOf("GIT_WORK_TREE" to workDir.absolutePath)
            runCapturedArgs(gitCmd(shadowDir, "read-tree", "HEAD"), workDir, env, 30)
        }
    }

    private fun ensureShadowGitInitialized(workDir: File, shadowDir: File): String? {
        if (!shadowDir.exists()) {
            shadowDir.mkdirs()
            val (initCode, _) = runCapturedArgs(
                gitCmd(null, "init", "--bare", shadowDir.absolutePath),
                workDir,
                emptyMap(),
                30,
            )
            if (initCode != 0) return null
            ensureShadowExclude(shadowDir)
            runCapturedArgs(gitCmd(shadowDir, "config", "core.bare", "false"), workDir, emptyMap(), 15)
            runCapturedArgs(
                gitCmd(shadowDir, "config", "user.name", "Antigravity"),
                workDir,
                emptyMap(),
                15,
            )
            runCapturedArgs(
                gitCmd(shadowDir, "config", "user.email", "harness@antigravity.local"),
                workDir,
                emptyMap(),
                15,
            )
        } else {
            ensureShadowExclude(shadowDir)
        }
        val (headCode, headOut) = runCapturedArgs(
            gitCmd(shadowDir, "rev-parse", "--verify", "HEAD"),
            workDir,
            emptyMap(),
            30,
        )
        if (headCode == 0 && headOut.trim().isNotEmpty()) {
            syncShadowIndexIfNeeded(workDir, shadowDir)
            return headOut.trim()
        }
        // Seed initial shadow commit so subsequent turns have a valid parent.
        val tmpIdx = File(tmpDir, "agy-shadow-init-${System.nanoTime()}.idx")
        return try {
            val env = mapOf(
                "GIT_INDEX_FILE" to tmpIdx.absolutePath,
                "GIT_WORK_TREE" to workDir.absolutePath,
            )
            val addArgs = shadowExcludeArgs.toTypedArray()
            runCapturedArgs(gitCmd(shadowDir, "add", "-A", *addArgs), workDir, env, 30)
            val (treeCode, treeOut) = runCapturedArgs(gitCmd(shadowDir, "write-tree"), workDir, env, 30)
            val treeSha = treeOut.trim()
            if (treeCode != 0 || treeSha.isEmpty()) return null
            val (commitCode, commitOut) = runCapturedArgs(
                gitCmd(shadowDir, "commit-tree", treeSha, "-m", "agy-shadow-init"),
                workDir,
                emptyMap(),
                30,
            )
            val sha = commitOut.trim()
            if (commitCode == 0 && sha.isNotEmpty()) {
                runCapturedArgs(gitCmd(shadowDir, "update-ref", "HEAD", sha), workDir, emptyMap(), 15)
                syncShadowIndexIfNeeded(workDir, shadowDir)
                sha
            } else {
                null
            }
        } finally {
            runCatching { if (tmpIdx.exists()) tmpIdx.delete() }
        }
    }

    fun createCheckpoint(cwd: String?): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (!dir.exists() || !dir.isDirectory) {
            return mapOf("ok" to false, "reason" to "Workspace directory does not exist")
        }
        val (insideCode, insideOut) = runCapturedArgs(
            gitCmd(null, "rev-parse", "--is-inside-work-tree"),
            dir,
            emptyMap(),
            30,
        )
        val useShadow = insideCode != 0 || insideOut.trim() != "true"
        val shadowDir = if (useShadow) shadowGitDir(dir) else null

        val headSha = if (shadowDir != null) {
            ensureShadowGitInitialized(dir, shadowDir)
                ?: return mapOf("ok" to false, "reason" to "Failed to initialize shadow git")
        } else {
            val (headCode, headOut) = runCapturedArgs(
                gitCmd(null, "rev-parse", "--verify", "HEAD"),
                dir,
                emptyMap(),
                30,
            )
            val sha = headOut.trim()
            if (headCode != 0 || sha.isEmpty()) {
                return mapOf("ok" to false, "reason" to "Repository has no commits yet")
            }
            // Fast path: clean standard Git repo needs no index/add/write-tree work.
            val (stCode, stOut) = runCapturedArgs(
                gitCmd(null, "status", "--porcelain", "--untracked-files=normal"),
                dir,
                emptyMap(),
                15,
            )
            if (stCode == 0 && stOut.isBlank()) {
                return mapOf("ok" to true, "ref" to sha, "head" to sha, "dirty" to false, "shadow" to false)
            }
            sha
        }

        val tmpIdx = File(tmpDir, "agy-cp-${System.nanoTime()}.idx")
        return try {
            val env = buildMap {
                put("GIT_INDEX_FILE", tmpIdx.absolutePath)
                if (shadowDir != null) {
                    put("GIT_WORK_TREE", dir.absolutePath)
                }
            }
            val addArgs = shadowExcludeArgs.toTypedArray()
            runCapturedArgs(gitCmd(shadowDir, "read-tree", headSha), dir, env, 30)
            runCapturedArgs(gitCmd(shadowDir, "add", "-A", *addArgs), dir, env, 30)
            if (shadowDir != null) {
                runCapturedArgs(
                    gitCmd(shadowDir, "rm", "-r", "--cached", "--ignore-unmatch", "phone_storage", "sdcard"),
                    dir,
                    env,
                    15,
                )
            }
            val (treeCode, treeOut) = runCapturedArgs(gitCmd(shadowDir, "write-tree"), dir, env, 30)
            val treeSha = treeOut.trim()
            if (treeCode != 0 || treeSha.isEmpty()) {
                return mapOf("ok" to true, "ref" to headSha, "head" to headSha, "dirty" to false, "shadow" to useShadow)
            }
            val (headTreeCode, headTreeOut) = runCapturedArgs(
                gitCmd(shadowDir, "rev-parse", "${headSha}^{tree}"),
                dir,
                emptyMap(),
                30,
            )
            if (headTreeCode == 0 && headTreeOut.trim() == treeSha) {
                return mapOf("ok" to true, "ref" to headSha, "head" to headSha, "dirty" to false, "shadow" to useShadow)
            }
            val (commitCode, commitOut) = runCapturedArgs(
                gitCmd(shadowDir, "commit-tree", treeSha, "-p", headSha, "-m", "agy-checkpoint"),
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
                "shadow" to useShadow,
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
        val (insideCode, insideOut) = runCapturedArgs(
            gitCmd(null, "rev-parse", "--is-inside-work-tree"),
            dir,
            emptyMap(),
            30,
        )
        val useStandard = insideCode == 0 && insideOut.trim() == "true"
        val shadowDir = if (!useStandard) shadowGitDir(dir).takeIf { it.exists() } else null
        if (!useStandard && shadowDir == null) {
            return mapOf("ok" to false, "message" to "No git or shadow git snapshot found")
        }

        val (verifyCode, verifyOut) = runCapturedArgs(
            gitCmd(shadowDir, "rev-parse", "--verify", "$cleanRef^{commit}"),
            dir,
            emptyMap(),
            30,
        )
        if (verifyCode != 0 || verifyOut.trim().isEmpty()) {
            return mapOf("ok" to false, "message" to "Checkpoint commit no longer exists")
        }

        val (_, subjectOut) = runCapturedArgs(
            gitCmd(shadowDir, "log", "-1", "--format=%s", cleanRef),
            dir,
            emptyMap(),
            30,
        )
        val isSnapshot = subjectOut.trim() == "agy-checkpoint" || subjectOut.trim() == "agy-shadow-init"

        if (isSnapshot) {
            val env = if (shadowDir != null) mapOf("GIT_WORK_TREE" to dir.absolutePath) else emptyMap()
            val (parentCode, parentOut) = runCapturedArgs(
                gitCmd(shadowDir, "rev-parse", "--verify", "$cleanRef^1"),
                dir,
                emptyMap(),
                30,
            )
            val baseHead = if (parentCode == 0 && parentOut.trim().isNotEmpty()) {
                parentOut.trim()
            } else {
                cleanRef
            }
            if (shadowDir == null) {
                val (resetCode, resetOut) = runCapturedArgs(
                    gitCmd(null, "reset", "--hard", baseHead),
                    dir,
                    emptyMap(),
                    30,
                )
                if (resetCode != 0) {
                    return mapOf("ok" to false, "ref" to cleanRef, "output" to resetOut.trim())
                }
            } else {
                ensureShadowExclude(shadowDir)
            }
            val (readTreeCode, readTreeOut) = runCapturedArgs(
                gitCmd(shadowDir, "read-tree", "--reset", "-u", cleanRef),
                dir,
                env,
                30,
            )
            if (readTreeCode != 0) {
                return mapOf("ok" to false, "ref" to cleanRef, "output" to readTreeOut.trim())
            }
            val (_, snapFilesRaw) = runCapturedArgs(
                gitCmd(shadowDir, "ls-tree", "-r", "--name-only", cleanRef),
                dir,
                env,
                30,
            )
            val snapFiles = snapFilesRaw.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
            val (_, untrackedRaw) = runCapturedArgs(
                gitCmd(shadowDir, "ls-files", "--others", "--exclude-standard"),
                dir,
                env,
                30,
            )
            for (rel in untrackedRaw.lineSequence()) {
                val p = rel.trim()
                if (p.isNotEmpty() && p !in snapFiles && !isIgnoredRuntimeLink(p)) {
                    runCatching { File(dir, p).delete() }
                }
            }
            if (shadowDir == null) {
                runCapturedArgs(gitCmd(null, "reset", "--mixed", baseHead), dir, emptyMap(), 30)
            } else {
                runCapturedArgs(gitCmd(shadowDir, "update-ref", "HEAD", cleanRef), dir, emptyMap(), 15)
            }
            return mapOf(
                "ok" to true,
                "ref" to cleanRef,
                "shadow" to (shadowDir != null),
                "output" to "Restored snapshot $cleanRef",
            )
        }

        val (resetCode, resetOut) = runCapturedArgs(
            gitCmd(null, "reset", "--hard", cleanRef),
            dir,
            emptyMap(),
            30,
        )
        runCapturedArgs(gitCmd(null, "clean", "-fd"), dir, emptyMap(), 30)
        return mapOf(
            "ok" to (resetCode == 0),
            "ref" to cleanRef,
            "output" to resetOut.trim(),
        )
    }

    fun revertPatch(cwd: String?, patchText: String): Map<String, Any?> {
        val dir = if (!cwd.isNullOrBlank()) File(cwd) else workspaceDir
        if (patchText.isBlank()) {
            return mapOf("ok" to false, "message" to "Empty patch")
        }
        val tmpPatch = File(tmpDir, "agy-revert-${System.nanoTime()}.patch")
        return try {
            tmpPatch.writeText(patchText)
            val (code, out) = runCapturedArgs(
                gitCmd(null, "apply", "-R", "--unidiff-zero", tmpPatch.absolutePath),
                dir,
                emptyMap(),
                30,
            )
            mapOf(
                "ok" to (code == 0),
                "output" to out.trim(),
            )
        } finally {
            runCatching { if (tmpPatch.exists()) tmpPatch.delete() }
        }
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
