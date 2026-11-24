package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Passphrase-encrypted credential backup & restore helper (AES-256-GCM + PBKDF2WithHmacSHA256)
 * for transferring signed-in Google OAuth tokens, CLI settings, and optional API keys
 * across Android devices without logging in again.
 */
object CredentialTransferHelper {
    private const val BUNDLE_FORMAT = "antigravity-go-creds-v1"
    private const val KDF_ALGORITHM = "PBKDF2WithHmacSHA256"
    private const val KDF_ITERATIONS = 120_000
    private const val KEY_BITS = 256
    private const val GCM_TAG_BITS = 128
    private const val MAX_FILE_BYTES = 512 * 1024L

    private val explicitRelativePaths = listOf(
        ".gemini/antigravity-go-auth.json",
        ".gemini/antigravity-cli/antigravity-oauth-token",
        ".gemini/antigravity-cli/credentials.json",
        ".gemini/antigravity-cli/cache/acp-auth-state.json",
        ".gemini/antigravity-cli/settings.json",
        ".gemini/antigravity-cli/jetski_state.pbtxt",
        ".gemini/oauth_creds.json",
        ".gemini/google_accounts.json",
        ".gemini/antigravity_state.pbtxt",
        ".gemini/config/config.json",
    )

    private val excludedDirs = setOf(
        "log",
        "annotations",
        "brain",
        "builtin",
        "presence",
        "tmp",
        "bin",
    )

