package io.github.dwicao.antigravity_go.runtime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.dwicao.antigravity_go.MainActivity
import io.github.dwicao.antigravity_go.R

/**
 * Posts and cancels high-priority actionable notifications with Approve / Deny /
 * Deny w/ Comment (`RemoteInput`) buttons for background ACP prompts, plus
 * low-importance Subagent progress notifications with a Cancel button.
 */
object ApprovalNotificationHelper {
    const val CHANNEL_APPROVAL = "agy_approvals"
    const val CHANNEL_SUBAGENTS = "agy_subagents"
    const val NOTIFICATION_ID = 4301
    const val SUBAGENT_NOTIFICATION_ID_BASE = 4350

    const val ACTION_APPROVE = "io.github.dwicao.antigravity_go.ACTION_APPROVE_TOOL"
    const val ACTION_DENY = "io.github.dwicao.antigravity_go.ACTION_DENY_TOOL"
    const val ACTION_DENY_WITH_COMMENT = "io.github.dwicao.antigravity_go.ACTION_DENY_WITH_COMMENT"
    const val ACTION_CANCEL_SUBAGENT = "io.github.dwicao.antigravity_go.ACTION_CANCEL_SUBAGENT"

    const val KEY_APPROVAL_COMMENT = "agy_approval_comment"
    const val EXTRA_TURN_ID = "turnId"
    const val EXTRA_REQUEST_ID = "requestId"
    const val EXTRA_OPTION_ID = "optionId"
    const val EXTRA_APPROVED = "approved"
    const val EXTRA_SUBAGENT_ID = "subagentId"
    const val EXTRA_NOTIFICATION_ID = "notificationId"

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
                        description = "Actionable Approve / Deny / Comment prompts for agent tools"
                    }
                )
            }
            if (mgr.getNotificationChannel(CHANNEL_SUBAGENTS) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_SUBAGENTS,
                        "Subagent Progress",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Live progress and cancel controls for running subagents"
                        setShowBadge(false)
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

        val replyIntent = Intent(appCtx, ApprovalNotificationReceiver::class.java).apply {
            action = ACTION_DENY_WITH_COMMENT
            putExtra(EXTRA_TURN_ID, turnId)
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_OPTION_ID, denyOptionId)
            putExtra(EXTRA_APPROVED, false)
        }
        val replyFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val replyPending = PendingIntent.getBroadcast(
            appCtx,
            4303,
            replyIntent,
            replyFlags,
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

        val remoteInput = RemoteInput.Builder(KEY_APPROVAL_COMMENT)
            .setLabel("Reason or new instruction")
            .build()
        val denyWithCommentAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_edit,
            "Deny w/ Comment",
            replyPending,
        )
            .addRemoteInput(remoteInput)
            .build()

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
            .addAction(denyWithCommentAction)

        return runCatching {
            mgr.notify(NOTIFICATION_ID, builder.build())
            true
        }.getOrDefault(false)
    }

    fun postSubagentProgress(
        context: Context,
        subagentId: String,
        title: String,
        message: String,
        progress: Int = -1,
        turnId: String = "",
        ongoing: Boolean = true,
    ): Int {
        val appCtx = context.applicationContext
        val mgr = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return -1
        ensureChannel(appCtx)

        val notifId = SUBAGENT_NOTIFICATION_ID_BASE + (subagentId.hashCode() and 0x0FFF)
        val openIntent = Intent(appCtx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val openPending = PendingIntent.getActivity(
            appCtx,
            notifId,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val cancelIntent = Intent(appCtx, ApprovalNotificationReceiver::class.java).apply {
            action = ACTION_CANCEL_SUBAGENT
            putExtra(EXTRA_TURN_ID, turnId)
            putExtra(EXTRA_SUBAGENT_ID, subagentId)
            putExtra(EXTRA_NOTIFICATION_ID, notifId)
        }
        val cancelPending = PendingIntent.getBroadcast(
            appCtx,
            notifId + 10000,
            cancelIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appCtx, CHANNEL_SUBAGENTS)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appCtx)
        }
        builder
            .setContentTitle(title.ifBlank { "Subagent running" })
            .setContentText(message.ifBlank { "Working in background…" })
            .setSmallIcon(R.drawable.ic_stat_agy)
            .setContentIntent(openPending)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Cancel",
                    cancelPending,
                ).build()
            )
        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else if (ongoing) {
            builder.setProgress(0, 0, true)
        }

        return runCatching {
            mgr.notify(notifId, builder.build())
            notifId
        }.getOrDefault(-1)
    }

    fun cancelSubagentNotification(context: Context, subagentId: String) {
        val mgr = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val notifId = SUBAGENT_NOTIFICATION_ID_BASE + (subagentId.hashCode() and 0x0FFF)
        runCatching { mgr.cancel(notifId) }
    }

    fun cancel(context: Context) {
        val mgr = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        runCatching { mgr.cancel(NOTIFICATION_ID) }
    }
}
