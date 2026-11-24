package io.github.dwicao.antigravity_go.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashClassifierAndSafePolicyTest {

    @Test
    fun `LogRedactor masks API keys, Bearer headers, URLs and PEM blocks`() {
        val redactor = LogRedactor()
        val line1 = redactor.line("Authorization: Bearer super_secret_token_123456")
        assertFalse(line1.contains("super_secret_token"))
        assertTrue(line1.contains("Bearer ••••"))

        val line2 = redactor.line("GOOGLE_KEY=AIzaSyDummyKeyValue1234567890123456789")
        assertFalse(line2.contains("DummyKeyValue"))

        val line3 = redactor.line("https://alice:hunter2@example.com/repo.git")
        assertFalse(line3.contains("hunter2"))
        assertTrue(line3.contains("alice:••••@example.com"))

        val pemStart = redactor.line("-----BEGIN RSA PRIVATE KEY-----")
        val pemMid = redactor.line("MIIEowIBAAKCAQEAsecretkeybytes")
        val pemEnd = redactor.line("-----END RSA PRIVATE KEY-----")
        assertTrue(pemStart.contains("BEGIN RSA PRIVATE KEY"))
        assertFalse(pemMid.contains("secretkeybytes"))
        assertTrue(pemEnd.contains("END RSA PRIVATE KEY"))
    }

    @Test
    fun `CrashClassifier categorizes sandbox, missing bash, quota, and OS kills`() {
        val sandbox = CrashClassifier.classify(
            exitCode = 1,
            upMillis = 500,
            tailLines = listOf("Auto mode is not available: it needs the OS terminal sandbox"),
            safeMode = false,
            receivedAgentOutput = false,
        )
        assertEquals(FailureKind.SANDBOX_UNAVAILABLE, sandbox?.kind)

        val missingBash = CrashClassifier.classify(
            exitCode = 1,
            upMillis = 1200,
            tailLines = listOf("""exec: "bash": executable file not found in ${'$'}PATH"""),
            safeMode = false,
            receivedAgentOutput = false,
        )
        assertEquals(FailureKind.MISSING_TOOL, missingBash?.kind)

        val rateLimited = CrashClassifier.classify(
            exitCode = 1,
            upMillis = 4000,
            tailLines = listOf("Error 429 RESOURCE_EXHAUSTED"),
            safeMode = false,
            receivedAgentOutput = false,
        )
        assertEquals(FailureKind.RATE_LIMITED, rateLimited?.kind)

        val osKilled = CrashClassifier.classify(
            exitCode = 137,
            upMillis = 45_000,
            tailLines = emptyList(),
            safeMode = false,
            receivedAgentOutput = true,
        )
        assertEquals(FailureKind.KILLED, osKilled?.kind)

        val sigsys = CrashClassifier.classify(
            exitCode = 159,
            upMillis = 100,
            tailLines = emptyList(),
            safeMode = false,
            receivedAgentOutput = false,
        )
        assertEquals(FailureKind.CRASHED_EARLY, sigsys?.kind)
        assertTrue(sigsys?.hint?.contains("SIGSYS") == true)
    }

    @Test
    fun `SafePolicy engages Safe Mode after two startup strikes and backs off retries`() {
        val startupCrash = RunFailure(
            kind = FailureKind.STARTUP_FAILED,
            exitCode = 1,
            safeMode = false,
            summary = "broken plugin",
            hint = "safe mode",
            upMillis = 800,
        )
        val first = SafePolicy.onFailure(SafeState.OFF, 0, startupCrash, autoSafe = true)
        assertFalse(first.engagedSafeMode)
        assertEquals(1, first.strikes)

        val second = SafePolicy.onFailure(first.state, first.strikes, startupCrash, autoSafe = true)
        assertTrue(second.engagedSafeMode)
        assertEquals(SafeState.ON, second.state)

        // Probation immediately returns to Safe Mode on failure.
        val probation = SafePolicy.onFailure(SafeState.PROBATION, 0, startupCrash, autoSafe = true)
        assertTrue(probation.engagedSafeMode)
        assertEquals(SafeState.ON, probation.state)

        // Exponential backoff schedule: 5s, 15s, 45s, then stop.
        val now = 1_000_000L
        assertEquals(5_000L, SafePolicy.autoRestartDelay(FailureKind.KILLED, 137, 45_000L, emptyList(), now))
        assertEquals(15_000L, SafePolicy.autoRestartDelay(FailureKind.KILLED, 137, 45_000L, listOf(now - 5_000), now))
        assertEquals(45_000L, SafePolicy.autoRestartDelay(FailureKind.KILLED, 137, 45_000L, listOf(now - 10_000, now - 5_000), now))
        assertNull(SafePolicy.autoRestartDelay(FailureKind.KILLED, 137, 45_000L, listOf(now - 15_000, now - 10_000, now - 5_000), now))
        assertNotNull(SafePolicy.autoRestartDelay(FailureKind.NETWORK_ERROR, 1, null, emptyList(), now))
    }

    @Test
    fun `AcpSessionManager suppresses session_load history replay before session_prompt`() {
        assertFalse(AcpSessionManager.shouldForwardAcpNotification("session/update", promptSent = false))
        assertTrue(AcpSessionManager.shouldForwardAcpNotification("session/update", promptSent = true))
        assertTrue(AcpSessionManager.shouldForwardAcpNotification("", promptSent = false))
    }

    @Test
    fun `AcpSessionManager summarizeCommand collapses whitespace and truncates long commands`() {
        assertEquals("Shell command", AcpSessionManager.summarizeCommand("   \n  "))
        assertEquals("ls -la /sdcard", AcpSessionManager.summarizeCommand("ls\n  -la   /sdcard"))
        val longCmd = "echo " + "a".repeat(100)
        val summarized = AcpSessionManager.summarizeCommand(longCmd, maxLen = 20)
        assertEquals(20, summarized.length)
        assertTrue(summarized.endsWith("…"))
    }

    @Test
    fun `AcpSessionManager workerSignature changes when extraDirs or skipPermissions change`() {
        val cwd = java.io.File("/data/user/0/app/workspace")
        val withoutSdcard = AcpSessionManager.buildWorkerSignature(
            cwd = cwd,
            extraDirs = listOf("/data/user/0/app/workspace"),
            skipPermissions = true,
            agent = null,
        )
        val withSdcard = AcpSessionManager.buildWorkerSignature(
            cwd = cwd,
            extraDirs = listOf("/data/user/0/app/workspace", "/sdcard", "/storage/emulated/0"),
            skipPermissions = true,
            agent = null,
        )
        val sameReordered = AcpSessionManager.buildWorkerSignature(
            cwd = cwd,
            extraDirs = listOf("/storage/emulated/0", "/sdcard", "/data/user/0/app/workspace", ""),
            skipPermissions = true,
            agent = null,
        )
        assertFalse(withoutSdcard == withSdcard)
        assertEquals(withSdcard, sameReordered)
    }
}
