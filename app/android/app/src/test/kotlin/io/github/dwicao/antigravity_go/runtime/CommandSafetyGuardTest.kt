package io.github.dwicao.antigravity_go.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.io.path.createTempDirectory

class CommandSafetyGuardTest {

    @Test
    fun allowsNormalDeveloperCommands() {
        assertTrue(CommandSafetyGuard.evaluateCommand("flutter test").allowed)
        assertTrue(CommandSafetyGuard.evaluateCommand("rm -rf build/app/outputs").allowed)
        assertTrue(CommandSafetyGuard.evaluateCommand("git diff --stat").allowed)
    }

    @Test
    fun blocksCatastrophicCommands() {
        assertFalse(CommandSafetyGuard.evaluateCommand("rm -rf /").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("rm -fr /sdcard").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("rm -rf /sdcard/*").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("busybox rm -rf /sdcard").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("echo \$(rm -rf /)").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("rm -rf /storage/emulated/0/").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("mkfs.ext4 /dev/sda1").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand("dd if=/dev/zero of=\"/dev/mmcblk0\"").allowed)
        assertFalse(CommandSafetyGuard.evaluateCommand(":(){ :|:& };:").allowed)
    }

    @Test
    fun blocksProtectedWritesAndAllowsWorkspaceWrites() {
        assertFalse(CommandSafetyGuard.evaluateWritePath("/system/bin/sh").allowed)
        assertFalse(CommandSafetyGuard.evaluateWritePath("/home/user/.gemini/oauth_creds.json").allowed)
        assertFalse(CommandSafetyGuard.evaluateWritePath("google_accounts.json", File("/home/user/.gemini")).allowed)
        assertTrue(CommandSafetyGuard.evaluateWritePath("/sdcard/Projects/app/lib/main.dart").allowed)
    }

    @Test
    fun offloadsLargeOutputToFileAndReturnsHeadTailPreview() {
        val dir = createTempDirectory("agy-offload-test").toFile()
        try {
            val huge = "START_MARKER\n" + "x".repeat(20_000) + "\nEND_MARKER"
            val result = CommandSafetyGuard.offloadIfLarge(
                outputDir = dir,
                callId = "term-7",
                rawOutput = huge,
                thresholdChars = 12_000,
            )
            assertTrue(result.offloaded)
            assertNotNull(result.filePath)
            assertTrue(File(result.filePath!!).exists())
            assertEquals(huge, File(result.filePath!!).readText())
            assertTrue(result.text.contains("START_MARKER"))
            assertTrue(result.text.contains("END_MARKER"))
            assertTrue(result.text.length < huge.length)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun compressTerminalOutputStripsAnsiAndCollapsesProgressAndRepeats() {
        val raw = "\u001B[31mFAIL\u001B[0m\n10%\r50%\r100% done\nspam\nspam\nspam\nspam\nend"
        val cleaned = CommandSafetyGuard.compressTerminalOutput(raw)
        assertFalse(cleaned.contains("\u001B"))
        assertFalse(cleaned.contains("10%"))
        assertTrue(cleaned.contains("100% done"))
        assertTrue(cleaned.contains("... [repeated 3 more times]"))
        assertTrue(cleaned.endsWith("end"))
    }
}
