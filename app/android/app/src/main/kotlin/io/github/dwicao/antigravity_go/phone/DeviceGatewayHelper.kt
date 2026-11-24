package io.github.dwicao.antigravity_go.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.widget.Toast
import io.github.dwicao.antigravity_go.runtime.CommandSafetyGuard
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Native Android gateway tools inspired by antigravity-android's GatewayDispatcher:
 * telemetry, notifications, clipboard, flashlight torch, haptics, toasts, URL dispatch,
 * and optional rootless Shizuku (`rish`) execution.
 */
object DeviceGatewayHelper {
    const val CHANNEL_TASKS = "agy_tasks"
    const val CHANNEL_ALERTS = "agy_alerts"

    private val mainHandler = Handler(Looper.getMainLooper())

    fun systemInfo(context: Context): JSONObject {
        val appCtx = context.applicationContext
        val resp = JSONObject().put("allowed", true).put("ok", true)
        runCatching {
            val bat = appCtx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (bat != null) {
                val level = bat.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = bat.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                val status = bat.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
                val pct = if (scale > 0) ((level / scale.toFloat()) * 100f).toInt() else level
                resp.put("battery", pct)
                resp.put("charging", charging)
            }

            val cm = appCtx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val network = if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
                when {
                    caps == null -> "offline"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                }
            } else {
                @Suppress("DEPRECATION")
                val active = cm?.activeNetworkInfo
                if (active != null && active.isConnected) active.typeName.lowercase() else "offline"
            }
            resp.put("network", network)

            resp.put("storageFreeMb", appCtx.filesDir.usableSpace / (1024L * 1024L))
            val rt = Runtime.getRuntime()
            val freeMemMb = (rt.maxMemory() - (rt.totalMemory() - rt.freeMemory())) / (1024L * 1024L)
            resp.put("memoryFreeMb", freeMemMb)
            resp.put("deviceModel", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
            resp.put("androidVersion", Build.VERSION.RELEASE)
            resp.put("sdkInt", Build.VERSION.SDK_INT)
            resp.put("abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
            resp.put("shizukuAvailable", isShizukuAvailable(appCtx))
        }.onFailure { e ->
            resp.put("ok", false).put("error", e.message ?: e.toString())
        }
        return resp
    }

    fun clipboard(context: Context, action: String, text: String = ""): JSONObject {
        val appCtx = context.applicationContext
        if (action.equals("get", ignoreCase = true)) {
            val ref = AtomicReference("")
            val latch = CountDownLatch(1)
            mainHandler.post {
                try {
                    val cm = appCtx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    val clip = cm?.primaryClip
                    if (clip != null && clip.itemCount > 0) {
                        ref.set(clip.getItemAt(0).text?.toString() ?: "")
                    }
                } catch (_: Throwable) {
                } finally {
                    latch.countDown()
                }
            }
            latch.await(1500, TimeUnit.MILLISECONDS)
            return JSONObject()
                .put("allowed", true)
                .put("ok", true)
                .put("text", ref.get())
        }

        mainHandler.post {
            runCatching {
                val cm = appCtx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("antigravity", text))
            }
        }
        return JSONObject()
            .put("allowed", true)
            .put("ok", true)
            .put("length", text.length)
    }

