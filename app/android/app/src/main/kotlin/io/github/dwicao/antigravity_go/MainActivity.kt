package io.github.dwicao.antigravity_go

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.dwicao.antigravity_go.performance.PerformancePlugin
import io.github.dwicao.antigravity_go.performance.RefreshRateCoordinator
import io.github.dwicao.antigravity_go.permissions.PermissionsPlugin
import io.github.dwicao.antigravity_go.phone.PhonePlugin
import io.github.dwicao.antigravity_go.runtime.AutomationPlugin
import io.github.dwicao.antigravity_go.runtime.RuntimePlugin
import io.github.dwicao.antigravity_go.theme.DynamicColorPlugin
import io.github.dwicao.antigravity_go.update.UpdatePlugin
import io.github.dwicao.antigravity_go.voice.VoicePlugin

class MainActivity : FlutterActivity() {
    private val permissionsPlugin = PermissionsPlugin()
    private var systemChannel: MethodChannel? = null
    private var pendingRouteAction: String? = null
    private var inForeground = false
    private var votedView: SurfaceView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureRouteAction(intent)
        RefreshRateCoordinator.onModeChanged = {
            runOnUiThread { applyRefreshRate() }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.getStringExtra(EXTRA_ROUTE_ACTION)
        if (!action.isNullOrBlank()) {
            pendingRouteAction = action
            systemChannel?.invokeMethod("onShortcutAction", action)
        }
    }

    private fun captureRouteAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_ROUTE_ACTION)
        if (!action.isNullOrBlank()) {
            pendingRouteAction = action
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(RuntimePlugin())
        flutterEngine.plugins.add(AutomationPlugin())
        flutterEngine.plugins.add(PhonePlugin())
        flutterEngine.plugins.add(VoicePlugin())
        flutterEngine.plugins.add(UpdatePlugin())
        flutterEngine.plugins.add(DynamicColorPlugin())
        flutterEngine.plugins.add(PerformancePlugin())
        flutterEngine.plugins.add(permissionsPlugin)

        systemChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agy/system").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingAction" -> {
                        val next = pendingRouteAction
                        pendingRouteAction = null
                        result.success(next)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        inForeground = true
        applyRefreshRate()
        permissionsPlugin.notifyStatusChanged()
    }

    override fun onPause() {
        inForeground = false
        applyRefreshRate()
        super.onPause()
    }

    /**
     * Votes on preferred display refresh rate (`auto` / `max` / `system`) cleanly on Android
     * so 120Hz+ screens stay fluid while active without forcing peak refresh while paused.
     */
    private fun applyRefreshRate() {
        val mode = RefreshRateCoordinator.mode
        val want = if (mode == "max" || (mode == "auto" && inForeground)) {
            @Suppress("DEPRECATION")
            val display = windowManager.defaultDisplay
            val now = display.mode
            display.supportedModes
                .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
                .maxByOrNull { it.refreshRate }
        } else {
            null
        }
        val targetId = want?.modeId ?: 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            window.attributes.preferredDisplayModeId != targetId
        ) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = targetId }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val view = flutterSurfaceView(findViewById<View>(FLUTTER_VIEW_ID)) ?: return
        if (view !== votedView) {
            votedView = view
            view.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = applyRefreshRate()
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            })
        }
        val surface = view.holder.surface
        if (surface.isValid) {
            surface.setFrameRate(
                want?.refreshRate ?: 0f,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
            )
        }
    }

    private fun flutterSurfaceView(view: View?): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                flutterSurfaceView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    companion object {
        const val ACTION_SHORTCUT = "io.github.dwicao.antigravity_go.SHORTCUT"
        const val EXTRA_ROUTE_ACTION = "agy_action"
    }
}
