package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/**
 * Stores multiple signed-in / imported Antigravity credential snapshots in app-private
 * storage (`runtime/accounts/`) so users can import multiple `.agycreds.json` bundles and
 * switch between accounts in one tap without repeating Google OAuth.
 */
object MultiAccountVault {
    private const val INDEX_FILE = "index.json"
    private const val SNAPSHOT_FILE = "snapshot.json"
    private val lock = Any()
    private val emailRegex = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    private data class AccountMeta(
        val id: String,
        val email: String?,
        val displayName: String,
        val method: String,
        val planTier: String,
        val gcpProject: String?,
        val gcpLocation: String?,
        val hasApiKey: Boolean,
        val fileCount: Int,
        val addedAtMs: Long,
        val lastUsedAtMs: Long,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("id", id)
            .put("displayName", displayName)
            .put("method", method)
            .put("planTier", planTier)
            .put("hasApiKey", hasApiKey)
            .put("fileCount", fileCount)
            .put("addedAtMs", addedAtMs)
            .put("lastUsedAtMs", lastUsedAtMs)
            .apply {
                if (!email.isNullOrBlank()) put("email", email)
                if (!gcpProject.isNullOrBlank()) put("gcpProject", gcpProject)
                if (!gcpLocation.isNullOrBlank()) put("gcpLocation", gcpLocation)
            }

        fun toMap(activeId: String?): Map<String, Any?> = mapOf(
            "id" to id,
            "email" to email,
            "displayName" to displayName,
            "method" to method,
            "planTier" to planTier,
            "gcpProject" to gcpProject,
            "gcpLocation" to gcpLocation,
            "hasApiKey" to hasApiKey,
            "fileCount" to fileCount,
            "addedAtMs" to addedAtMs,
            "lastUsedAtMs" to lastUsedAtMs,
            "isActive" to (id == activeId),
        )

        companion object {
            fun fromJson(obj: JSONObject): AccountMeta? {
                val id = obj.optString("id").trim()
                if (id.isEmpty()) return null
                val email = obj.optString("email").takeIf { it.isNotBlank() }
                val displayName = obj.optString("displayName")
                    .takeIf { it.isNotBlank() }
                    ?: email
                    ?: "Google Account"
                return AccountMeta(
                    id = id,
                    email = email,
                    displayName = displayName,
                    method = obj.optString("method").ifBlank { "oauth-personal" },
                    planTier = obj.optString("planTier").ifBlank { "free" },
                    gcpProject = obj.optString("gcpProject").takeIf { it.isNotBlank() },
                    gcpLocation = obj.optString("gcpLocation").takeIf { it.isNotBlank() },
                    hasApiKey = obj.optBoolean("hasApiKey", false),
                    fileCount = obj.optInt("fileCount", 0),
                    addedAtMs = obj.optLong("addedAtMs", System.currentTimeMillis()),
                    lastUsedAtMs = obj.optLong("lastUsedAtMs", System.currentTimeMillis()),
                )
            }
        }
    }

    private data class VaultIndex(
        var activeAccountId: String?,
        val accounts: MutableList<AccountMeta>,
    )

    fun listAccounts(
        homeDir: File,
        accountsDir: File,
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): List<Map<String, Any?>> = synchronized(lock) {
        syncActiveAccountLocked(
            homeDir = homeDir,
            accountsDir = accountsDir,
            authProfileJson = currentAuthProfileJson,
            geminiApiKey = currentGeminiApiKey,
        )
        val index = loadIndexLocked(accountsDir)
        index.accounts
            .sortedWith(
                compareByDescending<AccountMeta> { it.id == index.activeAccountId }
                    .thenByDescending { it.lastUsedAtMs }
            )
            .map { it.toMap(index.activeAccountId) }
    }

    fun syncActiveAccount(
        homeDir: File,
        accountsDir: File,
        authProfileJson: String? = null,
        geminiApiKey: String? = null,
    ): Map<String, Any?>? = synchronized(lock) {
        val synced = syncActiveAccountLocked(
            homeDir = homeDir,
            accountsDir = accountsDir,
            authProfileJson = authProfileJson,
            geminiApiKey = geminiApiKey,
        )
        val activeId = loadIndexLocked(accountsDir).activeAccountId
        synced?.toMap(activeId)
    }

