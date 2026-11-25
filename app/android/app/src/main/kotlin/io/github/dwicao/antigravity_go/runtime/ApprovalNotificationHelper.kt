package io.github.dwicao.antigravity_go.runtime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.dwicao.antigravity_go.MainActivity
import io.github.dwicao.antigravity_go.R

/**
 * Posts and cancels high-priority actionable notifications with Approve / Deny buttons
 * for background ACP `session/request_permission` prompts.
 */
object ApprovalNotificationHelper {
    const val CHANNEL_APPROVAL = "agy_approvals"
    const val NOTIFICATION_ID = 4301
    const val ACTION_APPROVE = "io.github.dwicao.antigravity_go.ACTION_APPROVE_TOOL"
    const val ACTION_DENY = "io.github.dwicao.antigravity_go.ACTION_DENY_TOOL"

    const val EXTRA_TURN_ID = "turnId"
    const val EXTRA_REQUEST_ID = "requestId"
    const val EXTRA_OPTION_ID = "optionId"
    const val EXTRA_APPROVED = "approved"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            if (mgr.getNotificationChannel(CHANNEL_APPROVAL) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_APPROVAL,
                        "Tool Approvals",
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "Actionable Approve / Deny prompts for background agent tools"
                    }
                )
            }
        }
    }

    fun post(
        context: Context,
        turnId: String,
        requestId: String,
        allowOptionId: String,
        denyOptionId: String,
        title: String,
        message: String,
    ): Boolean {
        val appCtx = context.applicationContext
        val mgr = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        ensureChannel(appCtx)

        val openIntent = Intent(appCtx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val openPending = PendingIntent.getActivity(
            appCtx,
            4300,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val approveIntent = Intent(appCtx, ApprovalNotificationReceiver::class.java).apply {
            action = ACTION_APPROVE
            putExtra(EXTRA_TURN_ID, turnId)
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_OPTION_ID, allowOptionId)
            putExtra(EXTRA_APPROVED, true)
        }
        val approvePending = PendingIntent.getBroadcast(
            appCtx,
            4301,
            approveIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val denyIntent = Intent(appCtx, ApprovalNotificationReceiver::class.java).apply {
            action = ACTION_DENY
            putExtra(EXTRA_TURN_ID, turnId)
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_OPTION_ID, denyOptionId)
            putExtra(EXTRA_APPROVED, false)
        }
        val denyPending = PendingIntent.getBroadcast(
            appCtx,
            4302,
            denyIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appCtx, CHANNEL_APPROVAL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appCtx)
        }

        val approveAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Approve",
            approvePending,
        ).build()

        val denyAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Deny",
            denyPending,
        ).build()

        val cleanTitle = title.ifBlank { "Approval needed" }
        val cleanMsg = message.ifBlank { "An agent tool action requires confirmation." }

        builder
            .setContentTitle(cleanTitle)
            .setContentText(cleanMsg)
            .setStyle(Notification.BigTextStyle().bigText(cleanMsg))
            .setSmallIcon(R.drawable.ic_stat_agy)
            .setContentIntent(openPending)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .addAction(approveAction)
            .addAction(denyAction)

        return runCatching {
            mgr.notify(NOTIFICATION_ID, builder.build())
            true
        }.getOrDefault(false)
    }

    fun cancel(context: Context) {
        val mgr = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        runCatching { mgr.cancel(NOTIFICATION_ID) }
    }
}
