package io.github.dwicao.antigravity_go.voice

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Locale

class VoicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    companion object {
        private const val REQ_CODE_SPEECH = 41021
    }

    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeechText: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "agy/voice")
        channel.setMethodCallHandler(this)
        VoiceForegroundService.stateListener = { active, muted ->
            if (muted) {
                runCatching { tts?.stop() }
            } else if (!active) {
                runCatching { tts?.stop() }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VoiceForegroundService.stateListener = null
        channel.setMethodCallHandler(null)
        runCatching {
            tts?.stop()
            tts?.shutdown()
        }
        tts = null
        ttsReady = false
        pendingSpeechText = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "dictate" -> {
                val act = activity
                if (act == null) {
                    result.error("no_activity", "Activity unavailable", null)
                    return
                }
                pendingResult = result
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak prompt for Antigravity")
                }
                try {
                    act.startActivityForResult(intent, REQ_CODE_SPEECH)
                } catch (t: Throwable) {
                    pendingResult = null
                    result.error("speech_unavailable", t.message, null)
                }
            }
            "speak" -> {
                val text = call.argument<String>("text")?.trim().orEmpty()
                if (text.isEmpty() || VoiceForegroundService.muted) {
                    result.success(false)
                    return
                }
                val localeCode = call.argument<String>("locale")?.trim().orEmpty()
                if (text.length > 80) {
                    runCatching { VoiceForegroundService.start(appContext, "Reading response aloud") }
                }
                speakText(text, localeCode)
                result.success(true)
            }
            "stopSpeaking" -> {
                pendingSpeechText = null
                runCatching { tts?.stop() }
                VoiceForegroundService.stop(appContext)
                result.success(true)
            }
            "startVoiceService" -> {
                val status = call.argument<String>("statusText") ?: "Voice mode active"
                runCatching { VoiceForegroundService.start(appContext, status) }
                result.success(mapOf("active" to true, "muted" to VoiceForegroundService.muted))
            }
            "stopVoiceService" -> {
                pendingSpeechText = null
                runCatching { tts?.stop() }
                VoiceForegroundService.stop(appContext)
                result.success(mapOf("active" to false, "muted" to false))
            }
            "setVoiceMuted" -> {
                val muted = call.argument<Boolean>("muted") ?: false
                VoiceForegroundService.setMuted(appContext, muted)
                if (muted) runCatching { tts?.stop() }
                result.success(mapOf("active" to VoiceForegroundService.active, "muted" to VoiceForegroundService.muted))
            }
            "voiceServiceStatus" -> {
                result.success(
                    mapOf(
                        "active" to VoiceForegroundService.active,
                        "muted" to VoiceForegroundService.muted,
                    )
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun speakText(text: String, localeCode: String) {
        val currentTts = tts
        if (currentTts == null) {
            pendingSpeechText = text
            ttsReady = false
            tts = TextToSpeech(appContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    ttsReady = true
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            VoiceForegroundService.stop(appContext)
                        }

                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            VoiceForegroundService.stop(appContext)
                        }
                    })
                    if (localeCode.isNotEmpty()) {
                        runCatching { tts?.language = Locale.forLanguageTag(localeCode) }
                    }
                    val queued = pendingSpeechText
                    pendingSpeechText = null
                    if (!queued.isNullOrBlank() && !VoiceForegroundService.muted) {
                        tts?.speak(queued, TextToSpeech.QUEUE_FLUSH, null, "agy_summary")
                    }
                }
            }
            return
        }
        if (!ttsReady) {
            pendingSpeechText = text
            return
        }
        if (localeCode.isNotEmpty()) {
            runCatching { currentTts.language = Locale.forLanguageTag(localeCode) }
        }
        currentTts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "agy_summary")
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_CODE_SPEECH) return false
        val res = pendingResult ?: return false
        pendingResult = null
        if (resultCode == Activity.RESULT_OK) {
            val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            res.success(matches?.firstOrNull() ?: "")
        } else {
            res.success("")
        }
        return true
    }
}
