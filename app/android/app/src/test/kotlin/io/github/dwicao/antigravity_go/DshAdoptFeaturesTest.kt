package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.performance.PerformanceClassifier
import io.github.dwicao.antigravity_go.performance.RefreshRateCoordinator
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import io.github.dwicao.antigravity_go.phone.SafetyGate
import io.github.dwicao.antigravity_go.runtime.CrashRecorder
import io.github.dwicao.antigravity_go.runtime.CredentialTransferHelper
import io.github.dwicao.antigravity_go.runtime.UrlSafetyGuard
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DshAdoptFeaturesTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Before
    fun resetCoordinator() {
        PhoneControlCoordinator.clearActionLog()
        RefreshRateCoordinator.setMode("auto")
    }

    @Test
    fun performanceClassifierCategorizesTiersAndModes() {
        assertEquals("low", PerformanceClassifier.classifyDeviceTier(3500L, 8))
        assertEquals("low", PerformanceClassifier.classifyDeviceTier(8192L, 4))
        assertEquals("medium", PerformanceClassifier.classifyDeviceTier(6144L, 8))
        assertEquals("high", PerformanceClassifier.classifyDeviceTier(12288L, 8))

        assertEquals("max", PerformanceClassifier.normalizeRefreshMode("MAX"))
        assertEquals("system", PerformanceClassifier.normalizeRefreshMode("system"))
        assertEquals("auto", PerformanceClassifier.normalizeRefreshMode("unknown"))
    }

    @Test
    fun safetyGateEnforcesPerAppBlockAndKeepsPasswordProtected() {
        val rules = mapOf(
            "com.example.reader" to SafetyGate.AppRuleMode.ALLOW,
            "com.example.blocked" to SafetyGate.AppRuleMode.BLOCK,
        )

        val blocked = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.blocked",
            action = "tap",
            customRules = rules,
        )
        assertFalse(blocked.allowed)
        assertTrue(blocked.reason.contains("App Rule"))

        val allowed = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.reader",
            action = "tap",
            customRules = rules,
        )
        assertTrue(allowed.allowed)

        val passwordProtected = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.reader",
            action = "type",
            isPasswordField = true,
            customRules = rules,
        )
        assertFalse(passwordProtected.allowed)
    }

    @Test
    fun phoneCoordinatorRecordsAndClearsActionLog() {
        PhoneControlCoordinator.recordAction("tap", "Submit", true, "Permitted tap")
        PhoneControlCoordinator.recordAction("type", "Password", false, "Blocked")

        val entries = PhoneControlCoordinator.getActionLog()
        assertEquals(2, entries.size)
        assertEquals("type", entries[0]["action"])
        assertEquals(false, entries[0]["allowed"])

        PhoneControlCoordinator.clearActionLog()
        assertTrue(PhoneControlCoordinator.getActionLog().isEmpty())
    }

    @Test
    fun urlSafetyGuardBlocksMetadataAndUnsafeSchemesAndAllowsHttp() {
        assertFalse(UrlSafetyGuard.evaluateUrl("").allowed)
        assertFalse(UrlSafetyGuard.evaluateUrl("file:///etc/passwd").allowed)
        assertFalse(UrlSafetyGuard.evaluateUrl("content://settings/secure").allowed)
        assertFalse(UrlSafetyGuard.evaluateUrl("http://169.254.169.254/latest/meta-data/").allowed)
        assertFalse(UrlSafetyGuard.evaluateUrl("http://metadata.google.internal/computeMetadata/v1/").allowed)
        assertFalse(UrlSafetyGuard.evaluateUrl("http://100.100.100.200/latest/").allowed)

        assertTrue(UrlSafetyGuard.evaluateUrl("https://github.com/dwicao/antigravity-go").allowed)
        assertTrue(UrlSafetyGuard.evaluateUrl("http://localhost:8080/health").allowed)
    }

    @Test
    fun crashRecorderRedactsSecretsInRecordedStacktrace() {
        val logFile = tempFolder.newFile("crashes.log")
        val boom = IllegalStateException("Bearer sk-proj-supersecret123456 failed")
        CrashRecorder.recordToFile(logFile, "worker-1", boom)

        val content = logFile.readText()
        assertTrue(content.contains("Crash @"))
        assertTrue(content.contains("thread=worker-1"))
        assertFalse(content.contains("sk-proj-supersecret123456"))
    }

    @Test
    fun credentialTransferHelperExportsAndImportsEncryptedBundleSafely() {
        val srcHome = tempFolder.newFolder("src-home")
        val tokenFile = File(srcHome, ".gemini/antigravity-cli/antigravity-oauth-token")
        tokenFile.parentFile?.mkdirs()
        tokenFile.writeText("""{"access_token":"secret-oauth-token"}""")

        val settingsFile = File(srcHome, ".gemini/antigravity-cli/settings.json")
        settingsFile.writeText("""{"model":"gemini-4-neon-high"}""")

        val bundle = CredentialTransferHelper.exportEncryptedBundle(
            homeDir = srcHome,
            passphrase = "my-strong-passphrase",
            geminiApiKey = "AIzaTestKey123",
            authProfileJson = """{"isAuthenticated":true,"email":"user@gmail.com"}""",
        )
        assertFalse(bundle.contains("secret-oauth-token"))
        assertFalse(bundle.contains("AIzaTestKey123"))

        var wrongPassFailed = false
        try {
            CredentialTransferHelper.importEncryptedBundle(srcHome, bundle, "wrong-pass")
        } catch (_: IllegalArgumentException) {
            wrongPassFailed = true
        }
        assertTrue(wrongPassFailed)

        val dstHome = tempFolder.newFolder("dst-home")
        val restored = CredentialTransferHelper.importEncryptedBundle(
            homeDir = dstHome,
            bundleJson = bundle,
            passphrase = "my-strong-passphrase",
        )
        assertEquals(2, restored["restoredFiles"])
        assertEquals("AIzaTestKey123", restored["geminiApiKey"])
        assertTrue(File(dstHome, ".gemini/antigravity-cli/antigravity-oauth-token").readText().contains("secret-oauth-token"))
        assertTrue(File(dstHome, ".gemini/antigravity-go-auth.json").exists())

        assertFalse(CredentialTransferHelper.isAllowedRelativePath("../etc/passwd"))
        assertFalse(CredentialTransferHelper.isAllowedRelativePath("/data/local/tmp/foo"))
        assertFalse(CredentialTransferHelper.isAllowedRelativePath(".ssh/id_rsa"))
        assertTrue(CredentialTransferHelper.isAllowedRelativePath(".gemini/antigravity-cli/antigravity-oauth-token"))
    }
}
