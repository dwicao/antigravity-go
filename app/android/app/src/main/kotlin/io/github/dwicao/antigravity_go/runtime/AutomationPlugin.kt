package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter bridge (`agy/automations`) synchronizing scheduled automation tasks with
 * [AutomationScheduler] so they survive process kills via [AlarmManager].
 */
class AutomationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "agy/automations")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sync" -> {
                val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                AutomationScheduler.syncFromDart(appContext, items)
                result.success(null)
            }
            "pullRuns" -> {
                result.success(AutomationScheduler.readNativeRuns(appContext))
            }
            else -> result.notImplemented()
        }
    }
}
