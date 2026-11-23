package io.github.dwicao.antigravity_go.runtime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.github.dwicao.antigravity_go.MainActivity
import io.github.dwicao.antigravity_go.R

/**
 * Foreground harness service modeled on DSH-Go's `DshService`:
 * holds a partial wake lock during active agent sessions, observes network
 * transitions/blocks, and surfaces live turn progress notifications.
 */
class AgyService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = RuntimeController.get(this)
        when (intent?.action) {
            ACTION_STOP -> {
                running = false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf(startId)
                return START_NOT_STICKY
            }

            ACTION_UPDATE_STATUS -> {
                activeInstance = this
                val statusText = intent.getStringExtra(EXTRA_STATUS_TEXT)
                    ?: "On-device Antigravity CLI harness active"
                latestStatusText = statusText
                if (running) {
                    acquireWakeLock(refresh = true)
                    val nm = getSystemService(NotificationManager::class.java)
                    nm.notify(NOTIFICATION_ID, buildNotification(this, latestStatusText))
                } else {
                    val notification = buildNotification(this, statusText)
                    if (Build.VERSION.SDK_INT >= 34) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    running = true
                    acquireWakeLock(refresh = true)
                    registerNetworkCallback(controller)
                }
                return START_STICKY
            }

            ACTION_RUN_AUTOMATIONS -> {
                val wasRunning = running
                activeInstance = this
                val notification = buildNotification(this, "Running scheduled automation…")
                if (Build.VERSION.SDK_INT >= 34) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                acquireWakeLock(refresh = true)
                AutomationScheduler.runDueHeadless(this) {
                    mainHandler.post {
                        if (!wasRunning && !running) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                            } else {
                                @Suppress("DEPRECATION")
                                stopForeground(true)
                            }
                            stopSelf(startId)
                        } else if (running) {
                            updateTurnStatus(this, latestStatusText)
                        }
                    }
                }
                return START_NOT_STICKY
            }

            else -> {
                activeInstance = this
                val statusText = intent?.getStringExtra(EXTRA_STATUS_TEXT)
                    ?: latestStatusText
                latestStatusText = statusText
                val notification = buildNotification(this, statusText)
                if (Build.VERSION.SDK_INT >= 34) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                running = true
                acquireWakeLock()
                registerNetworkCallback(controller)
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        running = false
        if (activeInstance === this) {
            activeInstance = null
        }
        networkCallback?.let { cb ->
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            runCatching { cm.unregisterNetworkCallback(cb) }
        }
        networkCallback = null
        wakeLock?.let {
            if (it.isHeld) runCatching { it.release() }
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireWakeLock(refresh: Boolean = false) {
        if (!refresh && wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "antigravity-go:runtime").apply {
                setReferenceCounted(false)
            }
        }
        runCatching { wakeLock?.acquire(60 * 60 * 1000L) }
    }

    private fun registerNetworkCallback(controller: RuntimeController) {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                val dnsCount = linkProperties.dnsServers.size
                controller.noteNetworkChange("Network updated ($dnsCount DNS servers)")
            }

            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
                controller.noteNetworkBlocked(blocked)
            }
        }
        if (runCatching { cm.registerDefaultNetworkCallback(cb) }.isSuccess) {
            networkCallback = cb
        }
    }

    companion object {
        const val ACTION_START = "io.github.dwicao.antigravity_go.SERVICE_START"
        const val ACTION_STOP = "io.github.dwicao.antigravity_go.SERVICE_STOP"
        const val ACTION_UPDATE_STATUS = "io.github.dwicao.antigravity_go.SERVICE_STATUS"
        const val ACTION_RUN_AUTOMATIONS = "io.github.dwicao.antigravity_go.RUN_AUTOMATIONS"
        const val EXTRA_STATUS_TEXT = "statusText"

        private const val CHANNEL_ID = "agy_runtime_channel"
        private const val NOTIFICATION_ID = 1001
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        var running: Boolean = false
            private set

        @Volatile
        private var activeInstance: AgyService? = null

        @Volatile
        private var latestStatusText: String = "On-device Antigravity CLI harness active"

        fun refreshWakeLock(context: Context) {
            if (!running) return
            val svc = activeInstance
            if (svc != null) {
                svc.acquireWakeLock(refresh = true)
                return
            }
            val intent = Intent(context.applicationContext, AgyService::class.java).apply {
                action = ACTION_UPDATE_STATUS
                putExtra(EXTRA_STATUS_TEXT, latestStatusText)
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.applicationContext.startForegroundService(intent)
                } else {
                    context.applicationContext.startService(intent)
                }
            }
        }

        fun updateTurnStatus(context: Context, statusText: String) {
            latestStatusText = statusText
            if (!running) return
            if (Looper.myLooper() != Looper.getMainLooper()) {
                val app = context.applicationContext
                mainHandler.post { updateTurnStatus(app, statusText) }
                return
            }
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, buildNotification(context, statusText))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val mgr = context.getSystemService(NotificationManager::class.java)
                if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                    mgr.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            "Antigravity Runtime",
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            setShowBadge(false)
                        }
                    )
                }
            }
        }

        private fun buildNotification(context: Context, statusText: String): Notification {
            ensureChannel(context)
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pending = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("Antigravity Go")
                .setContentText(statusText)
                .setSmallIcon(R.drawable.ic_stat_agy)
                .setContentIntent(pending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
    }
}