    fun importEncryptedBundle(
        homeDir: File,
        accountsDir: File,
        bundleJson: String,
        passphrase: String,
        activate: Boolean = true,
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): Map<String, Any?> = synchronized(lock) {
        if (activate) {
            syncActiveAccountLocked(
                homeDir = homeDir,
                accountsDir = accountsDir,
                authProfileJson = currentAuthProfileJson,
                geminiApiKey = currentGeminiApiKey,
            )
        }

        val decoded = CredentialTransferHelper.decryptPayload(bundleJson, passphrase)
        val refreshed = OAuthTokenManager.ensureFreshTokenInFileMap(
            files = decoded.files,
            homeDirForClientCache = homeDir,
            minRemainingMs = OAuthTokenManager.EXPORT_LEEWAY_MS,
        )
        val snapshotFiles = refreshed.files
        val meta = buildMeta(
            files = snapshotFiles,
            authProfileJson = decoded.authProfileJson,
            geminiApiKey = decoded.geminiApiKey,
            existingIndex = loadIndexLocked(accountsDir),
        )

        writeSnapshotLocked(
            accountsDir = accountsDir,
            accountId = meta.id,
            files = snapshotFiles,
            geminiApiKey = decoded.geminiApiKey,
            authProfileJson = decoded.authProfileJson,
        )

        val index = loadIndexLocked(accountsDir)
        upsertAccountLocked(index, meta)

        var restoredCount = 0
        if (activate) {
            CredentialTransferHelper.clearActiveCredentialFiles(homeDir)
            restoredCount = CredentialTransferHelper.restoreCredentialFiles(
                homeDir = homeDir,
                files = snapshotFiles,
                fallbackEmail = meta.email,
            )
            index.activeAccountId = meta.id
        }
        saveIndexLocked(accountsDir, index)

        mapOf(
            "account" to meta.toMap(index.activeAccountId),
            "restoredFiles" to restoredCount,
            "geminiApiKey" to decoded.geminiApiKey,
            "authProfileJson" to decoded.authProfileJson,
            "activated" to activate,
        )
    }

    fun switchAccount(
        homeDir: File,
        accountsDir: File,
        accountId: String,
        currentAuthProfileJson: String? = null,
        currentGeminiApiKey: String? = null,
    ): Map<String, Any?> = synchronized(lock) {
        val index = loadIndexLocked(accountsDir)
        val target = index.accounts.firstOrNull { it.id == accountId }
            ?: throw IllegalArgumentException("Saved account not found")

        // Snapshot outgoing active account so refreshed OAuth tokens are preserved.
        syncActiveAccountLocked(
            homeDir = homeDir,
            accountsDir = accountsDir,
            authProfileJson = currentAuthProfileJson,
            geminiApiKey = currentGeminiApiKey,
        )

        val rawSnapshot = readSnapshotLocked(accountsDir, accountId)
            ?: throw IllegalStateException("Saved credentials missing for ${target.displayName}")
        val refreshed = OAuthTokenManager.ensureFreshTokenInFileMap(
            files = rawSnapshot.files,
            homeDirForClientCache = homeDir,
            minRemainingMs = OAuthTokenManager.DEFAULT_LEEWAY_MS,
        )
        val snapshot = if (refreshed.outcome is OAuthTokenManager.RefreshOutcome.Refreshed) {
            writeSnapshotLocked(
                accountsDir = accountsDir,
                accountId = accountId,
                files = refreshed.files,
                geminiApiKey = rawSnapshot.geminiApiKey,
                authProfileJson = rawSnapshot.authProfileJson,
            )
            rawSnapshot.copy(files = refreshed.files)
        } else {
            rawSnapshot
        }

        CredentialTransferHelper.clearActiveCredentialFiles(homeDir)
        val restoredCount = CredentialTransferHelper.restoreCredentialFiles(
            homeDir = homeDir,
            files = snapshot.files,
            fallbackEmail = target.email,
        )

        val updated = target.copy(lastUsedAtMs = System.currentTimeMillis())
        upsertAccountLocked(index, updated)
        index.activeAccountId = accountId
        saveIndexLocked(accountsDir, index)

        mapOf(
            "account" to updated.toMap(accountId),
            "restoredFiles" to restoredCount,
            "geminiApiKey" to snapshot.geminiApiKey,
            "authProfileJson" to snapshot.authProfileJson,
        )
    }

