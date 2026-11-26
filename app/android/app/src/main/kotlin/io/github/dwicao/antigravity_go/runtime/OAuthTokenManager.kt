package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64

/**
 * Keeps Google OAuth credentials (`antigravity-oauth-token` / `oauth_creds.json`)
 * continuously fresh across cold boots, device exports, account switches, and
 * background sessions by proactively exchanging `refresh_token`s via Android's
 * native HTTPS stack before invoking `agy`.
 */
object OAuthTokenManager {
    const val TOKEN_REL_PATH = ".gemini/antigravity-cli/antigravity-oauth-token"
    const val ALT_CREDS_REL_PATH = ".gemini/oauth_creds.json"
    const val OAUTH_CLIENT_CACHE_REL_PATH = ".gemini/antigravity-go-oauth-client.json"
    const val DEFAULT_LEEWAY_MS = 15 * 60_000L
    const val EXPORT_LEEWAY_MS = 30 * 60_000L
    const val DORMANT_ACCOUNT_REFRESH_MS = 6 * 60 * 60_000L

    private const val OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
    private val CLIENT_ID_SUFFIX_BYTES = ".apps.googleusercontent.com".toByteArray(Charsets.US_ASCII)
    private val CLIENT_SECRET_PREFIX_BYTES = "GOCSPX-".toByteArray(Charsets.US_ASCII)

    private val fileLock = Any()

    data class ClientCredentials(
        val clientId: String,
        val clientSecret: String,
    )

    data class DiscoveredClients(
        val clientIds: List<String>,
        val clientSecrets: List<String>,
    )

    data class HttpResult(
        val statusCode: Int,
        val body: String,
    )

    fun interface TokenHttpTransport {
        fun postForm(url: String, params: Map<String, String>): HttpResult
    }

    sealed class RefreshOutcome {
        data object NotNeeded : RefreshOutcome()
        data object NoRefreshToken : RefreshOutcome()
        data class Refreshed(
            val email: String?,
            val expiresAtMs: Long,
            val updatedJson: String,
            val relPath: String,
        ) : RefreshOutcome()

        data class PermanentError(
            val errorCode: String,
            val description: String,
        ) : RefreshOutcome()

        data class TransientError(
            val detail: String,
        ) : RefreshOutcome()
    }

    data class FileMapRefreshResult(
        val files: Map<String, String>,
        val outcome: RefreshOutcome,
    )

    @Volatile
    private var cachedBinaryPath: String? = null

    @Volatile
    private var cachedDiscovered: DiscoveredClients? = null

    private val defaultTransport = TokenHttpTransport { urlStr, params ->
        val encoded = params.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 8000
            readTimeout = 10000
            doOutput = true
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            setRequestProperty("Accept", "application/json")
        }
        try {
            conn.outputStream.use { os ->
                os.write(encoded.toByteArray(Charsets.UTF_8))
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else (conn.errorStream ?: conn.inputStream)
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            HttpResult(code, body)
        } finally {
            conn.disconnect()
        }
    }

    fun parseExpiryMillis(container: JSONObject): Long? {
        val rawExpiry = container.optString("expiry").trim()
        if (rawExpiry.isNotEmpty()) {
            runCatching {
                return OffsetDateTime.parse(rawExpiry).toInstant().toEpochMilli()
            }
            runCatching {
                return Instant.parse(rawExpiry).toEpochMilli()
            }
        }
        val epochMs = container.optLong("expiry_date", -1L)
        if (epochMs > 0L) return epochMs
        return null
    }

    fun resolveTokenExpiryMillis(homeDir: File): Long? {
        for (rel in listOf(TOKEN_REL_PATH, ALT_CREDS_REL_PATH)) {
            val file = File(homeDir, rel)
            if (!file.isFile) continue
            val parsed = runCatching {
                val root = JSONObject(file.readText())
                val container = if (root.has("token")) root.optJSONObject("token") else root
                if (container != null) parseExpiryMillis(container) else null
            }.getOrNull()
            if (parsed != null) return parsed
        }
        return null
    }

