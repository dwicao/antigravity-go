package io.github.dwicao.antigravity_go.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles Approve / Deny clicks directly from [ApprovalNotificationHelper]
 * without requiring the user to bring the activity to the foreground.
 */
class ApprovalNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != ApprovalNotificationHelper.ACTION_APPROVE &&
            action != ApprovalNotificationHelper.ACTION_DENY
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

        val parsedReqId: Any = requestIdRaw.toLongOrNull() ?: requestIdRaw
        RuntimeController.get(context).handleNotificationPermissionAction(
            turnId = turnId,
            requestId = parsedReqId,
            optionId = optionId,
            approved = approved,
        )
    }
}
