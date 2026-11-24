package io.github.dwicao.antigravity_go.phone

import android.content.Context
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Process-wide holder for Phone Control state, loopback [PhoneMcpServer],
 * persistent per-app [SafetyGate] rules, and bounded action log history.
 */
object PhoneControlCoordinator {
    data class McpEndpoint(
        val port: Int,
        val authToken: String,
        val url: String,
    )

    data class ActionHistoryEntry(
        val action: String,
        val target: String,
        val allowed: Boolean,
        val reason: String,
        val timestampMs: Long,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "action" to action,
            "target" to target,
            "allowed" to allowed,
            "reason" to reason,
            "timestampMs" to timestampMs,
        )
    }

    private const val PREFS_NAME = "agy_phone_rules"
    private const val MAX_HISTORY = 200

    @Volatile
    var enabled: Boolean = false
        private set

    @Volatile
    var safetyStrict: Boolean = true

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var actionListener: ((String, String, Boolean, String) -> Unit)? = null

    private val history = CopyOnWriteArrayList<ActionHistoryEntry>()
    private val customRules = ConcurrentHashMap<String, SafetyGate.AppRuleMode>()

    val mcpServer = PhoneMcpServer(
        isStrictMode = { safetyStrict },
        contextProvider = { appContext },
        onActionLogged = { action, target, allowed, reason ->
            recordAction(action, target, allowed, reason)
            actionListener?.invoke(action, target, allowed, reason)
        },
    )

    fun bindContext(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        loadRules(ctx)
    }

    private fun loadRules(context: Context) {
        runCatching {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            customRules.clear()
            for ((k, v) in prefs.all) {
                val mode = SafetyGate.AppRuleMode.fromString(v?.toString())
                if (mode != null && k.isNotBlank()) {
                    customRules[k] = mode
                }
            }
        }
    }

    fun getAppRules(): Map<String, String> =
        customRules.entries.associate { (k, v) -> k to v.name.lowercase() }

    fun setAppRule(packageName: String, modeRaw: String?) {
        val clean = packageName.trim()
        if (clean.isEmpty()) return
        val mode = SafetyGate.AppRuleMode.fromString(modeRaw)
        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (mode == null) {
            customRules.remove(clean)
            prefs?.edit()?.remove(clean)?.apply()
        } else {
            customRules[clean] = mode
            prefs?.edit()?.putString(clean, mode.name.lowercase())?.apply()
        }
    }

    fun evaluateWithRules(
        packageName: String?,
        action: String,
        targetLabel: String? = null,
        isPasswordField: Boolean = false,
    ): SafetyGate.Decision = SafetyGate.evaluate(
        strictMode = safetyStrict,
        packageName = packageName,
        action = action,
        targetLabel = targetLabel,
        isPasswordField = isPasswordField,
        customRules = customRules,
    )

    fun recordAction(action: String, target: String, allowed: Boolean, reason: String) {
        history.add(
            0,
            ActionHistoryEntry(
                action = action,
                target = target,
                allowed = allowed,
                reason = reason,
                timestampMs = System.currentTimeMillis(),
            ),
        )
        while (history.size > MAX_HISTORY) {
            runCatching { history.removeAt(history.size - 1) }
        }
    }

    fun getActionLog(): List<Map<String, Any?>> = history.map { it.toMap() }

    fun clearActionLog() {
        history.clear()
    }

    fun setListener(listener: ((String, String, Boolean, String) -> Unit)?) {
        actionListener = listener
    }

    fun setEnabled(enable: Boolean) {
        enabled = enable
        if (enable) {
            mcpServer.start()
        } else {
            mcpServer.stop()
        }
    }

    fun currentMcpEndpoint(): McpEndpoint? {
        if (!enabled) return null
        val p = mcpServer.port ?: return null
        val tok = mcpServer.authToken ?: return null
        return McpEndpoint(
            port = p,
            authToken = tok,
            url = "http://127.0.0.1:$p/mcp",
        )
    }
}