    fun exportAccount(
        homeDir: File,
        accountsDir: File,
        accountId: String?,
        passphrase: String,
        fallbackGeminiApiKey: String? = null,
        fallbackAuthProfileJson: String? = null,
    ): String = synchronized(lock) {
        val index = loadIndexLocked(accountsDir)
        val targetId = accountId?.takeIf { it.isNotBlank() } ?: index.activeAccountId
        if (targetId == null || targetId == index.activeAccountId) {
            val activeOutcome = OAuthTokenManager.ensureFreshTokenInHome(
                homeDir = homeDir,
                minRemainingMs = OAuthTokenManager.EXPORT_LEEWAY_MS,
            )
            val existing = targetId?.let { readSnapshotLocked(accountsDir, it) }
            val collected = CredentialTransferHelper.collectCredentialFiles(homeDir)
            val baseFiles = if (collected.isNotEmpty()) collected else (existing?.files ?: emptyMap())
            val refreshed = OAuthTokenManager.ensureFreshTokenInFileMap(
                files = baseFiles,
                homeDirForClientCache = homeDir,
                minRemainingMs = OAuthTokenManager.EXPORT_LEEWAY_MS,
            )
            val useFiles = refreshed.files
            if (targetId != null &&
                (activeOutcome is OAuthTokenManager.RefreshOutcome.Refreshed ||
                    refreshed.outcome is OAuthTokenManager.RefreshOutcome.Refreshed)
            ) {
                writeSnapshotLocked(
                    accountsDir = accountsDir,
                    accountId = targetId,
                    files = useFiles,
                    geminiApiKey = fallbackGeminiApiKey ?: existing?.geminiApiKey,
                    authProfileJson = fallbackAuthProfileJson ?: existing?.authProfileJson,
                )
            }
            return@synchronized CredentialTransferHelper.encryptPayload(
                files = useFiles,
                passphrase = passphrase,
                geminiApiKey = fallbackGeminiApiKey ?: existing?.geminiApiKey,
                authProfileJson = fallbackAuthProfileJson ?: existing?.authProfileJson,
            )
        }
        val snapshot = readSnapshotLocked(accountsDir, targetId)
            ?: throw IllegalStateException("Saved credentials not found for account")
        val refreshed = OAuthTokenManager.ensureFreshTokenInFileMap(
            files = snapshot.files,
            homeDirForClientCache = homeDir,
            minRemainingMs = OAuthTokenManager.EXPORT_LEEWAY_MS,
        )
        if (refreshed.outcome is OAuthTokenManager.RefreshOutcome.Refreshed) {
            writeSnapshotLocked(
                accountsDir = accountsDir,
                accountId = targetId,
                files = refreshed.files,
                geminiApiKey = snapshot.geminiApiKey,
                authProfileJson = snapshot.authProfileJson,
            )
        }
        return@synchronized CredentialTransferHelper.encryptPayload(
            files = refreshed.files,
            passphrase = passphrase,
            geminiApiKey = snapshot.geminiApiKey,
            authProfileJson = snapshot.authProfileJson,
        )
    }

    fun removeAccount(
        homeDir: File,
        accountsDir: File,
        accountId: String,
    ): Map<String, Any?> = synchronized(lock) {
        val index = loadIndexLocked(accountsDir)
        val removed = index.accounts.removeAll { it.id == accountId }
        val wasActive = index.activeAccountId == accountId
        if (wasActive) {
            CredentialTransferHelper.clearActiveCredentialFiles(homeDir)
            index.activeAccountId = null
        }
        File(accountsDir, sanitizeId(accountId)).deleteRecursively()
        saveIndexLocked(accountsDir, index)
        mapOf(
            "removed" to removed,
            "wasActive" to wasActive,
        )
    }

    fun clearActiveAccountOnLogout(
        homeDir: File,
        accountsDir: File,
    ) = synchronized(lock) {
        val index = loadIndexLocked(accountsDir)
        val activeId = index.activeAccountId
        if (!activeId.isNullOrBlank()) {
            index.accounts.removeAll { it.id == activeId }
            File(accountsDir, sanitizeId(activeId)).deleteRecursively()
            index.activeAccountId = null
            saveIndexLocked(accountsDir, index)
        }
        CredentialTransferHelper.clearActiveCredentialFiles(homeDir)
    }

