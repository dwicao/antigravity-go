package io.github.dwicao.antigravity_go.runtime

import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles Approve / Deny / Deny w/ Comment (`RemoteInput`) clicks and Subagent
 * Cancel clicks directly from [ApprovalNotificationHelper].
 */
class ApprovalNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return

        if (action == ApprovalNotificationHelper.ACTION_CANCEL_SUBAGENT) {
            val turnId = intent.getStringExtra(ApprovalNotificationHelper.EXTRA_TURN_ID).orEmpty()
            val subagentId = intent.getStringExtra(ApprovalNotificationHelper.EXTRA_SUBAGENT_ID).orEmpty()
            val notifId = intent.getIntExtra(ApprovalNotificationHelper.EXTRA_NOTIFICATION_ID, -1)
            if (notifId > 0) {
                val nm = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                runCatching { nm?.cancel(notifId) }
            }
            if (subagentId.isNotEmpty()) {
                ApprovalNotificationHelper.cancelSubagentNotification(context, subagentId)
            }
            RuntimeController.get(context).handleNotificationCancelTurn(turnId, subagentId)
            return
        }

        if (action != ApprovalNotificationHelper.ACTION_APPROVE &&
            action != ApprovalNotificationHelper.ACTION_DENY &&
            action != ApprovalNotificationHelper.ACTION_DENY_WITH_COMMENT
        ) {
            return
        }
        ApprovalNotificationHelper.cancel(context)

        val turnId = intent.getStringExtra(ApprovalNotificationHelper.EXTRA_TURN_ID) ?: return
        val requestIdRaw = intent.getStringExtra(ApprovalNotificationHelper.EXTRA_REQUEST_ID) ?: return
        val optionId = intent.getStringExtra(ApprovalNotificationHelper.EXTRA_OPTION_ID) ?: return
        val approved = intent.getBooleanExtra(
            ApprovalNotificationHelper.EXTRA_APPROVED,
            action == ApprovalNotificationHelper.ACTION_APPROVE,
        )
        val comment = if (action == ApprovalNotificationHelper.ACTION_DENY_WITH_COMMENT) {
            RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(ApprovalNotificationHelper.KEY_APPROVAL_COMMENT)
                ?.toString()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        } else {
            null
        }

        val parsedReqId: Any = requestIdRaw.toLongOrNull() ?: requestIdRaw
        RuntimeController.get(context).handleNotificationPermissionAction(
            turnId = turnId,
            requestId = parsedReqId,
            optionId = optionId,
            approved = approved,
            comment = comment,
        )
    }
}
