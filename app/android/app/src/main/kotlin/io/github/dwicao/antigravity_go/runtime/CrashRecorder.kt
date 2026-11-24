package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Pure SSRF & dangerous URI scheme guard (adopted from claude-code-android / DSH-Go):
 * prevents untrusted MCP/agent openUrl calls from hitting cloud metadata endpoints
 * (169.254.169.254 / metadata.google.internal) or dangerous non-web Android schemes.
 */
object UrlSafetyGuard {
    data class Decision(
        val allowed: Boolean,
        val reason: String = "",
    )

    private val blockedHosts = setOf(
        "169.254.169.254",
        "metadata.google.internal",
        "metadata.goog",
        "100.100.100.200",
    )

    fun evaluateUrl(rawUrl: String): Decision {
        val trimmed = rawUrl.trim()
        if (trimmed.isEmpty()) {
            return Decision(false, "URL is empty")
        }
        val uri = runCatching { URI(trimmed) }.getOrNull()
            ?: return Decision(false, "Malformed URL")
        val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
        if (scheme != "http" && scheme != "https") {
            return Decision(false, "Blocked non-HTTP scheme ($scheme)")
        }
        val host = uri.host?.lowercase(Locale.ROOT).orEmpty()
        if (host.isEmpty()) {
            return Decision(false, "URL has no host")
        }
        if (host in blockedHosts || host.startsWith("169.254.")) {
            return Decision(false, "Blocked cloud metadata / link-local host ($host)")
        }
        return Decision(true)
    }
}

/**
 * Process-wide uncaught exception recorder (adopted from OPENCODE-ANDROID / dsh-Go):
 * persists redacted JVM crash stacktraces to app storage so DiagnosticsPage can
 * inspect them cleanly after an unexpected restart.
 */
object CrashRecorder {
    private const val FILE_NAME = "agy_crashes.log"
    private const val MAX_BYTES = 24 * 1024L

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        synchronized(this) {
            if (installed) return
            val appCtx = context.applicationContext
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                runCatching { record(appCtx, thread.name, throwable) }
                previous?.uncaughtException(thread, throwable)
            }
            installed = true
        }
    }

    fun record(context: Context, threadName: String, throwable: Throwable) {
        recordToFile(File(context.filesDir, FILE_NAME), threadName, throwable)
    }

    internal fun recordToFile(file: File, threadName: String, throwable: Throwable) {
        val sw = StringWriter()
        throwable.printStackTrace(PrintWriter(sw))
        val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).format(Date())
        val entry = buildString {
            appendLine("=== Crash @ $stamp (thread=$threadName) ===")
            appendLine(LogRedactor.redact(sw.toString()).take(8192))
        }
        val combined = if (file.exists() && file.length() > MAX_BYTES) {
            entry
        } else {
            val prev = runCatching { file.readText() }.getOrDefault("")
            (prev + "\n" + entry).takeLast(MAX_BYTES.toInt())
        }
        file.parentFile?.mkdirs()
        file.writeText(combined)
    }

    fun readRecent(context: Context): String {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.exists()) return ""
        return runCatching { file.readText() }.getOrDefault("")
    }

    fun clear(context: Context) {
        runCatching { File(context.filesDir, FILE_NAME).delete() }
    }
}