    fun refreshSavedAccountsKeepAlive(
        homeDir: File,
        accountsDir: File,
        forceActive: Boolean = false,
        nowMs: Long = System.currentTimeMillis(),
    ): OAuthTokenManager.RefreshOutcome {
        val activeOutcome = OAuthTokenManager.ensureFreshTokenInHome(
            homeDir = homeDir,
            force = forceActive,
            minRemainingMs = OAuthTokenManager.DEFAULT_LEEWAY_MS,
            nowMs = { nowMs },
        )
        val inactiveTargets = synchronized(lock) {
            val index = loadIndexLocked(accountsDir)
            val activeId = index.activeAccountId
            if (activeOutcome is OAuthTokenManager.RefreshOutcome.Refreshed && activeId != null) {
                readSnapshotLocked(accountsDir, activeId)?.let { snap ->
                    val refreshedFiles = CredentialTransferHelper.collectCredentialFiles(homeDir)
                    if (refreshedFiles.isNotEmpty()) {
                        writeSnapshotLocked(
                            accountsDir = accountsDir,
                            accountId = activeId,
                            files = refreshedFiles,
                            geminiApiKey = snap.geminiApiKey,
                            authProfileJson = snap.authProfileJson,
                        )
                    }
                }
            }
            index.accounts.mapNotNull { meta ->
                if (meta.id == activeId) return@mapNotNull null
                val snapFile = File(accountsDir, "${sanitizeId(meta.id)}/$SNAPSHOT_FILE")
                if (!snapFile.isFile) return@mapNotNull null
                if (nowMs - snapFile.lastModified() < OAuthTokenManager.DORMANT_ACCOUNT_REFRESH_MS) {
                    return@mapNotNull null
                }
                val snap = readSnapshotLocked(accountsDir, meta.id) ?: return@mapNotNull null
                meta.id to snap
            }
        }
        for ((acctId, snap) in inactiveTargets) {
            val res = OAuthTokenManager.ensureFreshTokenInFileMap(
                files = snap.files,
                homeDirForClientCache = homeDir,
                minRemainingMs = OAuthTokenManager.DEFAULT_LEEWAY_MS,
                nowMs = { nowMs },
            )
            if (res.outcome is OAuthTokenManager.RefreshOutcome.Refreshed) {
                synchronized(lock) {
                    val latestSnap = readSnapshotLocked(accountsDir, acctId) ?: snap
                    writeSnapshotLocked(
                        accountsDir = accountsDir,
                        accountId = acctId,
                        files = res.files,
                        geminiApiKey = latestSnap.geminiApiKey,
                        authProfileJson = latestSnap.authProfileJson,
                    )
                }
            }
        }
        return activeOutcome
    }

    private fun syncActiveAccountLocked(
        homeDir: File,
        accountsDir: File,
        authProfileJson: String?,
        geminiApiKey: String?,
    ): AccountMeta? {
        val index = loadIndexLocked(accountsDir)
        val files = CredentialTransferHelper.collectCredentialFiles(homeDir)
        val hasActiveAuth = hasAuthPayload(files, authProfileJson, geminiApiKey)
        if (!hasActiveAuth) {
            return index.activeAccountId?.let { id -> index.accounts.firstOrNull { it.id == id } }
        }

        val currentActive = index.activeAccountId?.let { id ->
            index.accounts.firstOrNull { it.id == id }
        }
        val prevSnapshot = currentActive?.let { readSnapshotLocked(accountsDir, it.id) }
        val effectiveProfile = authProfileJson?.takeIf { it.isNotBlank() } ?: prevSnapshot?.authProfileJson
        val effectiveApiKey = geminiApiKey?.takeIf { it.isNotBlank() } ?: prevSnapshot?.geminiApiKey

        val meta = buildMeta(
            files = files,
            authProfileJson = effectiveProfile,
            geminiApiKey = effectiveApiKey,
            existingIndex = index,
            preferredId = currentActive?.id,
        )
        writeSnapshotLocked(
            accountsDir = accountsDir,
            accountId = meta.id,
            files = files,
            geminiApiKey = effectiveApiKey,
            authProfileJson = effectiveProfile,
        )
        upsertAccountLocked(index, meta)
        index.activeAccountId = meta.id
        saveIndexLocked(accountsDir, index)
        return meta
    }

