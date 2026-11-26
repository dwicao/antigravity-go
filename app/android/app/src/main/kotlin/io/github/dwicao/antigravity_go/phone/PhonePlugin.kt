package io.github.dwicao.antigravity_go.phone

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.dwicao.antigravity_go.runtime.ApprovalNotificationHelper
import io.github.dwicao.antigravity_go.runtime.RuntimeController
import org.json.JSONObject

class PhonePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        PhoneControlCoordinator.bindContext(appContext)
        methodChannel = MethodChannel(binding.binaryMessenger, "agy/phone")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "agy/phone/events")
        eventChannel.setStreamHandler(this)
        PhoneControlCoordinator.setListener { action, target, allowed, reason ->
            mainHandler.post {
                eventSink?.success(
                    mapOf(
                        "action" to action,
                        "target" to target,
                        "allowed" to allowed,
                        "reason" to reason,
                    )
                )
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PhoneControlCoordinator.setListener(null)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "enabled" to PhoneControlCoordinator.enabled,
                    "accessibilityConnected" to (AgyAccessibilityService.instance != null),
                    "safetyGateStrict" to PhoneControlCoordinator.safetyStrict,
                    "mcpPort" to PhoneControlCoordinator.mcpServer.port,
                    "mcpToken" to PhoneControlCoordinator.mcpServer.authToken,
                    "shizukuAvailable" to DeviceGatewayHelper.isShizukuAvailable(appContext),
                )
            )
            "deviceInfo" -> {
                val info = DeviceGatewayHelper.systemInfo(appContext)
                val map = mutableMapOf<String, Any?>()
                val keys = info.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = info.opt(k)?.let { if (it is org.json.JSONArray) it.toString() else it }
                }
                result.success(map)
            }
            "setTorch" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val res = DeviceGatewayHelper.setTorch(appContext, enabled)
                result.success(res.optBoolean("ok", false))
            }
            "vibrate" -> {
                val ms = (call.argument<Number>("durationMs")?.toLong()) ?: 100L
                val res = DeviceGatewayHelper.vibrate(appContext, ms)
                result.success(res.optBoolean("ok", false))
            }
            "postNotification" -> {
                val title = call.argument<String>("title") ?: "Antigravity"
                val message = call.argument<String>("message") ?: ""
                val tag = call.argument<String>("tag") ?: "agy_task"
                val channel = call.argument<String>("channel") ?: DeviceGatewayHelper.CHANNEL_ALERTS
                val res = DeviceGatewayHelper.notify(
                    context = appContext,
                    action = "post",
                    title = title,
                    message = message,
                    tag = tag,
                    channel = channel,
                )
                result.success(res.optBoolean("ok", false))
            }
            "postApprovalNotification" -> {
                val ok = ApprovalNotificationHelper.post(
                    context = appContext,
                    turnId = call.argument<String>("turnId") ?: "",
                    requestId = call.argument<String>("requestId") ?: "",
                    allowOptionId = call.argument<String>("allowOptionId") ?: "allow",
                    denyOptionId = call.argument<String>("denyOptionId") ?: "reject",
                    title = call.argument<String>("title") ?: "Approval needed",
                    message = call.argument<String>("message") ?: "An agent action needs confirmation.",
                )
                result.success(ok)
            }
            "cancelApprovalNotification" -> {
                ApprovalNotificationHelper.cancel(appContext)
                result.success(true)
            }
            "postSubagentNotification" -> {
                val id = ApprovalNotificationHelper.postSubagentProgress(
                    context = appContext,
                    subagentId = call.argument<String>("subagentId") ?: "default",
                    title = call.argument<String>("title") ?: "Subagent running",
                    message = call.argument<String>("message") ?: "Working in background…",
                    progress = call.argument<Int>("progress") ?: -1,
                    turnId = call.argument<String>("turnId") ?: "",
                    ongoing = call.argument<Boolean>("ongoing") ?: true,
                )
                result.success(id >= 0)
            }
            "cancelSubagentNotification" -> {
                val sid = call.argument<String>("subagentId") ?: "default"
                ApprovalNotificationHelper.cancelSubagentNotification(appContext, sid)
                result.success(true)
            }
            "hasClipboardImage" -> {
                result.success(ClipboardImageHelper.hasClipboardImage(appContext))
            }
            "readClipboardImagePath" -> {
                result.success(ClipboardImageHelper.readClipboardImageToTempFile(appContext))
            }
            "copyContentImageUri" -> {
                val rawUri = call.argument<String>("uri")?.trim().orEmpty()
                val hintMime = call.argument<String>("mimeType")
                if (rawUri.isEmpty()) {
                    result.success(mapOf("ok" to false, "error" to "empty_uri"))
                } else {
                    val uri = Uri.parse(rawUri)
                    result.success(ClipboardImageHelper.copyImageUriToTempFile(appContext, uri, hintMime))
                }
            }
            "browserAuto" -> {
                val payloadMap = call.argument<Map<String, Any?>>("payload") ?: emptyMap()
                val json = JSONObject(payloadMap)
                Thread {
                    val res = DeviceGatewayHelper.browserAuto(appContext, json)
                    val outMap = mutableMapOf<String, Any?>()
                    val keys = res.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        outMap[k] = res.opt(k)?.let {
                            if (it is org.json.JSONArray || it is JSONObject) it.toString() else it
                        }
                    }
                    mainHandler.post { result.success(outMap) }
                }.start()
            }
            "shizukuExec" -> {
                val cmd = call.argument<String>("command") ?: ""
                val res = DeviceGatewayHelper.shizukuExec(appContext, cmd)
                result.success(
                    mapOf(
                        "ok" to res.optBoolean("ok", false),
                        "allowed" to res.optBoolean("allowed", false),
                        "output" to res.optString("output", res.optString("error", res.optString("reason", ""))),
                    )
                )
            }
            "shizukuLogcat" -> {
                val tag = call.argument<String>("tag") ?: ""
                val lines = call.argument<Int>("lines") ?: 120
                val res = DeviceGatewayHelper.shizukuLogcat(appContext, tag, lines)
                result.success(
                    mapOf(
                        "ok" to res.optBoolean("ok", false),
                        "allowed" to res.optBoolean("allowed", false),
                        "output" to res.optString("output", res.optString("error", res.optString("reason", ""))),
                    )
                )
            }
            "shizukuInstall" -> {
                val apkPath = call.argument<String>("apkPath") ?: ""
                val res = DeviceGatewayHelper.shizukuInstallApk(appContext, apkPath)
                result.success(
                    mapOf(
                        "ok" to res.optBoolean("ok", false),
                        "allowed" to res.optBoolean("allowed", false),
                        "output" to res.optString("output", res.optString("error", res.optString("reason", ""))),
                    )
                )
            }
            "shizukuUiDump" -> {
                val res = DeviceGatewayHelper.shizukuUiDump(appContext)
                result.success(
                    mapOf(
                        "ok" to res.optBoolean("ok", false),
                        "allowed" to res.optBoolean("allowed", false),
                        "output" to res.optString("output", res.optString("error", res.optString("reason", ""))),
                    )
                )
            }
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                PhoneControlCoordinator.setEnabled(enabled)
                runCatching { RuntimeController.get(appContext).syncPhoneMcpRegistration() }
                result.success(null)
            }
            "setSafetyStrict" -> {
                PhoneControlCoordinator.safetyStrict = call.argument<Boolean>("strict") ?: true
                result.success(null)
            }
            "openAccessibilitySettings" -> {
                val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                appContext.startActivity(intent)
                result.success(null)
            }
            "dumpScreen" -> {
                val dump = AgyAccessibilityService.instance?.dumpTree() ?: ""
                result.success(dump)
            }
            "actionLog" -> result.success(PhoneControlCoordinator.getActionLog())
            "clearActionLog" -> {
                PhoneControlCoordinator.clearActionLog()
                result.success(null)
            }
            "getAppRules" -> result.success(PhoneControlCoordinator.getAppRules())
            "setAppRule" -> {
                val pkg = call.argument<String>("packageName") ?: ""
                val mode = call.argument<String>("mode")
                PhoneControlCoordinator.setAppRule(pkg, mode)
                result.success(PhoneControlCoordinator.getAppRules())
            }
            "runSelfCheck" -> {
                val notificationsGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED
                } else {
                    true
                }
                val storageGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Environment.isExternalStorageManager()
                } else {
                    appContext.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                        PackageManager.PERMISSION_GRANTED
                }
                val batteryIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    pm?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
                } else {
                    true
                }
                result.success(
                    mapOf(
                        "accessibilityConnected" to (AgyAccessibilityService.instance != null),
                        "notificationsGranted" to notificationsGranted,
                        "storageGranted" to storageGranted,
                        "batteryOptimizationIgnored" to batteryIgnored,
                        "shizukuAvailable" to DeviceGatewayHelper.isShizukuAvailable(appContext),
                        "mcpRunning" to (PhoneControlCoordinator.currentMcpEndpoint() != null),
                        "mcpPort" to PhoneControlCoordinator.mcpServer.port,
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }
}
