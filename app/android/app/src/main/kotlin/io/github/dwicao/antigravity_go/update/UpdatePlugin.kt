package io.github.dwicao.antigravity_go.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class UpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancelRequested = AtomicBoolean(false)
    private val downloadActive = AtomicBoolean(false)
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var activeConnection: HttpURLConnection? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "agy/update")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "agy/update/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        cancelActiveDownload()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitEvent(map: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(map)
        }
    }

    private fun cancelActiveDownload() {
        cancelRequested.set(true)
        try {
            activeConnection?.disconnect()
        } catch (_: Throwable) {}
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canRequestPackageInstalls" -> {
                val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext.packageManager.canRequestPackageInstalls()
                } else {
                    true
                }
                result.success(allowed)
            }
            "openInstallUnknownAppsSettings" -> {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${appContext.packageName}"),
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        appContext.startActivity(intent)
                    }
                    result.success(true)
                } catch (_: Throwable) {
                    result.success(false)
                }
            }
            "cancelUpdate" -> {
                cancelActiveDownload()
                result.success(true)
            }
            "installFromUrl" -> {
                val urlStr = call.argument<String>("url")
                if (urlStr.isNullOrBlank()) {
                    result.error("bad_url", "Missing APK URL", null)
                    return
                }
                if (!downloadActive.compareAndSet(false, true)) {
                    result.error("update_busy", "An update download is already in progress", null)
                    return
                }
                val expectedSha256 = call.argument<String>("expectedSha256")?.trim()?.lowercase()
                cancelRequested.set(false)
                executor.submit {
                    val apkFile = File(appContext.cacheDir, "antigravity-go-update.apk")
                    try {
                        if (apkFile.exists()) apkFile.delete()
                        val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                            instanceFollowRedirects = true
                            connectTimeout = 20_000
                            readTimeout = 60_000
                        }
                        activeConnection = conn
                        val code = conn.responseCode
                        if (code !in 200..299) {
                            throw IllegalStateException("HTTP $code downloading update")
                        }
                        val total = conn.contentLengthLong
                        var received = 0L
                        val startMs = System.currentTimeMillis()
                        var lastEmitMs = 0L

                        emitEvent(
                            mapOf(
                                "phase" to "downloading",
                                "received" to 0L,
                                "total" to total,
                                "speedBps" to 0L,
                            )
                        )

                        conn.inputStream.use { input ->
                            FileOutputStream(apkFile).use { out ->
                                val buf = ByteArray(64 * 1024)
                                while (true) {
                                    if (cancelRequested.get()) {
                                        throw UpdateCancelledException()
                                    }
                                    val n = input.read(buf)
                                    if (n < 0) break
                                    out.write(buf, 0, n)
                                    received += n.toLong()
                                    val now = System.currentTimeMillis()
                                    if (now - lastEmitMs >= 120L) {
                                        lastEmitMs = now
                                        val elapsedSec = ((now - startMs).coerceAtLeast(1L)) / 1000.0
                                        val speedBps = (received / elapsedSec).toLong()
                                        emitEvent(
                                            mapOf(
                                                "phase" to "downloading",
                                                "received" to received,
                                                "total" to total,
                                                "speedBps" to speedBps,
                                            )
                                        )
                                    }
                                }
                                out.flush()
                            }
                        }

                        if (cancelRequested.get()) {
                            throw UpdateCancelledException()
                        }

                        emitEvent(
                            mapOf(
                                "phase" to "verifying",
                                "received" to received,
                                "total" to if (total > 0) total else received,
                                "speedBps" to 0L,
                            )
                        )

                        if (expectedSha256.isNullOrBlank() || !expectedSha256.matches(Regex("^[0-9a-f]{64}$"))) {
                            apkFile.delete()
                            throw IllegalStateException("Missing or invalid expected APK SHA-256 checksum")
                        }
                        val actualSha = sha256Of(apkFile)
                        if (actualSha != expectedSha256) {
                            apkFile.delete()
                            throw IllegalStateException("APK SHA-256 mismatch")
                        }

                        emitEvent(
                            mapOf(
                                "phase" to "installing",
                                "received" to received,
                                "total" to if (total > 0) total else received,
                                "speedBps" to 0L,
                            )
                        )

                        val uri = FileProvider.getUriForFile(
                            appContext,
                            "${appContext.packageName}.files",
                            apkFile,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        mainHandler.post {
                            try {
                                appContext.startActivity(intent)
                                result.success(
                                    mapOf(
                                        "received" to received,
                                        "total" to if (total > 0) total else received,
                                    )
                                )
                            } catch (t: Throwable) {
                                result.error("install_launch_failed", t.message ?: t.toString(), null)
                            }
                        }
                    } catch (_: UpdateCancelledException) {
                        try {
                            apkFile.delete()
                        } catch (_: Throwable) {}
                        emitEvent(mapOf("phase" to "cancelled"))
                        mainHandler.post {
                            result.error("update_cancelled", "Update cancelled by user", null)
                        }
                    } catch (t: Throwable) {
                        try {
                            apkFile.delete()
                        } catch (_: Throwable) {}
                        val msg = t.message ?: t.toString()
                        emitEvent(mapOf("phase" to "failed", "error" to msg))
                        mainHandler.post {
                            result.error("update_failed", msg, null)
                        }
                    } finally {
                        downloadActive.set(false)
                        try {
                            activeConnection?.disconnect()
                        } catch (_: Throwable) {}
                        activeConnection = null
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { fis ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = fis.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private class UpdateCancelledException : RuntimeException()
}
