package io.github.dwicao.antigravity_go.theme

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes Android 12+ Material You wallpaper Monet palette (`agy/dynamic_color`)
 * so Appearance -> Accent can follow the user's wallpaper dynamically.
 */
class DynamicColorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "palette" -> result.success(palette())
            else -> result.notImplemented()
        }
    }

    private fun palette(): Map<String, Long>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return runCatching {
            fun tone(id: Int): Long = context.getColor(id).toLong() and 0xFFFFFFFFL
            mapOf(
                "accent" to tone(android.R.color.system_accent1_500),
                "accentLight" to tone(android.R.color.system_accent1_600),
                "accentDark" to tone(android.R.color.system_accent1_200),
                "neutral" to tone(android.R.color.system_neutral1_500),
            )
        }.getOrNull()
    }

    companion object {
        private const val CHANNEL = "agy/dynamic_color"
    }
}