    fun discoverClientsFromBinary(binaryFile: File?): DiscoveredClients {
        if (binaryFile == null || !binaryFile.isFile) {
            return DiscoveredClients(emptyList(), emptyList())
        }
        val path = binaryFile.absolutePath
        if (cachedBinaryPath == path) {
            cachedDiscovered?.let { return it }
        }
        val ids = LinkedHashSet<String>()
        val secrets = LinkedHashSet<String>()
        val chunkSize = 1024 * 1024
        val overlap = 256
        val buf = ByteArray(chunkSize + overlap)
        var validPrefix = 0

        runCatching {
            FileInputStream(binaryFile).use { fis ->
                while (true) {
                    val read = fis.read(buf, validPrefix, chunkSize)
                    if (read <= 0) break
                    val total = validPrefix + read
                    scanBufferForClientIds(buf, total, ids)
                    scanBufferForClientSecrets(buf, total, secrets)
                    if (ids.size >= 8 && secrets.size >= 8) break
                    if (total > overlap) {
                        System.arraycopy(buf, total - overlap, buf, 0, overlap)
                        validPrefix = overlap
                    } else {
                        validPrefix = total
                    }
                }
            }
        }

        val discovered = DiscoveredClients(
            clientIds = ids.toList(),
            clientSecrets = secrets.toList(),
        )
        if (discovered.clientIds.isNotEmpty() || discovered.clientSecrets.isNotEmpty()) {
            cachedBinaryPath = path
            cachedDiscovered = discovered
        }
        return discovered
    }

    private fun scanBufferForClientIds(buf: ByteArray, len: Int, out: MutableSet<String>) {
        val suffix = CLIENT_ID_SUFFIX_BYTES
        val sLen = suffix.size
        val first = suffix[0]
        var i = 0
        while (i <= len - sLen) {
            if (buf[i] == first && matchesAt(buf, i, suffix)) {
                var start = i - 1
                while (start >= 0 && isClientIdChar(buf[start]) && (i - start) <= 96) {
                    start--
                }
                start++
                val prefixLen = i - start
                if (prefixLen >= 16) {
                    val candidate = String(buf, start, prefixLen + sLen, Charsets.US_ASCII)
                    val dashIdx = candidate.indexOf('-')
                    if (dashIdx >= 6 && candidate.substring(0, dashIdx).all { it.isDigit() }) {
                        out.add(candidate)
                    }
                }
                i += sLen
            } else {
                i++
            }
        }
    }

    private fun scanBufferForClientSecrets(buf: ByteArray, len: Int, out: MutableSet<String>) {
        val prefix = CLIENT_SECRET_PREFIX_BYTES
        val pLen = prefix.size
        val first = prefix[0]
        var i = 0
        while (i <= len - pLen) {
            if (buf[i] == first && matchesAt(buf, i, prefix)) {
                var end = i + pLen
                while (end < len && isSecretChar(buf[end]) && (end - i) <= 64) {
                    end++
                }
                if (end - i >= 20) {
                    out.add(String(buf, i, end - i, Charsets.US_ASCII))
                }
                i = end
            } else {
                i++
            }
        }
    }

    private fun matchesAt(buf: ByteArray, offset: Int, needle: ByteArray): Boolean {
        for (j in needle.indices) {
            if (buf[offset + j] != needle[j]) return false
        }
        return true
    }

    private fun isClientIdChar(b: Byte): Boolean {
        val c = b.toInt().toChar()
        return c.isLetterOrDigit() || c == '-' || c == '_'
    }

    private fun isSecretChar(b: Byte): Boolean {
        val c = b.toInt().toChar()
        return c.isLetterOrDigit() || c == '-' || c == '_'
    }