    private fun hasAuthPayload(
        files: Map<String, String>,
        authProfileJson: String?,
        geminiApiKey: String?,
    ): Boolean {
        if (!geminiApiKey.isNullOrBlank()) return true
        if (!authProfileJson.isNullOrBlank()) {
            val isAuth = runCatching {
                JSONObject(authProfileJson).optBoolean("isAuthenticated", false)
            }.getOrDefault(false)
            if (isAuth) return true
        }
        // settings.json alone may exist for tool permissions before signing in.
        return files.keys.any {
            it != ".gemini/antigravity-cli/settings.json" &&
                it != ".gemini/config/config.json"
        }
    }

    private fun buildMeta(
        files: Map<String, String>,
        authProfileJson: String?,
        geminiApiKey: String?,
        existingIndex: VaultIndex,
        preferredId: String? = null,
    ): AccountMeta {
        val profileObj = authProfileJson?.let { runCatching { JSONObject(it) }.getOrNull() }
        var email = profileObj?.optString("email")?.takeIf { it.isNotBlank() }
        var method = profileObj?.optString("method")?.takeIf { it.isNotBlank() }
        val planTier = profileObj?.optString("planTier")?.takeIf { it.isNotBlank() }
        var gcpProject = profileObj?.optString("gcpProject")?.takeIf { it.isNotBlank() }
        var gcpLocation = profileObj?.optString("gcpLocation")?.takeIf { it.isNotBlank() }

        val decoder = Base64.getDecoder()
        if (email == null || gcpProject == null || method == null) {
            for ((rel, b64) in files) {
                val text = runCatching { String(decoder.decode(b64), Charsets.UTF_8) }.getOrNull()
                    ?: continue
                if (rel.endsWith("antigravity-go-auth.json")) {
                    runCatching {
                        val marker = JSONObject(text)
                        if (email == null) email = marker.optString("email").takeIf { it.isNotBlank() }
                        if (method == null) method = marker.optString("method").takeIf { it.isNotBlank() }
                    }
                }
                if (rel.endsWith("settings.json")) {
                    runCatching {
                        val settings = JSONObject(text)
                        val gcp = settings.optJSONObject("gcp")
                        if (gcp != null) {
                            if (gcpProject == null) gcpProject = gcp.optString("project").takeIf { it.isNotBlank() }
                            if (gcpLocation == null) gcpLocation = gcp.optString("location").takeIf { it.isNotBlank() }
                            if (method == null) method = "oauth-business"
                        }
                    }
                }
                if (email == null) {
                    val match = emailRegex.find(text)
                    if (match != null && !match.value.endsWith(".example.com")) {
                        email = match.value
                    }
                }
            }
        }

        val resolvedMethod = method ?: when {
            gcpProject != null -> "oauth-business"
            !geminiApiKey.isNullOrBlank() && files.isEmpty() -> "gemini-api-key"
            else -> "oauth-personal"
        }
        val resolvedTier = planTier ?: when (resolvedMethod) {
            "gemini-api-key" -> "apiKey"
            "oauth-business" -> "enterprise"
            else -> "free"
        }
        val displayName = profileObj?.optString("displayName")?.takeIf { it.isNotBlank() }
            ?: email
            ?: if (!gcpProject.isNullOrBlank()) "Enterprise ($gcpProject)"
            else if (!geminiApiKey.isNullOrBlank() && files.isEmpty()) "Gemini API Key"
            else "Google Account"

        val id = when {
            !email.isNullOrBlank() -> "email_${sha256Short(email.trim().lowercase())}"
            !gcpProject.isNullOrBlank() -> "gcp_${sha256Short("$gcpProject:${gcpLocation ?: "global"}")}"
            !geminiApiKey.isNullOrBlank() -> "apikey_${sha256Short(geminiApiKey.trim())}"
            !preferredId.isNullOrBlank() -> preferredId
            else -> "acct_${UUID.randomUUID().toString().replace("-", "").take(16)}"
        }

        val existing = existingIndex.accounts.firstOrNull { it.id == id }
        val now = System.currentTimeMillis()
        return AccountMeta(
            id = id,
            email = email,
            displayName = displayName,
            method = resolvedMethod,
            planTier = resolvedTier,
            gcpProject = gcpProject,
            gcpLocation = gcpLocation,
            hasApiKey = !geminiApiKey.isNullOrBlank(),
            fileCount = files.size,
            addedAtMs = existing?.addedAtMs ?: now,
            lastUsedAtMs = now,
        )
    }

