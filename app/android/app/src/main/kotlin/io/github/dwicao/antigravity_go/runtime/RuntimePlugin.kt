package io.github.dwicao.antigravity_go.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class RuntimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null
    private var controllerListener: ((Map<String, Any?>) -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "agy/runtime")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "agy/runtime/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        controllerListener?.let { RuntimeController.get(appContext).removeListener(it) }
        controllerListener = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val listener: (Map<String, Any?>) -> Unit = { payload ->
            mainHandler.post { eventSink?.success(payload) }
        }
        controllerListener = listener
        RuntimeController.get(appContext).addListener(listener)
    }

    override fun onCancel(arguments: Any?) {
        controllerListener?.let { RuntimeController.get(appContext).removeListener(it) }
        controllerListener = null
        eventSink = null
    }

    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctrl = RuntimeController.get(appContext)
        when (call.method) {
            "status" -> result.success(ctrl.statusMap())
            "logs" -> result.success(ctrl.getLogs())
            "install" -> {
                ctrl.install(call.argument<String>("manifestUrl"))
                result.success(null)
            }
            "start" -> {
                ctrl.startService()
                result.success(null)
            }
            "stop" -> {
                ctrl.stopService()
                result.success(null)
            }
            "reset" -> {
                ctrl.resetRuntime()
                result.success(null)
            }
            "setSafeMode" -> {
                ctrl.setSafeMode(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "readSettings" -> result.success(ctrl.readSettings())
            "writeSettings" -> {
                val settings = call.argument<Map<String, Any?>>("settings") ?: emptyMap()
                ctrl.writeSettings(settings)
                result.success(null)
            }
            "authStatus" -> result.success(ctrl.checkAuthStatus())
            "verifyAuth" -> {
                ioExecutor.submit {
                    val status = ctrl.verifyAuth()
                    mainHandler.post { result.success(status) }
                }
            }
            "probeUsage" -> {
                ioExecutor.submit {
                    val out = ctrl.probeUsage()
                    mainHandler.post { result.success(out) }
                }
            }
            "startLogin" -> {
                ctrl.startGoogleLogin(call.argument<Boolean>("enterprise") ?: false)
                result.success(null)
            }
            "submitLoginCode" -> {
                ctrl.submitLoginCode(call.argument<String>("code") ?: "")
                result.success(null)
            }
            "logout" -> {
                ctrl.logout()
                result.success(null)
            }
            "runCapture" -> {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val cwd = call.argument<String>("cwd")
                val env = call.argument<Map<String, String>>("env") ?: emptyMap()
                val timeout = call.argument<Int>("timeoutSeconds") ?: 20
                ioExecutor.submit {
                    val out = ctrl.runCapture(args, cwd, env, timeout)
                    mainHandler.post { result.success(out) }
                }
            }
            "runShell" -> {
                val command = call.argument<String>("command") ?: ""
                val cwd = call.argument<String>("cwd")
                ioExecutor.submit {
                    val out = ctrl.runShell(command, cwd)
                    mainHandler.post { result.success(out) }
                }
            }
            "startTurn" -> {
                ctrl.startTurn(
                    turnId = call.argument<String>("turnId") ?: "",
                    prompt = call.argument<String>("prompt") ?: "",
                    cwd = call.argument<String>("cwd"),
                    extraDirs = call.argument<List<String>>("extraDirs") ?: emptyList(),
                    conversationId = call.argument<String>("conversationId"),
                    model = call.argument<String>("model"),
                    effort = call.argument<String>("effort"),
                    mode = call.argument<String>("mode"),
                    skipPermissions = call.argument<Boolean>("skipPermissions") ?: false,
                    allowNonWorkspaceAccess = call.argument<Boolean>("allowNonWorkspaceAccess") ?: true,
                    useAcp = call.argument<Boolean>("useAcp") ?: true,
                    geminiApiKey = call.argument<String>("geminiApiKey"),
                )
                result.success(null)
            }
            "respondPermission" -> {
                val turnId = call.argument<String>("turnId") ?: ""
                val reqId = call.argument<Any>("requestId")
                val optId = call.argument<String>("optionId") ?: ""
                if (reqId != null) {
                    ctrl.respondPermission(turnId, reqId, optId)
                }
                result.success(null)
            }
            "cancelTurn" -> {
                ctrl.cancelTurn(call.argument<String>("turnId") ?: "")
                result.success(null)
            }
            "writeFile" -> {
                val ok = ctrl.writeTextFile(
                    call.argument<String>("path") ?: "",
                    call.argument<String>("content") ?: "",
                )
                result.success(ok)
            }
            "listCustomizations" -> {
                result.success(ctrl.listCustomizations(call.argument<String>("cwd")))
            }
            "gitDiff" -> {
                ioExecutor.submit {
                    val res = ctrl.gitDiff(call.argument<String>("cwd"))
                    mainHandler.post { result.success(res) }
                }
            }
            "listWorkspace" -> result.success(ctrl.listWorkspace(call.argument<String>("path")))
            "readFile" -> result.success(ctrl.readFile(call.argument<String>("path") ?: ""))
            else -> result.notImplemented()
        }
    }
}
