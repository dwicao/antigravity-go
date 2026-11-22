package io.github.dwicao.antigravity_go.permissions

import android.Manifest
import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.dwicao.antigravity_go.phone.AgyAccessibilityService

/**
 * Handles Android storage (All Files Access / MANAGE_EXTERNAL_STORAGE),
 * runtime permissions, and Samsung DeX desktop mode detection.
 */
class PermissionsPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val REQ_PERMISSIONS = 41088
    }

    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "agy/permissions")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "agy/permissions/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        notifyStatusChanged()
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun notifyStatusChanged() {
        eventSink?.success(statusMap())
    }

    fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager()
        } else {
            val read = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
            val write = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
            read && write
        }
    }

    fun hasNotifications(): Boolean {
        return if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    fun hasMicrophone(): Boolean {
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun isDexMode(): Boolean {
        val config = (activity ?: appContext).resources.configuration
        try {
            val field = Configuration::class.java.getField("semDesktopModeEnabled")
            val enabledVal = Configuration::class.java.getField("SEM_DESKTOP_MODE_ENABLED").getInt(null)
            if (field.getInt(config) == enabledVal) return true
        } catch (_: Throwable) {}

        val uiModeMgr = appContext.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeMgr?.currentModeType == Configuration.UI_MODE_TYPE_DESK) {
            return true
        }
        return false
    }

    fun statusMap(): Map<String, Any?> {
        val externalRoot = Environment.getExternalStorageDirectory()?.absolutePath ?: "/storage/emulated/0"
        return mapOf(
            "allFilesAccess" to hasAllFilesAccess(),
            "notifications" to hasNotifications(),
            "microphone" to hasMicrophone(),
            "accessibility" to (AgyAccessibilityService.instance != null),
            "isDexMode" to isDexMode(),
            "sdkInt" to Build.VERSION.SDK_INT,
            "externalStorageRoot" to externalRoot,
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(statusMap())
            "requestAllFilesAccess" -> {
                val act = activity
                if (act == null) {
                    result.error("no_activity", "Activity unavailable", null)
                    return
                }
                if (Build.VERSION.SDK_INT >= 30) {
                    try {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:${act.packageName}"),
                        )
                        act.startActivity(intent)
                        result.success(true)
                    } catch (_: Throwable) {
                        try {
                            val fallback = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            act.startActivity(fallback)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("settings_error", t.message, null)
                        }
                    }
                } else {
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(
                        act,
                        arrayOf(
                            Manifest.permission.READ_EXTERNAL_STORAGE,
                            Manifest.permission.WRITE_EXTERNAL_STORAGE,
                        ),
                        REQ_PERMISSIONS,
                    )
                }
            }
            "requestRuntimePermissions" -> {
                val act = activity
                if (act == null) {
                    result.error("no_activity", "Activity unavailable", null)
                    return
                }
                val toRequest = mutableListOf<String>()
                if (!hasMicrophone()) {
                    toRequest.add(Manifest.permission.RECORD_AUDIO)
                }
                if (Build.VERSION.SDK_INT >= 33 && !hasNotifications()) {
                    toRequest.add(Manifest.permission.POST_NOTIFICATIONS)
                }
                if (Build.VERSION.SDK_INT < 30 && !hasAllFilesAccess()) {
                    toRequest.add(Manifest.permission.READ_EXTERNAL_STORAGE)
                    toRequest.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                }
                if (toRequest.isEmpty()) {
                    result.success(statusMap())
                } else {
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(act, toRequest.toTypedArray(), REQ_PERMISSIONS)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PERMISSIONS) return false
        val map = statusMap()
        pendingPermissionResult?.success(map)
        pendingPermissionResult = null
        notifyStatusChanged()
        return true
    }
}
