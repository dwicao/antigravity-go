package io.github.dwicao.antigravity_go.phone

/**
 * Pure safety gate for Phone Control: blocks sensitive banking, payment,
 * authenticator, and password-manager packages when strict mode is active.
 */
object SafetyGate {
    data class Decision(
        val allowed: Boolean,
        val reason: String,
    )

    private val protectedPackageTokens = listOf(
        "bank",
        "wallet",
        "paypal",
        "venmo",
        "stripe",
        "alipay",
        "wechat",
        "1password",
        "bitwarden",
        "keepass",
        "lastpass",
        "authenticator",
        "com.android.settings",
        "com.google.android.gms.auth",
    )

    private val sensitiveTextTokens = listOf(
        "password",
        "passcode",
        "pin code",
        "cvv",
        "transfer",
        "confirm payment",
        "authorize payment",
    )

    fun evaluate(
        strictMode: Boolean,
        packageName: String?,
        action: String,
        targetLabel: String? = null,
    ): Decision {
        if (!strictMode) {
            return Decision(allowed = true, reason = "Allowed (strict mode relaxed by user)")
        }
        val pkg = packageName?.lowercase().orEmpty()
        for (token in protectedPackageTokens) {
            if (pkg.contains(token)) {
                return Decision(
                    allowed = false,
                    reason = "Blocked by SafetyGate: protected package ($packageName)",
                )
            }
        }
        val label = targetLabel?.lowercase().orEmpty()
        for (token in sensitiveTextTokens) {
            if (label.contains(token)) {
                return Decision(
                    allowed = false,
                    reason = "Blocked by SafetyGate: sensitive action ($token)",
                )
            }
        }
        return Decision(allowed = true, reason = "Permitted $action")
    }
}
