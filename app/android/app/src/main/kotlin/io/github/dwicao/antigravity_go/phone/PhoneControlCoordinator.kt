package io.github.dwicao.antigravity_go.phone

/**
 * Process-wide holder for Phone Control state and loopback [PhoneMcpServer],
 * allowing both [PhonePlugin] (Flutter UI channel) and runtime/ACP launchers
 * to inspect and wire the live HTTP MCP endpoint when enabled.
 */
object PhoneControlCoordinator {
    data class McpEndpoint(
        val port: Int,
        val authToken: String,
        val url: String,
    )

    @Volatile
    var enabled: Boolean = false
        private set

    @Volatile
    var safetyStrict: Boolean = true

    @Volatile
    private var appContext: android.content.Context? = null

    @Volatile
    private var actionListener: ((String, String, Boolean, String) -> Unit)? = null

    val mcpServer = PhoneMcpServer(
        isStrictMode = { safetyStrict },
        contextProvider = { appContext },
        onActionLogged = { action, target, allowed, reason ->
            actionListener?.invoke(action, target, allowed, reason)
        },
    )

    fun bindContext(context: android.content.Context) {
        appContext = context.applicationContext
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