    private fun buildCandidateClientPairs(
        root: JSONObject,
        container: JSONObject,
        cachedClient: ClientCredentials?,
        binaryFile: File?,
    ): List<ClientCredentials> {
        val out = LinkedHashSet<ClientCredentials>()
        val explicitId = root.optString("client_id").takeIf { it.isNotBlank() }
            ?: container.optString("client_id").takeIf { it.isNotBlank() }
        val explicitSecret = root.optString("client_secret").takeIf { it.isNotBlank() }
            ?: container.optString("client_secret").takeIf { it.isNotBlank() }
        if (explicitId != null) {
            out.add(ClientCredentials(explicitId, explicitSecret.orEmpty()))
        }
        if (cachedClient != null && cachedClient.clientId.isNotBlank()) {
            out.add(cachedClient)
        }
        val discovered = discoverClientsFromBinary(binaryFile)
        for (cid in discovered.clientIds) {
            for (sec in discovered.clientSecrets) {
                out.add(ClientCredentials(cid, sec))
            }
            if (discovered.clientSecrets.isEmpty()) {
                out.add(ClientCredentials(cid, ""))
            }
        }
        return out.toList()
    }

    private fun readCachedClient(homeDir: File?): ClientCredentials? {
        if (homeDir == null) return null
        val file = File(homeDir, OAUTH_CLIENT_CACHE_REL_PATH)
        if (!file.isFile) return null
        return runCatching {
            val obj = JSONObject(file.readText())
            val id = obj.optString("client_id").trim()
            val sec = obj.optString("client_secret").trim()
            if (id.isNotEmpty()) ClientCredentials(id, sec) else null
        }.getOrNull()
    }

    private fun saveCachedClient(homeDir: File?, creds: ClientCredentials) {
        if (homeDir == null || creds.clientId.isBlank()) return
        runCatching {
            val file = File(homeDir, OAUTH_CLIENT_CACHE_REL_PATH)
            val obj = JSONObject()
                .put("client_id", creds.clientId)
                .put("client_secret", creds.clientSecret)
            writeAtomicPrivate(file, obj.toString(2))
        }
    }