    private fun upsertAccountLocked(index: VaultIndex, meta: AccountMeta) {
        val pos = index.accounts.indexOfFirst { it.id == meta.id }
        if (pos >= 0) {
            index.accounts[pos] = meta
        } else {
            index.accounts.add(meta)
        }
    }

    private fun loadIndexLocked(accountsDir: File): VaultIndex {
        val indexFile = File(accountsDir, INDEX_FILE)
        if (!indexFile.isFile) return VaultIndex(null, mutableListOf())
        return runCatching {
            val root = JSONObject(indexFile.readText())
            val activeId = root.optString("activeAccountId").takeIf { it.isNotBlank() }
            val arr = root.optJSONArray("accounts") ?: JSONArray()
            val list = mutableListOf<AccountMeta>()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                AccountMeta.fromJson(obj)?.let(list::add)
            }
            VaultIndex(activeId, list)
        }.getOrElse { VaultIndex(null, mutableListOf()) }
    }

    private fun saveIndexLocked(accountsDir: File, index: VaultIndex) {
        accountsDir.mkdirs()
        lockOwnerOnly(accountsDir)
        val arr = JSONArray()
        for (a in index.accounts) {
            arr.put(a.toJson())
        }
        val root = JSONObject()
            .put("accounts", arr)
        if (!index.activeAccountId.isNullOrBlank()) {
            root.put("activeAccountId", index.activeAccountId)
        }
        val file = File(accountsDir, INDEX_FILE)
        file.writeText(root.toString(2))
        lockOwnerOnly(file)
    }

    private fun writeSnapshotLocked(
        accountsDir: File,
        accountId: String,
        files: Map<String, String>,
        geminiApiKey: String?,
        authProfileJson: String?,
    ) {
        val dir = File(accountsDir, sanitizeId(accountId))
        dir.mkdirs()
        lockOwnerOnly(dir)
        val filesObj = JSONObject()
        for ((k, v) in files) {
            filesObj.put(k, v)
        }
        val snap = JSONObject().put("files", filesObj)
        if (!geminiApiKey.isNullOrBlank()) snap.put("geminiApiKey", geminiApiKey)
        if (!authProfileJson.isNullOrBlank()) snap.put("authProfileJson", authProfileJson)
        val snapFile = File(dir, SNAPSHOT_FILE)
        snapFile.writeText(snap.toString())
        lockOwnerOnly(snapFile)
    }

    private fun readSnapshotLocked(
        accountsDir: File,
        accountId: String,
    ): CredentialTransferHelper.DecryptedPayload? {
        val snapFile = File(accountsDir, "${sanitizeId(accountId)}/$SNAPSHOT_FILE")
        if (!snapFile.isFile) return null
        return runCatching {
            val snap = JSONObject(snapFile.readText())
            val filesObj = snap.optJSONObject("files") ?: JSONObject()
            val map = linkedMapOf<String, String>()
            val keys = filesObj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                map[k] = filesObj.getString(k)
            }
            CredentialTransferHelper.DecryptedPayload(
                files = map,
                geminiApiKey = snap.optString("geminiApiKey").takeIf { it.isNotBlank() },
                authProfileJson = snap.optString("authProfileJson").takeIf { it.isNotBlank() },
            )
        }.getOrNull()
    }

    private fun sanitizeId(id: String): String =
        id.replace(Regex("[^A-Za-z0-9._-]"), "_")

    private fun sha256Short(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }.take(16)
    }

    private fun lockOwnerOnly(file: File) {
        runCatching {
            file.setReadable(false, false)
            file.setReadable(true, true)
            file.setWritable(false, false)
            file.setWritable(true, true)
            if (file.isDirectory) {
                file.setExecutable(false, false)
                file.setExecutable(true, true)
            }
        }
    }
}
