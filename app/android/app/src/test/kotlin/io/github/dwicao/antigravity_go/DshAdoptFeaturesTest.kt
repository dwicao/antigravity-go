package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.performance.PerformanceClassifier
import io.github.dwicao.antigravity_go.performance.RefreshRateCoordinator
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import io.github.dwicao.antigravity_go.phone.SafetyGate
import io.github.dwicao.antigravity_go.runtime.CrashRecorder
import io.github.dwicao.antigravity_go.runtime.CredentialTransferHelper
import io.github.dwicao.antigravity_go.runtime.CustomizationsOps
import io.github.dwicao.antigravity_go.runtime.MultiAccountVault
import io.github.dwicao.antigravity_go.runtime.OAuthTokenManager
import io.github.dwicao.antigravity_go.runtime.UrlSafetyGuard
import java.io.File
import java.util.Base64
import org.json.JSONObject
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

    @Test
    fun oauthTokenManagerProactivelyRefreshesExpiredAndImportedTokensSafely() {
        val nowMs = 1_795_680_000_000L // fixed baseline
        val homeDir = tempFolder.newFolder("oauth-home")
        val tokenFile = File(homeDir, OAuthTokenManager.TOKEN_REL_PATH)
        tokenFile.parentFile?.mkdirs()

        // 1. Fresh token (>15m remaining) skips network refresh completely.
        val futureIso = java.time.Instant.ofEpochMilli(nowMs + 45 * 60_000L).toString()
        val pastIso = java.time.Instant.ofEpochMilli(nowMs - 20 * 3_600_000L).toString()
        val freshPayload = JSONObject()
            .put("auth_method", "consumer")
            .put("id_token_email", "dev@gmail.com")
            .put(
                "token",
                JSONObject()
                    .put("access_token", "ya29.fresh")
                    .put("refresh_token", "1//refresh-keep")
                    .put("token_type", "Bearer")
                    .put("expires_in", 3599)
                    .put("expiry", futureIso),
            )
        tokenFile.writeText(freshPayload.toString())

        var networkCalls = 0
        val testCreds = OAuthTokenManager.ClientCredentials("test-client-id", "test-client-secret")
        val freshOutcome = OAuthTokenManager.ensureFreshTokenInHome(
            homeDir = homeDir,
            clientCredentials = testCreds,
            transport = { _, _ ->
                networkCalls++
                OAuthTokenManager.HttpResult(500, "{}")
            },
            nowMs = { nowMs },
        )
        assertTrue(freshOutcome is OAuthTokenManager.RefreshOutcome.NotNeeded)
        assertEquals(0, networkCalls)

        // 2. Expired token (exported yesterday) refreshes cleanly, preserves refresh_token, updates file + marker.
        freshPayload.getJSONObject("token").put("access_token", "ya29.stale").put("expiry", pastIso)
        tokenFile.writeText(freshPayload.toString())
        val markerFile = File(homeDir, ".gemini/antigravity-go-auth.json")
        markerFile.writeText("""{"isAuthenticated":true,"method":"oauth-personal","updatedAt":1000}""")

        val refreshedOutcome = OAuthTokenManager.ensureFreshTokenInHome(
            homeDir = homeDir,
            clientCredentials = testCreds,
            transport = { _, params ->
                networkCalls++
                assertEquals("1//refresh-keep", params["refresh_token"])
                assertEquals("refresh_token", params["grant_type"])
                OAuthTokenManager.HttpResult(
                    200,
                    """{"access_token":"ya29.new-shiny","expires_in":3599,"token_type":"Bearer"}""",
                )
            },
            nowMs = { nowMs },
        )
        assertTrue(refreshedOutcome is OAuthTokenManager.RefreshOutcome.Refreshed)
        assertEquals(1, networkCalls)
        val saved = JSONObject(tokenFile.readText()).getJSONObject("token")
        assertEquals("ya29.new-shiny", saved.getString("access_token"))
        assertEquals("1//refresh-keep", saved.getString("refresh_token"))
        val updatedExpiry = OAuthTokenManager.parseExpiryMillis(saved)!!
        assertTrue(updatedExpiry > nowMs + 55 * 60_000L)
        assertTrue(JSONObject(markerFile.readText()).getLong("updatedAt") == nowMs)

        // 3. Transient failure never deletes token; PermanentError returns invalid_grant cleanly.
        val transientRes = OAuthTokenManager.ensureFreshTokenInJson(
            rawJson = freshPayload.toString(),
            clientCredentials = testCreds,
            transport = { _, _ -> OAuthTokenManager.HttpResult(503, """{"error":"temporarily_unavailable"}""") },
            nowMs = { nowMs },
        )
        assertTrue(transientRes is OAuthTokenManager.RefreshOutcome.TransientError)

        val permRes = OAuthTokenManager.ensureFreshTokenInJson(
            rawJson = freshPayload.toString(),
            clientCredentials = testCreds,
            transport = { _, _ ->
                OAuthTokenManager.HttpResult(
                    400,
                    """{"error":"invalid_grant","error_description":"Token has been expired or revoked."}""",
                )
            },
            nowMs = { nowMs },
        )
        assertTrue(permRes is OAuthTokenManager.RefreshOutcome.PermanentError)

        // 4. Export/import file-map helper upgrades stale bundled access token cleanly.
        val staleB64 = Base64.getEncoder().encodeToString(freshPayload.toString().toByteArray(Charsets.UTF_8))
        val mapRes = OAuthTokenManager.ensureFreshTokenInFileMap(
            files = mapOf(OAuthTokenManager.TOKEN_REL_PATH to staleB64),
            clientCredentials = testCreds,
            transport = { _, _ ->
                OAuthTokenManager.HttpResult(200, """{"access_token":"ya29.imported-fresh","expires_in":3599}""")
            },
            nowMs = { nowMs },
        )
        assertTrue(mapRes.outcome is OAuthTokenManager.RefreshOutcome.Refreshed)
        val decodedMapToken = String(Base64.getDecoder().decode(mapRes.files[OAuthTokenManager.TOKEN_REL_PATH]!!), Charsets.UTF_8)
        assertTrue(decodedMapToken.contains("ya29.imported-fresh"))

        // 5. Runtime binary discovery extracts synthetic client metadata cleanly without hardcoding.
        val fakeBin = File(tempFolder.newFolder("bin-probe"), "agy")
        val mockId = "999999999999-synthclient" + ".apps.googleusercontent.com"
        val mockSec = "GOCSPX-" + "SynthSecretToken0001"
        fakeBin.writeBytes(("noise\u0000" + mockId + "\u0000middle\u0000" + mockSec + "\u0000end").toByteArray())
        val discovered = OAuthTokenManager.discoverClientsFromBinary(fakeBin)
        assertTrue(discovered.clientIds.contains(mockId))
        assertTrue(discovered.clientSecrets.contains(mockSec))
    }
}
