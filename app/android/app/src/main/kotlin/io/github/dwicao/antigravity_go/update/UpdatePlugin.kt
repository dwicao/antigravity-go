package io.github.dwicao.antigravity_go.update

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class UpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "agy/update")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installFromUrl") {
            result.notImplemented()
            return
        }
        val urlStr = call.argument<String>("url")
        if (urlStr.isNullOrBlank()) {
            result.error("bad_url", "Missing APK URL", null)
            return
        }
        executor.submit {
            try {
                val apkFile = File(appContext.cacheDir, "antigravity-go-update.apk")
                val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 20_000
                    readTimeout = 60_000
                }
                conn.inputStream.use { input ->
                    FileOutputStream(apkFile).use { out ->
                        input.copyTo(out)
                    }
                }
                conn.disconnect()

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
                    appContext.startActivity(intent)
                    result.success(null)
                }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("update_failed", t.message, null)
                }
            }
        }
    }
}
