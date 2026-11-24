package io.github.dwicao.antigravity_go.phone

/**
 * Pure safety gate for Phone Control: blocks sensitive banking, payment,
 * authenticator, and password-manager packages when strict mode is active,
 * and supports per-package custom rules (`allow` / `confirm` / `block`).
 */
object SafetyGate {
    enum class AppRuleMode {
        ALLOW,
        CONFIRM,
        BLOCK;

        companion object {
            fun fromString(raw: String?): AppRuleMode? = when (raw?.lowercase()?.trim()) {
                "allow" -> ALLOW
                "confirm" -> CONFIRM
                "block" -> BLOCK
                else -> null
            }
        }
    }

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
        isPasswordField: Boolean = false,
        customRules: Map<String, AppRuleMode> = emptyMap(),
    ): Decision {
        val pkg = packageName?.lowercase()?.trim().orEmpty()
        val matchedRule = customRules.entries.firstOrNull { (k, _) ->
            val clean = k.lowercase().trim()
            clean.isNotEmpty() && (pkg == clean || pkg.contains(clean))
        }?.value

        if (matchedRule == AppRuleMode.BLOCK) {
            return Decision(
                allowed = false,
                reason = "Blocked by App Rule ($packageName)",
            )
        }
        if (isPasswordField) {
            return Decision(
                allowed = false,
                reason = "Blocked by SafetyGate: password/PIN input field protected",
            )
        }
        if (!strictMode) {
            return Decision(allowed = true, reason = "Allowed (strict mode relaxed by user)")
        }
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
        if (matchedRule == AppRuleMode.ALLOW) {
            return Decision(allowed = true, reason = "Allowed by App Rule ($action)")
        }
        return Decision(allowed = true, reason = "Permitted $action")
    }
}