    fun ensureFreshTokenInJson(
        rawJson: String,
        relPath: String = TOKEN_REL_PATH,
        force: Boolean = false,
        minRemainingMs: Long = DEFAULT_LEEWAY_MS,
        clientCredentials: ClientCredentials? = null,
        binaryFile: File? = null,
        homeDirForClientCache: File? = null,
        transport: TokenHttpTransport = defaultTransport,
        nowMs: () -> Long = { System.currentTimeMillis() },
    ): RefreshOutcome {
        val root = runCatching { JSONObject(rawJson) }.getOrNull() ?: return RefreshOutcome.NoRefreshToken
        val hasNestedToken = root.has("token")
        val container = if (hasNestedToken) {
            root.optJSONObject("token") ?: return RefreshOutcome.NoRefreshToken
        } else {
            root
        }

        val refreshToken = container.optString("refresh_token").trim()
        if (refreshToken.isEmpty()) {
            return RefreshOutcome.NoRefreshToken
        }

        val accessToken = container.optString("access_token").trim()
        val expiryMs = parseExpiryMillis(container)
        val currentMs = nowMs()
        if (!force &&
            accessToken.isNotEmpty() &&
            expiryMs != null &&
            (expiryMs - currentMs) > minRemainingMs
        ) {
            return RefreshOutcome.NotNeeded
        }

        val candidates = buildCandidateClientPairs(
            root = root,
            container = container,
            cachedClient = clientCredentials ?: readCachedClient(homeDirForClientCache),
            binaryFile = binaryFile,
        )
        if (candidates.isEmpty()) {
            return RefreshOutcome.TransientError("No OAuth client metadata available yet")
        }

        var lastTransient: RefreshOutcome.TransientError? = null
        var lastPermanent: RefreshOutcome.PermanentError? = null
        for (pair in candidates) {
            val form = linkedMapOf(
                "client_id" to pair.clientId,
                "refresh_token" to refreshToken,
                "grant_type" to "refresh_token",
            )
            if (pair.clientSecret.isNotEmpty()) {
                form["client_secret"] = pair.clientSecret
            }

            val httpRes = try {
                transport.postForm(OAUTH_TOKEN_URL, form)
            } catch (t: Throwable) {
                lastTransient = RefreshOutcome.TransientError(t.message ?: t.javaClass.simpleName)
                break
            }

            val respObj = runCatching { JSONObject(httpRes.body) }.getOrNull()
            if (httpRes.statusCode in 200..299 && respObj != null) {
                val newAccess = respObj.optString("access_token").trim()
                if (newAccess.isEmpty()) {
                    lastTransient = RefreshOutcome.TransientError("OAuth response missing access_token")
                    continue
                }
                val expiresIn = respObj.optLong("expires_in", 3599L).coerceAtLeast(60L)
                val newExpiryMs = currentMs + expiresIn * 1000L
                val newExpiryIso = DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(
                    Instant.ofEpochMilli(newExpiryMs).atOffset(ZoneOffset.UTC)
                )
                container.put("access_token", newAccess)
                container.put("expires_in", expiresIn)
                if (container.has("expiry") || hasNestedToken || !container.has("expiry_date")) {
                    container.put("expiry", newExpiryIso)
                }
                if (container.has("expiry_date")) {
                    container.put("expiry_date", newExpiryMs)
                }
                val tokenType = respObj.optString("token_type").trim()
                if (tokenType.isNotEmpty()) {
                    container.put("token_type", tokenType)
                }
                val rotatedRefresh = respObj.optString("refresh_token").trim()
                if (rotatedRefresh.isNotEmpty()) {
                    container.put("refresh_token", rotatedRefresh)
                }
                if (clientCredentials == null) {
                    saveCachedClient(homeDirForClientCache, pair)
                }
                val email = root.optString("id_token_email").takeIf { it.isNotBlank() }
                    ?: root.optString("email").takeIf { it.isNotBlank() }
                return RefreshOutcome.Refreshed(
                    email = email,
                    expiresAtMs = newExpiryMs,
                    updatedJson = root.toString(2),
                    relPath = relPath,
                )
            }

            val errorCode = respObj?.optString("error")?.trim().orEmpty()
            val desc = respObj?.optString("error_description")?.trim().orEmpty()
            if (httpRes.statusCode in 400..499 && errorCode == "invalid_grant") {
                return RefreshOutcome.PermanentError(errorCode, desc)
            }
            if (httpRes.statusCode in 400..499 &&
                (errorCode == "invalid_client" || errorCode == "unauthorized_client")
            ) {
                lastPermanent = RefreshOutcome.PermanentError(errorCode, desc)
                continue
            }
            val detail = if (errorCode.isNotEmpty()) {
                "HTTP ${httpRes.statusCode} $errorCode: $desc".trim()
            } else {
                "HTTP ${httpRes.statusCode}"
            }
            lastTransient = RefreshOutcome.TransientError(detail)
        }
        return lastTransient ?: lastPermanent ?: RefreshOutcome.TransientError("OAuth refresh unsuccessful")
    }

    fun ensureFreshTokenInHome(
        homeDir: File,
        binaryFile: File? = null,
        force: Boolean = false,
        minRemainingMs: Long = DEFAULT_LEEWAY_MS,
        clientCredentials: ClientCredentials? = null,
        transport: TokenHttpTransport = defaultTransport,
        nowMs: () -> Long = { System.currentTimeMillis() },
    ): RefreshOutcome = synchronized(fileLock) {
        val resolvedBinary = binaryFile ?: defaultBinaryFile(homeDir)
        val candidates = listOf(TOKEN_REL_PATH, ALT_CREDS_REL_PATH)
        for (rel in candidates) {
            val file = File(homeDir, rel)
            if (!file.isFile || file.length() <= 2) continue
            val raw = runCatching { file.readText() }.getOrNull() ?: continue
            val outcome = ensureFreshTokenInJson(
                rawJson = raw,
                relPath = rel,
                force = force,
                minRemainingMs = minRemainingMs,
                clientCredentials = clientCredentials,
                binaryFile = resolvedBinary,
                homeDirForClientCache = homeDir,
                transport = transport,
                nowMs = nowMs,
            )
            when (outcome) {
                is RefreshOutcome.Refreshed -> {
                    writeAtomicPrivate(file, outcome.updatedJson)
                    touchAuthMarker(homeDir, outcome.email, nowMs())
                    return outcome
                }
                is RefreshOutcome.PermanentError,
                is RefreshOutcome.TransientError,
                RefreshOutcome.NotNeeded -> return outcome
                RefreshOutcome.NoRefreshToken -> continue
            }
        }
        return RefreshOutcome.NoRefreshToken
    }

