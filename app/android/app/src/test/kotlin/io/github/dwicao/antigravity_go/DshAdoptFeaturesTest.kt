package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.performance.PerformanceClassifier
import io.github.dwicao.antigravity_go.performance.RefreshRateCoordinator
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import io.github.dwicao.antigravity_go.phone.SafetyGate
import io.github.dwicao.antigravity_go.runtime.CrashRecorder
import io.github.dwicao.antigravity_go.runtime.CredentialTransferHelper
import io.github.dwicao.antigravity_go.runtime.CustomizationsOps
import io.github.dwicao.antigravity_go.runtime.MultiAccountVault
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

    @Test
    fun multiAccountVaultImportsMultipleBundlesAndSwitchesCleanly() {
        val aliceSrc = tempFolder.newFolder("alice-src")
        val aliceToken = File(aliceSrc, ".gemini/antigravity-cli/antigravity-oauth-token")
        aliceToken.parentFile?.mkdirs()
        aliceToken.writeText("""{"token":"alice-secret"}""")
        File(aliceSrc, ".gemini/antigravity-go-auth.json").writeText(
            """{"isAuthenticated":true,"email":"alice@gmail.com","method":"oauth-personal"}"""
        )
        val aliceBundle = CredentialTransferHelper.exportEncryptedBundle(
            homeDir = aliceSrc,
            passphrase = "pass-a",
            authProfileJson = """{"isAuthenticated":true,"email":"alice@gmail.com","planTier":"pro"}""",
        )

        val bobSrc = tempFolder.newFolder("bob-src")
        val bobToken = File(bobSrc, ".gemini/antigravity-cli/antigravity-oauth-token")
        bobToken.parentFile?.mkdirs()
        bobToken.writeText("""{"token":"bob-secret"}""")
        File(bobSrc, ".gemini/oauth_creds.json").writeText("""{"refresh_token":"bob-refresh"}""")
        val bobBundle = CredentialTransferHelper.exportEncryptedBundle(
            homeDir = bobSrc,
            passphrase = "pass-b",
            authProfileJson = """{"isAuthenticated":true,"email":"bob@gmail.com","planTier":"ultra"}""",
        )

        // Device already signed in as carol@gmail.com before importing Alice & Bob.
        val deviceHome = tempFolder.newFolder("device-home")
        val accountsDir = tempFolder.newFolder("device-accounts")
        val carolToken = File(deviceHome, ".gemini/antigravity-cli/antigravity-oauth-token")
        carolToken.parentFile?.mkdirs()
        carolToken.writeText("""{"token":"carol-secret"}""")
        File(deviceHome, ".gemini/antigravity-go-auth.json").writeText(
            """{"isAuthenticated":true,"email":"carol@gmail.com","method":"oauth-personal"}"""
        )

        val aliceImport = MultiAccountVault.importEncryptedBundle(
            homeDir = deviceHome,
            accountsDir = accountsDir,
            bundleJson = aliceBundle,
            passphrase = "pass-a",
            activate = false,
            currentAuthProfileJson = """{"isAuthenticated":true,"email":"carol@gmail.com"}""",
        )
        assertEquals(false, aliceImport["activated"])

        val bobImport = MultiAccountVault.importEncryptedBundle(
            homeDir = deviceHome,
            accountsDir = accountsDir,
            bundleJson = bobBundle,
            passphrase = "pass-b",
            activate = true,
            currentAuthProfileJson = """{"isAuthenticated":true,"email":"carol@gmail.com"}""",
        )
        assertEquals(true, bobImport["activated"])

        val accounts = MultiAccountVault.listAccounts(deviceHome, accountsDir)
        assertEquals(3, accounts.size)
        val activeAcct = accounts.first { it["isActive"] == true }
        assertEquals("bob@gmail.com", activeAcct["email"])
        assertTrue(File(deviceHome, ".gemini/antigravity-cli/antigravity-oauth-token").readText().contains("bob-secret"))

        // Switching to Alice clears Bob-only files (oauth_creds.json) and restores Alice's tokens.
        val aliceMeta = accounts.first { it["email"] == "alice@gmail.com" }
        MultiAccountVault.switchAccount(deviceHome, accountsDir, aliceMeta["id"] as String)
        assertTrue(File(deviceHome, ".gemini/antigravity-cli/antigravity-oauth-token").readText().contains("alice-secret"))
        assertFalse(File(deviceHome, ".gemini/oauth_creds.json").exists())

        // Exporting Carol's inactive slot works without switching away from Alice.
        val carolMeta = accounts.first { it["email"] == "carol@gmail.com" }
        val carolExport = MultiAccountVault.exportAccount(
            homeDir = deviceHome,
            accountsDir = accountsDir,
            accountId = carolMeta["id"] as String,
            passphrase = "pass-c",
        )
        val decryptedCarol = CredentialTransferHelper.decryptPayload(carolExport, "pass-c")
        assertTrue(decryptedCarol.files.containsKey(".gemini/antigravity-cli/antigravity-oauth-token"))

        // Removing active Alice clears home auth files while keeping Bob & Carol.
        val removeRes = MultiAccountVault.removeAccount(deviceHome, accountsDir, aliceMeta["id"] as String)
        assertEquals(true, removeRes["wasActive"])
        assertFalse(File(deviceHome, ".gemini/antigravity-cli/antigravity-oauth-token").exists())
        assertEquals(2, MultiAccountVault.listAccounts(deviceHome, accountsDir).size)
    }

    @Test
    fun customizationsOpsDiscoversAgentsMdAndSkillsWithFrontmatter() {
        val homeDir = tempFolder.newFolder("cust-home")
        val workspaceDir = tempFolder.newFolder("cust-ws")
        val projectDir = tempFolder.newFolder("cust-proj")
        val ops = CustomizationsOps(
            homeDir = homeDir,
            workspaceDir = workspaceDir,
            bashFile = File("/system/bin/sh"),
            tmpDir = tempFolder.newFolder("cust-tmp"),
            settingsFile = File(homeDir, ".gemini/antigravity-cli/settings.json"),
            atomicWriteText = { file, text ->
                file.parentFile?.mkdirs()
                file.writeText(text)
            },
        )

        val globalAgents = File(homeDir, ".agents/AGENTS.md")
        globalAgents.parentFile?.mkdirs()
        globalAgents.writeText("# Global Agents\nAlways verify diffs.")

        val projectAgents = File(projectDir, "AGENTS.md")
        projectAgents.writeText("# Project Agents\nRun tests before commit.")

        val skillPath = ops.createSkill(
            name = "Deploy Check",
            description = "Validate release artifacts before tagging",
            scope = "Project",
            cwd = projectDir.absolutePath,
        )
        assertTrue(File(skillPath).isFile)

        val globalSkill = File(homeDir, ".gemini/antigravity-cli/skills/audit/SKILL.md")
        globalSkill.parentFile?.mkdirs()
        globalSkill.writeText("---\nname: security-audit\ndescription: \"Audit auth flows\"\n---\nCheck tokens.")

        val items = ops.listCustomizations(projectDir.absolutePath)
        val projectAgentsItem = items.firstOrNull { it["path"] == projectAgents.absolutePath }
        assertEquals("rule", projectAgentsItem?.get("kind"))
        assertEquals(true, projectAgentsItem?.get("enabled"))

        val globalAgentsItem = items.firstOrNull { it["path"] == globalAgents.absolutePath }
        assertEquals("rule", globalAgentsItem?.get("kind"))
        assertEquals(true, globalAgentsItem?.get("enabled"))

        val projectSkill = items.firstOrNull { it["name"] == "deploy-check" }
        assertEquals("skill", projectSkill?.get("kind"))
        assertEquals("Project", projectSkill?.get("scope"))
        assertEquals("Validate release artifacts before tagging", projectSkill?.get("description"))

        val auditSkill = items.firstOrNull { it["name"] == "security-audit" }
        assertEquals("skill", auditSkill?.get("kind"))
        assertEquals("Global", auditSkill?.get("scope"))
        assertEquals("Audit auth flows", auditSkill?.get("description"))
    }
}
