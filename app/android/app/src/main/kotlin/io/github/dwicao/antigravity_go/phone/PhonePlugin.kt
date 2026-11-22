package io.github.dwicao.antigravity_go.phone

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class PhonePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var enabled = false

    @Volatile
    private var safetyStrict = true

    private val mcpServer = PhoneMcpServer(
        isStrictMode = { safetyStrict },
        onActionLogged = { action, target, allowed, reason ->
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
        },
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "agy/phone")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "agy/phone/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        mcpServer.stop()
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
                    "enabled" to enabled,
                    "accessibilityConnected" to (AgyAccessibilityService.instance != null),
                    "safetyGateStrict" to safetyStrict,
                    "mcpPort" to mcpServer.port,
                )
            )
            "setEnabled" -> {
                enabled = call.argument<Boolean>("enabled") ?: false
                if (enabled) mcpServer.start() else mcpServer.stop()
                result.success(null)
            }
            "setSafetyStrict" -> {
                safetyStrict = call.argument<Boolean>("strict") ?: true
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
            else -> result.notImplemented()
        }
    }
}
