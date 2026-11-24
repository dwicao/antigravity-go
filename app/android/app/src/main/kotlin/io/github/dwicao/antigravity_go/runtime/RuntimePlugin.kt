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
        controllerListener?.let { RuntimeController.get(appContext).removeListener(it) }
        eventSink = events
        val listener: (Map<String, Any?>) -> Unit = { payload ->
            mainHandler.post { eventSink?.success(payload) }
        }
        controllerListener = listener
        RuntimeController.get(appContext).addListener(listener)
    }

    private inline fun <T> runAsync(
        result: MethodChannel.Result,
        crossinline block: () -> T,
    ) {
        ioExecutor.submit {
            try {
                val res = block()
                mainHandler.post { result.success(res) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("runtime_error", t.message ?: t.toString(), null)
                }
            }
        }
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
            "setGuardrailsEnabled" -> {
                ctrl.setGuardrailsEnabled(call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }
            "readSettings" -> runAsync(result) { ctrl.readSettings() }
            "writeSettings" -> {
                val settings = call.argument<Map<String, Any?>>("settings") ?: emptyMap()
                runAsync(result) {
                    ctrl.writeSettings(settings)
                    null
                }
            }
            "authStatus" -> runAsync(result) { ctrl.checkAuthStatus() }
            "verifyAuth" -> runAsync(result) { ctrl.verifyAuth() }
            "probeUsage" -> runAsync(result) { ctrl.probeUsage() }
            "startLogin" -> {
                ctrl.startGoogleLogin(call.argument<Boolean>("enterprise") ?: false)
                result.success(null)
            }
            "submitLoginCode" -> {
                ctrl.submitLoginCode(call.argument<String>("code") ?: "")
                result.success(null)
            }
            "logout" -> runAsync(result) {
                ctrl.logout()
                null
            }
            "exportCredentials" -> {
                val passphrase = call.argument<String>("passphrase") ?: ""
                val apiKey = call.argument<String>("geminiApiKey")
                val authProfile = call.argument<String>("authProfileJson")
                val accountId = call.argument<String>("accountId")
                runAsync(result) { ctrl.exportCredentials(passphrase, apiKey, authProfile, accountId) }
            }
            "importCredentials" -> {
                val bundleJson = call.argument<String>("bundleJson") ?: ""
                val passphrase = call.argument<String>("passphrase") ?: ""
                val activate = call.argument<Boolean>("activate") ?: true
                val authProfile = call.argument<String>("authProfileJson")
                val apiKey = call.argument<String>("geminiApiKey")
                runAsync(result) {
                    ctrl.importCredentials(bundleJson, passphrase, activate, authProfile, apiKey)
                }
            }
            "listAccounts" -> {
                val authProfile = call.argument<String>("authProfileJson")
                val apiKey = call.argument<String>("geminiApiKey")
                runAsync(result) { ctrl.listAccounts(authProfile, apiKey) }
            }
            "syncActiveAccount" -> {
                val authProfile = call.argument<String>("authProfileJson")
                val apiKey = call.argument<String>("geminiApiKey")
                runAsync(result) { ctrl.syncActiveAccount(authProfile, apiKey) }
            }
            "switchAccount" -> {
                val accountId = call.argument<String>("accountId") ?: ""
                val authProfile = call.argument<String>("authProfileJson")
                val apiKey = call.argument<String>("geminiApiKey")
                runAsync(result) { ctrl.switchAccount(accountId, authProfile, apiKey) }
            }
            "removeAccount" -> {
                val accountId = call.argument<String>("accountId") ?: ""
                runAsync(result) { ctrl.removeAccount(accountId) }
            }
            "runCapture" -> {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val cwd = call.argument<String>("cwd")
                val env = call.argument<Map<String, String>>("env") ?: emptyMap()
                val timeout = call.argument<Int>("timeoutSeconds") ?: 20
                runAsync(result) { ctrl.runCapture(args, cwd, env, timeout) }
            }
            "runShell" -> {
                val command = call.argument<String>("command") ?: ""
                val cwd = call.argument<String>("cwd")
                runAsync(result) { ctrl.runShell(command, cwd) }
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
                    agent = call.argument<String>("agent"),
                    printTimeoutSeconds = call.argument<Int>("printTimeoutSeconds"),
                    disableSlashCommands = call.argument<Boolean>("disableSlashCommands") ?: false,
                    continueLast = call.argument<Boolean>("continueLast") ?: false,
                    remoteAgent = call.argument<String>("remoteAgent"),
                    attachments = call.argument<List<String>>("attachments") ?: emptyList(),
                )
                result.success(null)
            }
            "startTerminalSession" -> {
                val sid = call.argument<String>("sessionId") ?: ""
                val cwd = call.argument<String>("cwd")
                val cols = call.argument<Int>("cols") ?: 80
                val rows = call.argument<Int>("rows") ?: 24
                ctrl.startTerminalSession(sid, cwd, cols, rows)
                result.success(null)
            }
            "resizeTerminalSession" -> {
                val sid = call.argument<String>("sessionId") ?: ""
                val cols = call.argument<Int>("cols") ?: 80
                val rows = call.argument<Int>("rows") ?: 24
                result.success(ctrl.resizeTerminalSession(sid, cols, rows))
            }
            "writeTerminalInput" -> {
                val sid = call.argument<String>("sessionId") ?: ""
                val input = call.argument<String>("input") ?: ""
                result.success(ctrl.writeTerminalInput(sid, input))
            }
            "closeTerminalSession" -> {
                val sid = call.argument<String>("sessionId") ?: ""
                ctrl.closeTerminalSession(sid)
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
            "closeSessionWorker" -> {
                val sid = call.argument<String>("sessionId") ?: ""
                result.success(ctrl.closeSessionWorker(sid))
            }
            "backgroundTasks" -> result.success(ctrl.listBackgroundTasks())
            "cancelBackgroundTask" -> {
                val ok = ctrl.cancelBackgroundTask(call.argument<String>("taskId") ?: "")
                result.success(ok)
            }
            "forceStopAllBackgroundTasks" -> {
                val count = ctrl.forceStopAllBackgroundTasks()
                result.success(count)
            }
            "writeFile" -> {
                val path = call.argument<String>("path") ?: ""
                val content = call.argument<String>("content") ?: ""
                runAsync(result) { ctrl.writeTextFile(path, content) }
            }
            "listCustomizations" -> {
                val cwd = call.argument<String>("cwd")
                runAsync(result) { ctrl.listCustomizations(cwd) }
            }
            "gitDiff" -> {
                val cwd = call.argument<String>("cwd")
                runAsync(result) { ctrl.gitDiff(cwd) }
            }
            "gitCommitAndPush" -> {
                val cwd = call.argument<String>("cwd")
                val message = call.argument<String>("message") ?: ""
                val stageAll = call.argument<Boolean>("stageAll") ?: true
                val push = call.argument<Boolean>("push") ?: true
                runAsync(result) { ctrl.gitCommitAndPush(cwd, message, stageAll, push) }
            }
            "diagnoseRuntime" -> runAsync(result) { ctrl.diagnoseRuntime() }
            "listWorkspace" -> {
                val path = call.argument<String>("path")
                runAsync(result) { ctrl.listWorkspace(path) }
            }
            "readFile" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { ctrl.readFile(path) }
            }
            "createDirectory" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { ctrl.createDirectory(path) }
            }
            "deleteWorkspaceEntry" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { ctrl.deleteWorkspaceEntry(path) }
            }
            "createCheckpoint" -> {
                val cwd = call.argument<String>("cwd")
                runAsync(result) { ctrl.createCheckpoint(cwd) }
            }
            "restoreCheckpoint" -> {
                val cwd = call.argument<String>("cwd")
                val ref = call.argument<String>("ref") ?: ""
                runAsync(result) { ctrl.restoreCheckpoint(cwd, ref) }
            }
            "initHarnessFiles" -> {
                val cwd = call.argument<String>("cwd")
                val featureJson = call.argument<String>("featureJson") ?: ""
                val progressTxt = call.argument<String>("progressTxt") ?: ""
                runAsync(result) { ctrl.initHarnessFiles(cwd, featureJson, progressTxt) }
            }
            "readHarnessFiles" -> {
                val cwd = call.argument<String>("cwd")
                runAsync(result) { ctrl.readHarnessFiles(cwd) }
            }
            "writeHarnessFile" -> {
                val cwd = call.argument<String>("cwd")
                val name = call.argument<String>("name") ?: ""
                val content = call.argument<String>("content") ?: ""
                runAsync(result) { ctrl.writeHarnessFile(cwd, name, content) }
            }
            else -> result.notImplemented()
        }
    }
}