    fun isAllowedRelativePath(raw: String): Boolean {
        if (raw.isBlank() || raw.startsWith("/") || raw.contains("\\")) return false
        val segments = raw.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) return false
        return raw.startsWith(".gemini/") ||
            raw.startsWith(".config/antigravity") ||
            raw.startsWith(".local/share/antigravity")
    }

    fun collectCredentialFiles(homeDir: File): Map<String, String> {
        val encoder = Base64.getEncoder()
        val result = linkedMapOf<String, String>()

        fun addIfValid(file: File, relPath: String) {
            if (!isAllowedRelativePath(relPath)) return
            if (!file.isFile || file.length() <= 0 || file.length() > MAX_FILE_BYTES) return
            val bytes = runCatching { file.readBytes() }.getOrNull() ?: return
            result[relPath] = encoder.encodeToString(bytes)
        }

        for (rel in explicitRelativePaths) {
            addIfValid(File(homeDir, rel), rel)
        }

        val roots = listOf(
            File(homeDir, ".gemini"),
            File(homeDir, ".config/antigravity"),
            File(homeDir, ".config/antigravity-cli"),
            File(homeDir, ".local/share/antigravity"),
        )
        for (root in roots) {
            if (!root.exists()) continue
            root.walkTopDown()
                .onEnter { dir -> dir.name !in excludedDirs }
                .maxDepth(4)
                .forEach { f ->
                    if (!f.isFile || f.name.endsWith(".lock")) return@forEach
                    val lower = f.name.lowercase()
                    val looksLikeAuth = lower.contains("cred") ||
                        lower.contains("oauth") ||
                        lower.contains("token") ||
                        lower.contains("account") ||
                        lower.contains("auth") ||
                        lower.endsWith(".pbtxt")
                    if (!looksLikeAuth) return@forEach
                    val rel = runCatching { f.relativeTo(homeDir).invariantSeparatorsPath }.getOrNull()
                        ?: return@forEach
                    if (!result.containsKey(rel)) {
                        addIfValid(f, rel)
                    }
                }
        }
        return result
    }

    fun restoreCredentialFiles(
        homeDir: File,
        files: Map<String, String>,
        fallbackEmail: String? = null,
    ): Int {
        val decoder = Base64.getDecoder()
        val canonicalHome = homeDir.canonicalFile
        var restored = 0

        for ((relPath, b64) in files) {
            if (!isAllowedRelativePath(relPath)) {
                throw IllegalArgumentException("Blocked unsafe path in credentials bundle: $relPath")
            }
            val bytes = runCatching { decoder.decode(b64) }.getOrNull()
                ?: throw IllegalArgumentException("Malformed file payload for $relPath")
            if (bytes.size > MAX_FILE_BYTES) {
                throw IllegalArgumentException("Credential file exceeds size limit: $relPath")
            }
            val target = File(homeDir, relPath).canonicalFile
            val homePrefix = canonicalHome.path + File.separator
            if (!target.path.startsWith(homePrefix)) {
                throw IllegalArgumentException("Path escaped home directory: $relPath")
            }
            target.parentFile?.mkdirs()
            target.writeBytes(bytes)
            // Lock restored secret files down to owner-only permissions on Android/POSIX.
            runCatching {
                target.setReadable(false, false)
                target.setReadable(true, true)
                target.setWritable(false, false)
                target.setWritable(true, true)
            }
            restored++
        }

        // Ensure native auth marker exists if credentials were restored without one.
        val marker = File(homeDir, ".gemini/antigravity-go-auth.json")
        if (restored > 0 && !marker.exists()) {
            marker.parentFile?.mkdirs()
            val obj = JSONObject()
                .put("isAuthenticated", true)
                .put("method", "oauth-personal")
                .put("updatedAt", System.currentTimeMillis())
            if (!fallbackEmail.isNullOrBlank()) {
                obj.put("email", fallbackEmail)
            }
            marker.writeText(obj.toString(2))
            runCatching {
                marker.setReadable(false, false)
                marker.setReadable(true, true)
                marker.setWritable(false, false)
                marker.setWritable(true, true)
            }
        }
        return restored
    }

    fun encrypt(plainBytes: ByteArray, passphrase: String): String {
        val clean = passphrase.trim()
        require(clean.length >= 4) { "Passphrase must be at least 4 characters" }

        val rng = SecureRandom()
        val salt = ByteArray(16).also(rng::nextBytes)
        val iv = ByteArray(12).also(rng::nextBytes)
        val key = deriveAesKey(clean, salt)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        val encrypted = cipher.doFinal(plainBytes)

        val encoder = Base64.getEncoder()
        return JSONObject()
            .put("format", BUNDLE_FORMAT)
            .put("kdf", KDF_ALGORITHM)
            .put("iter", KDF_ITERATIONS)
            .put("salt", encoder.encodeToString(salt))
            .put("iv", encoder.encodeToString(iv))
            .put("ciphertext", encoder.encodeToString(encrypted))
            .toString(2)
    }

    fun decrypt(bundleJson: String, passphrase: String): ByteArray {
        val clean = passphrase.trim()
        require(clean.isNotEmpty()) { "Passphrase is required" }

        val envelope = runCatching { JSONObject(bundleJson) }.getOrNull()
            ?: throw IllegalArgumentException("Invalid credentials bundle JSON")
        if (envelope.optString("format") != BUNDLE_FORMAT) {
            throw IllegalArgumentException("Unsupported credentials bundle format")
        }

        val decoder = Base64.getDecoder()
        val salt = runCatching { decoder.decode(envelope.getString("salt")) }.getOrNull()
            ?: throw IllegalArgumentException("Missing salt in bundle")
        val iv = runCatching { decoder.decode(envelope.getString("iv")) }.getOrNull()
            ?: throw IllegalArgumentException("Missing IV in bundle")
        val ciphertext = runCatching { decoder.decode(envelope.getString("ciphertext")) }.getOrNull()
            ?: throw IllegalArgumentException("Missing ciphertext in bundle")

        val iterations = envelope.optInt("iter", KDF_ITERATIONS).coerceIn(10_000, 600_000)
        val key = deriveAesKey(clean, salt, iterations)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        return try {
            cipher.doFinal(ciphertext)
        } catch (_: AEADBadTagException) {
            throw IllegalArgumentException("Wrong passphrase or corrupted credentials bundle")
        }
    }

    fun exportEncryptedBundle(
        homeDir: File,
        passphrase: String,
        geminiApiKey: String? = null,
        authProfileJson: String? = null,
    ): String {
        val files = collectCredentialFiles(homeDir)
        if (files.isEmpty() && geminiApiKey.isNullOrBlank() && authProfileJson.isNullOrBlank()) {
            throw IllegalStateException("No saved credentials found on this device")
        }
        val filesObj = JSONObject()
        for ((k, v) in files) {
            filesObj.put(k, v)
        }
        val payload = JSONObject()
            .put("version", 1)
            .put("exportedAtMs", System.currentTimeMillis())
            .put("files", filesObj)
        if (!geminiApiKey.isNullOrBlank()) {
            payload.put("geminiApiKey", geminiApiKey)
        }
        if (!authProfileJson.isNullOrBlank()) {
            payload.put("authProfileJson", authProfileJson)
        }
        return encrypt(payload.toString().toByteArray(Charsets.UTF_8), passphrase)
    }

    fun importEncryptedBundle(
        homeDir: File,
        bundleJson: String,
        passphrase: String,
    ): Map<String, Any?> {
        val plainBytes = decrypt(bundleJson, passphrase)
        val payload = runCatching { JSONObject(String(plainBytes, Charsets.UTF_8)) }.getOrNull()
            ?: throw IllegalArgumentException("Corrupted credential payload")

        val filesObj = payload.optJSONObject("files") ?: JSONObject()
        val fileMap = linkedMapOf<String, String>()
        val keys = filesObj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            fileMap[k] = filesObj.getString(k)
        }

        val authProfileJson = payload.optString("authProfileJson").takeIf { it.isNotBlank() }
        val fallbackEmail = authProfileJson?.let { raw ->
            runCatching { JSONObject(raw).optString("email").takeIf { it.isNotBlank() } }.getOrNull()
        }
        val restoredCount = restoreCredentialFiles(homeDir, fileMap, fallbackEmail)
        val geminiApiKey = payload.optString("geminiApiKey").takeIf { it.isNotBlank() }

        return mapOf(
            "restoredFiles" to restoredCount,
            "geminiApiKey" to geminiApiKey,
            "authProfileJson" to authProfileJson,
        )
    }

    private fun deriveAesKey(
        passphrase: String,
        salt: ByteArray,
        iterations: Int = KDF_ITERATIONS,
    ): SecretKeySpec {
        val factory = SecretKeyFactory.getInstance(KDF_ALGORITHM)
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, iterations, KEY_BITS)
        val secret = factory.generateSecret(spec)
        return SecretKeySpec(secret.encoded, "AES")
    }
}
