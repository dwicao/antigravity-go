package io.github.dwicao.antigravity_go.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.dwicao.antigravity_go.phone.DeviceGatewayHelper

/**
 * Handles flashlight (torch) control requests via broadcast
 * `io.github.dwicao.antigravity_go.ACTION_TORCH`, allowing shell CLI helpers
 * and automations to toggle device torch cleanly.
 */
class TorchReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null || intent.action != ACTION_TORCH) return
        var enabled = intent.getBooleanExtra("enabled", true)
        if (intent.hasExtra("state")) {
            enabled = when (intent.getStringExtra("state")?.lowercase()?.trim()) {
                "off", "0", "false" -> false
                else -> true
            }
        }
        DeviceGatewayHelper.setTorch(context, enabled)
    }

    companion object {
        const val ACTION_TORCH = "io.github.dwicao.antigravity_go.ACTION_TORCH"
    }
}
