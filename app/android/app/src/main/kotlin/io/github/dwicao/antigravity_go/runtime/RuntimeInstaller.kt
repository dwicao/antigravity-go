package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.zip.GZIPInputStream

/**
 * Installs and SHA-512 verifies the official Android Antigravity CLI (`agy`) binary
 * inside app-private storage without requiring root or Termux.
 */
object RuntimeInstaller {
    private const val DEFAULT_BASE_URL =
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"

    fun platformKey(abis: Array<String>): String {
        return if (abis.any { it.contains("x86_64") }) {
            "android_amd64"
        } else {
            "android_arm64"
        }
    }

    data class InstallResult(
        val version: String,
        val binaryFile: File,
    )

    fun install(
        runtimeDir: File,
        abis: Array<String>,
        customManifestUrl: String? = null,
        onProgress: (Double, String) -> Unit,
    ): InstallResult {
        val binDir = File(runtimeDir, "bin").apply { mkdirs() }
        val homeDir = File(runtimeDir, "home").apply { mkdirs() }
        val workspaceDir = File(runtimeDir, "workspace").apply { mkdirs() }
        File(homeDir, ".gemini/antigravity-cli").mkdirs()

        val platform = platformKey(abis)
        val manifestUrl = customManifestUrl ?: "$DEFAULT_BASE_URL/manifests/$platform.json"
        val parsedManifestUri = runCatching { java.net.URI(manifestUrl) }.getOrNull()
        val schemeOk = parsedManifestUri?.scheme?.lowercase() == "https" ||
            (parsedManifestUri?.scheme?.lowercase() == "http" &&
                (parsedManifestUri.host == "127.0.0.1" || parsedManifestUri.host == "localhost"))
        if (!schemeOk) {
            throw IllegalArgumentException("Unsupported manifest URL scheme: $manifestUrl")
        }
        onProgress(0.05, "Fetching manifest for $platform…")

        val manifestRaw = downloadText(manifestUrl)
        val manifest = JSONObject(manifestRaw)
        val version = manifest.getString("version")
        val downloadUrl = manifest.getString("url")
        val expectedSha512 = manifest.getString("sha512").lowercase().trim()

        val stagingDir = File(runtimeDir, "staging").apply { mkdirs() }
        val isTarGz = downloadUrl.contains(".tar.gz")
        val payloadFile = File(stagingDir, if (isTarGz) "agy.tar.gz" else "agy.bin")

        onProgress(0.15, "Downloading agy $version ($platform)…")
        downloadFile(downloadUrl, payloadFile) { fraction ->
            onProgress(0.15 + fraction * 0.65, "Downloading agy $version… ${(fraction * 100).toInt()}%")
        }

        onProgress(0.85, "Verifying SHA-512 checksum…")
        val actualSha512 = sha512Hex(payloadFile)
        if (actualSha512 != expectedSha512) {
            payloadFile.delete()
            throw IllegalStateException(
                "SHA-512 mismatch for agy $version: expected $expectedSha512, got $actualSha512"
            )
        }

        val targetBin = File(binDir, "agy")
        val tempBin = File(binDir, "agy.tmp")
        onProgress(0.92, "Extracting binary…")
        if (isTarGz) {
            extractAgyFromTarGz(payloadFile, tempBin)
        } else {
            payloadFile.copyTo(tempBin, overwrite = true)
        }

        tempBin.setExecutable(true, false)
        if (targetBin.exists()) targetBin.delete()
        if (!tempBin.renameTo(targetBin)) {
            tempBin.copyTo(targetBin, overwrite = true)
            tempBin.delete()
        }
        targetBin.setExecutable(true, false)
        File(runtimeDir, "version.txt").writeText(version)
        payloadFile.delete()
        onProgress(1.0, "Installed agy $version (workspace: ${workspaceDir.absolutePath})")
        return InstallResult(version = version, binaryFile = targetBin)
    }

    private fun downloadText(urlStr: String): String {
        val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 20_000
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code fetching $urlStr")
            }
            return conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private fun downloadFile(
        urlStr: String,
        dest: File,
        onFraction: (Double) -> Unit,
    ) {
        val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 60_000
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code downloading $urlStr")
            }
            val total = conn.contentLengthLong.coerceAtLeast(1L)
            var downloaded = 0L
            var lastReportedFraction = -1.0
            conn.inputStream.use { input ->
                FileOutputStream(dest).use { out ->
                    val buf = ByteArray(32 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        downloaded += n
                        val frac = (downloaded.toDouble() / total.toDouble()).coerceIn(0.0, 1.0)
                        if (frac - lastReportedFraction >= 0.02 || frac >= 1.0) {
                            lastReportedFraction = frac
                            onFraction(frac)
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun sha512Hex(file: File): String {
        val md = MessageDigest.getInstance("SHA-512")
        FileInputStream(file).use { fis ->
            val buf = ByteArray(32 * 1024)
            while (true) {
                val n = fis.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Minimal POSIX tar.gz extractor that locates `antigravity` or `agy` binary.
     */
    private fun extractAgyFromTarGz(tarGz: File, dest: File) {
        GZIPInputStream(BufferedInputStream(FileInputStream(tarGz))).use { gz ->
            val header = ByteArray(512)
            while (readExact(gz, header)) {
                if (header.all { it == 0.toByte() }) break
                val name = parseTarString(header, 0, 100)
                val sizeOctal = parseTarString(header, 124, 12).trim()
                val size = if (sizeOctal.isEmpty()) 0L else sizeOctal.toLong(8)
                val typeFlag = header[156].toInt().toChar()

                val isBinary = (typeFlag == '0' || typeFlag == '\u0000') &&
                    (name == "antigravity" || name == "agy" ||
                        name.endsWith("/antigravity") || name.endsWith("/agy"))

                if (isBinary && size > 0) {
                    FileOutputStream(dest).use { out ->
                        copyExact(gz, out, size)
                    }
                    return
                } else {
                    skipExact(gz, size)
                }

                val remainder = (512 - (size % 512)) % 512
                if (remainder > 0) {
                    skipExact(gz, remainder)
                }
            }
        }
        throw IllegalStateException("Archive did not contain agy/antigravity binary")
    }

    private fun parseTarString(buf: ByteArray, offset: Int, len: Int): String {
        var end = offset
        val limit = (offset + len).coerceAtMost(buf.size)
        while (end < limit && buf[end] != 0.toByte()) end++
        return String(buf, offset, end - offset, Charsets.UTF_8)
    }

    private fun readExact(input: InputStream, buf: ByteArray): Boolean {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) return false
            off += n
        }
        return true
    }

    private fun copyExact(input: InputStream, out: FileOutputStream, total: Long) {
        val buf = ByteArray(16 * 1024)
        var left = total
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            out.write(buf, 0, n)
            left -= n
        }
    }

    private fun skipExact(input: InputStream, total: Long) {
        val buf = ByteArray(8192)
        var left = total
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            left -= n
        }
    }
}
