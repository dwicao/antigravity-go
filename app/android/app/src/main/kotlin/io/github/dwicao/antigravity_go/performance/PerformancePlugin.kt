package io.github.dwicao.antigravity_go.performance

import android.app.ActivityManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.dwicao.antigravity_go.runtime.CrashRecorder
import java.io.File

/**
 * Pure classification & display refresh-rate helpers, adopted from DSH Go so JVM unit
 * tests can verify device tier classification without Android Context/framework fakes.
 */
object PerformanceClassifier {
    fun classifyDeviceTier(totalRamMb: Long, cpuCores: Int): String = when {
        totalRamMb in 1..4600 || cpuCores <= 4 -> "low"
        totalRamMb >= 7500 && cpuCores >= 8 -> "high"
        else -> "medium"
    }

    fun isThermalLightweight(thermalStatus: Int): Boolean =
        thermalStatus >= PowerManager.THERMAL_STATUS_SEVERE

    fun normalizeRefreshMode(raw: String?): String = when (raw?.lowercase()) {
        "max", "system", "auto" -> raw.lowercase()
        else -> "auto"
    }
}

object RefreshRateCoordinator {
    @Volatile
    var mode: String = "auto"
        private set

    @Volatile
    var onModeChanged: (() -> Unit)? = null

    fun setMode(raw: String?) {
        mode = PerformanceClassifier.normalizeRefreshMode(raw)
        onModeChanged?.invoke()
    }
}

/**
 * Bridges hardware tier / thermal snapshot, display refresh-rate voting, battery
 * optimization exemption, and Android share/Download exports (`agy/performance`).
 */
class PerformancePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(snapshot())
            "setRefreshRateMode" -> {
                RefreshRateCoordinator.setMode(call.argument<String>("mode"))
                result.success(RefreshRateCoordinator.mode)
            }
            "batteryStatus" -> result.success(
                mapOf(
                    "ignoringOptimizations" to isIgnoringBatteryOptimizations(),
                    "manufacturer" to (Build.MANUFACTURER ?: ""),
                    "model" to (Build.MODEL ?: ""),
                    "sdkInt" to Build.VERSION.SDK_INT,
                ),
            )
            "requestIgnoreBatteryOptimizations" -> {
                result.success(openIgnoreBatteryOptimizations())
            }
            "openBatterySettings" -> {
                result.success(openBatterySettings())
            }
            "shareText" -> {
                val title = call.argument<String>("title") ?: "Antigravity Go"
                val text = call.argument<String>("text") ?: ""
                result.success(shareTextIntent(title, text))
            }
            "saveToDownloads" -> {
                val filename = call.argument<String>("filename") ?: "export.txt"
                val mime = call.argument<String>("mimeType") ?: "text/plain"
                val bytes = call.argument<ByteArray>("bytes")
                    ?: call.argument<String>("text")?.toByteArray(Charsets.UTF_8)
                    ?: ByteArray(0)
                result.success(saveBytesToDownloads(filename, mime, bytes))
            }
            "recentCrashLog" -> result.success(CrashRecorder.readRecent(appContext))
            "clearCrashLog" -> {
                CrashRecorder.clear(appContext)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return runCatching {
            val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
            pm?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
        }.getOrDefault(false)
    }

    private fun openIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return runCatching {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${appContext.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        }.getOrElse { openBatterySettings() }
    }

    private fun openBatterySettings(): Boolean = runCatching {
        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
        true
    }.getOrDefault(false)

    private fun shareTextIntent(title: String, text: String): Boolean = runCatching {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, title)
            putExtra(Intent.EXTRA_TEXT, text)
        }
        val chooser = Intent.createChooser(send, title).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appContext.startActivity(chooser)
        true
    }.getOrDefault(false)

    private fun saveBytesToDownloads(filename: String, mime: String, bytes: ByteArray): String? {
        val safeName = filename.replace(Regex("""[^A-Za-z0-9._-]"""), "_")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return runCatching {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/AntigravityGo")
                }
                val resolver = appContext.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                "Download/AntigravityGo/$safeName"
            }.getOrNull()
        }
        return runCatching {
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "AntigravityGo",
            ).apply { mkdirs() }
            val out = File(dir, safeName)
            out.writeBytes(bytes)
            out.absolutePath
        }.getOrNull()
    }

    private fun snapshot(): Map<String, Any?> {
        val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memInfo = ActivityManager.MemoryInfo().also { am?.getMemoryInfo(it) }
        val ramMb = memInfo.totalMem / (1024L * 1024L)
        val cores = Runtime.getRuntime().availableProcessors()
        val tier = PerformanceClassifier.classifyDeviceTier(ramMb, cores)

        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && pm != null) {
            pm.currentThermalStatus
        } else {
            0
        }
        val maxHz = runCatching {
            val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            @Suppress("DEPRECATION")
            val display = wm?.defaultDisplay
            @Suppress("DEPRECATION")
            display?.supportedModes?.maxOfOrNull { it.refreshRate.toDouble() } ?: 60.0
        }.getOrDefault(60.0)

        return mapOf(
            "tier" to tier,
            "ramMb" to ramMb,
            "cpuCores" to cores,
            "thermalStatus" to thermal,
            "thermalLightweight" to PerformanceClassifier.isThermalLightweight(thermal),
            "refreshRateMode" to RefreshRateCoordinator.mode,
            "maxRefreshHz" to maxHz,
            "ignoringBatteryOptimizations" to isIgnoringBatteryOptimizations(),
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    companion object {
        private const val CHANNEL = "agy/performance"
    }
}