    fun notify(
        context: Context,
        action: String = "post",
        title: String = "Antigravity",
        message: String = "",
        tag: String = "agy_task",
        id: Int = 4201,
        progress: Int = -1,
        ongoing: Boolean = false,
        channel: String = CHANNEL_TASKS,
    ): JSONObject {
        val appCtx = context.applicationContext
        val mgr = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return JSONObject().put("allowed", false).put("error", "NotificationManager unavailable")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_TASKS, "Antigravity Tasks", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = "Ongoing AI agent and automation updates" }
            )
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_ALERTS, "Antigravity Alerts", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "Task completion and approval alerts" }
            )
        }

        if (action.equals("cancel", ignoreCase = true)) {
            mgr.cancel(tag, id)
            return JSONObject().put("allowed", true).put("ok", true).put("cancelled", true)
        }

        val targetChannel = if (channel == CHANNEL_ALERTS) CHANNEL_ALERTS else CHANNEL_TASKS
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appCtx, targetChannel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appCtx)
        }
        builder
            .setContentTitle(title.ifBlank { "Antigravity" })
            .setContentText(message)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        }

        return runCatching {
            mgr.notify(tag, id, builder.build())
            JSONObject()
                .put("allowed", true)
                .put("ok", true)
                .put("tag", tag)
                .put("id", id)
        }.getOrElse { e ->
            JSONObject().put("allowed", false).put("error", e.message ?: "Notification failed")
        }
    }

    fun setTorch(context: Context, enabled: Boolean): JSONObject {
        val appCtx = context.applicationContext
        val camMgr = appCtx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return JSONObject().put("allowed", false).put("error", "CameraManager unavailable")
        return runCatching {
            var toggledId: String? = null
            for (id in camMgr.cameraIdList) {
                val chars = camMgr.getCameraCharacteristics(id)
                val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                if (hasFlash) {
                    camMgr.setTorchMode(id, enabled)
                    toggledId = id
                    break
                }
            }
            if (toggledId == null) {
                JSONObject().put("allowed", false).put("error", "No camera flash hardware found")
            } else {
                JSONObject()
                    .put("allowed", true)
                    .put("ok", true)
                    .put("enabled", enabled)
                    .put("cameraId", toggledId)
            }
        }.getOrElse { e ->
            JSONObject().put("allowed", false).put("error", e.message ?: e.toString())
        }
    }

    fun vibrate(context: Context, durationMs: Long = 100L): JSONObject {
        val appCtx = context.applicationContext
        val clampedMs = durationMs.coerceIn(10L, 5000L)
        return runCatching {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = appCtx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                appCtx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator == null || !vibrator.hasVibrator()) {
                return JSONObject().put("allowed", false).put("error", "Vibrator unavailable")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createOneShot(clampedMs, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(clampedMs)
            }
            JSONObject().put("allowed", true).put("ok", true).put("durationMs", clampedMs)
        }.getOrElse { e ->
            JSONObject().put("allowed", false).put("error", e.message ?: e.toString())
        }
    }

    fun toast(context: Context, message: String, isLong: Boolean = false): JSONObject {
        val appCtx = context.applicationContext
        mainHandler.post {
            Toast.makeText(
                appCtx,
                message,
                if (isLong) Toast.LENGTH_LONG else Toast.LENGTH_SHORT,
            ).show()
        }
        return JSONObject().put("allowed", true).put("ok", true)
    }

    fun openUrl(context: Context, url: String): JSONObject {
        val clean = url.trim()
        val parsed = runCatching { URI(clean) }.getOrNull()
        val scheme = parsed?.scheme?.lowercase()
        if (clean.isEmpty() || (scheme != "https" && scheme != "http")) {
            return JSONObject().put("allowed", false).put("error", "Only http/https URLs are supported")
        }
        return runCatching {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(clean)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.applicationContext.startActivity(intent)
            JSONObject().put("allowed", true).put("ok", true).put("url", clean)
        }.getOrElse { e ->
            JSONObject().put("allowed", false).put("error", e.message ?: e.toString())
        }
    }

    fun findRishBinary(context: Context): File? {
        val files = context.applicationContext.filesDir
        val candidates = listOf(
            File(files, "runtime/bin/rish"),
            File(files, "usr/bin/rish"),
            File(files, "bin/rish"),
            File("/data/local/tmp/rish"),
        )
        return candidates.firstOrNull { it.isFile && it.canExecute() }
    }

    fun isShizukuAvailable(context: Context): Boolean = findRishBinary(context) != null

    fun shizukuExec(context: Context, command: String): JSONObject {
        val cmd = command.trim()
        if (cmd.isEmpty()) {
            return JSONObject().put("allowed", false).put("error", "Empty command")
        }
        val safety = CommandSafetyGuard.evaluateCommand(cmd)
        if (!safety.allowed) {
            return JSONObject()
                .put("allowed", false)
                .put("reason", safety.reason.ifBlank { "Blocked by CommandSafetyGuard" })
        }
        val rish = findRishBinary(context)
            ?: return JSONObject()
                .put("allowed", false)
                .put("error", "Shizuku rish binary not installed in runtime/bin/rish")

        return runCatching {
            val pb = ProcessBuilder(rish.absolutePath, "-c", "env -u LD_LIBRARY_PATH $cmd").apply {
                redirectErrorStream(true)
                directory(context.applicationContext.filesDir)
                environment().remove("LD_LIBRARY_PATH")
                environment()["RISH_APPLICATION_ID"] = context.packageName
            }
            val proc = pb.start()
            val out = proc.inputStream.bufferedReader().readText()
            val finished = proc.waitFor(15, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                return JSONObject()
                    .put("allowed", true)
                    .put("ok", false)
                    .put("error", "Shizuku command timed out after 15s")
            }
            JSONObject()
                .put("allowed", true)
                .put("ok", proc.exitValue() == 0)
                .put("exitCode", proc.exitValue())
                .put("output", out.take(16_384))
        }.getOrElse { e ->
            JSONObject().put("allowed", false).put("error", e.message ?: e.toString())
        }
    }
}
