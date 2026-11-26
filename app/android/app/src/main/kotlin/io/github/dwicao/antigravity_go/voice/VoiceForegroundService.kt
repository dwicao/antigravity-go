package io.github.dwicao.antigravity_go.voice

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.github.dwicao.antigravity_go.MainActivity
import io.github.dwicao.antigravity_go.R

/**
 * Foreground service keeping Voice Dictation / TTS Sessions active with a bounded
 * wake lock, gentle passive audio focus, and notification-shade Mute / Stop actions.
 * Adopted from antigravity-android PR #37 (`VoiceForegroundService`).
 */
class VoiceForegroundService : Service() {

    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var hasAudioFocus = false

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { _ -> }

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_VOICE_STOP -> {
                active = false
                muted = false
                abandonAudioFocus()
                releaseWakeLock()
                notifyListener()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf(startId)
                return START_NOT_STICKY
            }

            ACTION_VOICE_TOGGLE_MUTE -> {
                muted = !muted
                if (active) {
                    val nm = getSystemService(NotificationManager::class.java)
                    nm.notify(NOTIFICATION_ID, buildNotification(this, currentStatusText, muted))
                }
                notifyListener()
                return START_STICKY
            }

            ACTION_VOICE_SET_MUTE -> {
                muted = intent.getBooleanExtra(EXTRA_MUTED, false)
                if (active) {
                    val nm = getSystemService(NotificationManager::class.java)
                    nm.notify(NOTIFICATION_ID, buildNotification(this, currentStatusText, muted))
                }
                notifyListener()
                return START_STICKY
            }

            else -> {
                val label = intent?.getStringExtra(EXTRA_STATUS_TEXT)?.trim().orEmpty()
                if (label.isNotEmpty()) currentStatusText = label
                active = true
                requestAudioFocus()
                acquireWakeLock()
                val notification = buildNotification(this, currentStatusText, muted)
                if (Build.VERSION.SDK_INT >= 34) {
                    val hasMicPerm = checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED
                    val type = if (hasMicPerm) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    } else {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    }
                    startForeground(NOTIFICATION_ID, notification, type)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startForeground(NOTIFICATION_ID, notification)
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                notifyListener()
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        active = false
        muted = false
        abandonAudioFocus()
        releaseWakeLock()
        notifyListener()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notifyListener() {
        stateListener?.invoke(active, muted)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "antigravity-go:voice").apply {
            setReferenceCounted(false)
        }
        runCatching { wakeLock?.acquire(60 * 60 * 1000L) }
    }

    private fun releaseWakeLock() {
        runCatching {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        }
        wakeLock = null
    }

    private fun requestAudioFocus() {
        val am = audioManager ?: return
        if (hasAudioFocus) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()
            audioFocusRequest = req
            hasAudioFocus = am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            hasAudioFocus = am.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManager ?: return
        if (!hasAudioFocus) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { runCatching { am.abandonAudioFocusRequest(it) } }
        } else {
            @Suppress("DEPRECATION")
            runCatching { am.abandonAudioFocus(focusChangeListener) }
        }
        hasAudioFocus = false
    }

    companion object {
        const val CHANNEL_VOICE = "agy_voice"
        const val NOTIFICATION_ID = 4401

        const val ACTION_VOICE_START = "io.github.dwicao.antigravity_go.ACTION_VOICE_START"
        const val ACTION_VOICE_STOP = "io.github.dwicao.antigravity_go.ACTION_VOICE_STOP"
        const val ACTION_VOICE_TOGGLE_MUTE = "io.github.dwicao.antigravity_go.ACTION_VOICE_TOGGLE_MUTE"
        const val ACTION_VOICE_SET_MUTE = "io.github.dwicao.antigravity_go.ACTION_VOICE_SET_MUTE"
        const val EXTRA_STATUS_TEXT = "statusText"
        const val EXTRA_MUTED = "muted"

        @Volatile var active: Boolean = false
            private set
        @Volatile var muted: Boolean = false
            private set
        @Volatile private var currentStatusText: String = "Voice mode active"
        @Volatile var stateListener: ((Boolean, Boolean) -> Unit)? = null

        fun start(context: Context, statusText: String = "Voice mode active") {
            val appCtx = context.applicationContext
            val intent = Intent(appCtx, VoiceForegroundService::class.java).apply {
                action = ACTION_VOICE_START
                putExtra(EXTRA_STATUS_TEXT, statusText)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appCtx.startForegroundService(intent)
            } else {
                appCtx.startService(intent)
            }
        }

        fun stop(context: Context) {
            if (!active) return
            val appCtx = context.applicationContext
            val intent = Intent(appCtx, VoiceForegroundService::class.java).apply {
                action = ACTION_VOICE_STOP
            }
            runCatching { appCtx.startService(intent) }
        }

        fun setMuted(context: Context, isMuted: Boolean) {
            muted = isMuted
            if (!active) return
            val appCtx = context.applicationContext
            val intent = Intent(appCtx, VoiceForegroundService::class.java).apply {
                action = ACTION_VOICE_SET_MUTE
                putExtra(EXTRA_MUTED, isMuted)
            }
            runCatching { appCtx.startService(intent) }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val mgr = context.getSystemService(NotificationManager::class.java)
                if (mgr.getNotificationChannel(CHANNEL_VOICE) == null) {
                    mgr.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_VOICE,
                            "Voice Mode",
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            description = "Active voice dictation and read-aloud session controls"
                            setShowBadge(false)
                        }
                    )
                }
            }
        }

        private fun buildNotification(context: Context, statusText: String, isMuted: Boolean): Notification {
            ensureChannel(context)
            val openIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val openPending = PendingIntent.getActivity(
                context,
                4400,
                openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

            val toggleIntent = Intent(context, VoiceForegroundService::class.java).apply {
                action = ACTION_VOICE_TOGGLE_MUTE
            }
            val togglePending = PendingIntent.getService(
                context,
                4401,
                toggleIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

            val stopIntent = Intent(context, VoiceForegroundService::class.java).apply {
                action = ACTION_VOICE_STOP
            }
            val stopPending = PendingIntent.getService(
                context,
                4402,
                stopIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_VOICE)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            return builder
                .setContentTitle(if (isMuted) "Voice Mode (Muted)" else "Voice Mode Active")
                .setContentText(statusText)
                .setSmallIcon(R.drawable.ic_stat_agy)
                .setContentIntent(openPending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_lock_silent_mode,
                        if (isMuted) "Unmute" else "Mute",
                        togglePending,
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "Stop Voice",
                        stopPending,
                    ).build()
                )
                .build()
        }
    }
}