    fun ensureFreshTokenInFileMap(
        files: Map<String, String>,
        binaryFile: File? = null,
        homeDirForClientCache: File? = null,
        force: Boolean = false,
        minRemainingMs: Long = DEFAULT_LEEWAY_MS,
        clientCredentials: ClientCredentials? = null,
        transport: TokenHttpTransport = defaultTransport,
        nowMs: () -> Long = { System.currentTimeMillis() },
    ): FileMapRefreshResult {
        val resolvedBinary = binaryFile ?: homeDirForClientCache?.let(::defaultBinaryFile)
        val decoder = Base64.getDecoder()
        val encoder = Base64.getEncoder()
        for (rel in listOf(TOKEN_REL_PATH, ALT_CREDS_REL_PATH)) {
            val b64 = files[rel] ?: continue
            val raw = runCatching { String(decoder.decode(b64), Charsets.UTF_8) }.getOrNull() ?: continue
            val outcome = ensureFreshTokenInJson(
                rawJson = raw,
                relPath = rel,
                force = force,
                minRemainingMs = minRemainingMs,
                clientCredentials = clientCredentials,
                binaryFile = resolvedBinary,
                homeDirForClientCache = homeDirForClientCache,
                transport = transport,
                nowMs = nowMs,
            )
            if (outcome is RefreshOutcome.Refreshed) {
                val next = LinkedHashMap(files)
                next[rel] = encoder.encodeToString(outcome.updatedJson.toByteArray(Charsets.UTF_8))
                return FileMapRefreshResult(files = next, outcome = outcome)
            }
            if (outcome != RefreshOutcome.NoRefreshToken) {
                return FileMapRefreshResult(files = files, outcome = outcome)
            }
        }
        return FileMapRefreshResult(files = files, outcome = RefreshOutcome.NoRefreshToken)
    }

    private fun defaultBinaryFile(homeDir: File): File? {
        val runtimeDir = homeDir.parentFile ?: return null
        val bin = File(runtimeDir, "bin/agy")
        return if (bin.isFile) bin else null
    }

    private fun touchAuthMarker(homeDir: File, email: String?, updatedAtMs: Long) {
        val marker = File(homeDir, ".gemini/antigravity-go-auth.json")
        if (!marker.isFile) return
        runCatching {
            val obj = JSONObject(marker.readText())
            obj.put("isAuthenticated", true)
            obj.put("updatedAt", updatedAtMs)
            if (!email.isNullOrBlank() && obj.optString("email").isBlank()) {
                obj.put("email", email)
            }
            writeAtomicPrivate(marker, obj.toString(2))
        }
    }

    private fun writeAtomicPrivate(file: File, content: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, ".${file.name}.tmp")
        tmp.writeText(content, Charsets.UTF_8)
        lockOwnerOnly(tmp)
        if (!tmp.renameTo(file)) {
            file.writeText(content, Charsets.UTF_8)
            tmp.delete()
        }
        lockOwnerOnly(file)
    }

    private fun lockOwnerOnly(file: File) {
        runCatching {
            file.setReadable(false, false)
            file.setReadable(true, true)
            file.setWritable(false, false)
            file.setWritable(true, true)
        }
    }
}
