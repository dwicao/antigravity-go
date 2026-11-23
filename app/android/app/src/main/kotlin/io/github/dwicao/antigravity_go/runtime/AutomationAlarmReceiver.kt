package io.github.dwicao.antigravity_go.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Receives [AlarmManager] wakeups and `BOOT_COMPLETED` broadcasts to execute due scheduled
 * automations via [AgyService] even when the Flutter UI is suspended or closed.
 */
class AutomationAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action == Intent.ACTION_BOOT_COMPLETED) {
            AutomationScheduler.scheduleNextAlarm(context)
            return
        }
        val svcIntent = Intent(context.applicationContext, AgyService::class.java).apply {
            this.action = AgyService.ACTION_RUN_AUTOMATIONS
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.applicationContext.startForegroundService(svcIntent)
            } else {
                context.applicationContext.startService(svcIntent)
            }
        }
    }

    companion object {
        const val ACTION_CHECK_AUTOMATIONS = "io.github.dwicao.antigravity_go.CHECK_AUTOMATIONS"
    }
}
