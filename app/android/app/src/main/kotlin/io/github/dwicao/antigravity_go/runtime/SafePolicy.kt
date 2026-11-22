package io.github.dwicao.antigravity_go.runtime

/**
 * Pure JVM safe-mode state machine & exponential backoff policy modeled on DSH-Go's `SafePolicy`.
 */
enum class SafeState(val wire: String) {
    OFF("off"),
    ON("on"),
    PROBATION("probation");

    companion object {
        fun parse(wire: String?): SafeState = entries.firstOrNull { it.wire == wire } ?: OFF
    }
}

object SafePolicy {
    const val STRIKE_LIMIT = 2
    const val HEALTHY_MS = 120_000L

    /** Exponential backoff delays for transient kills/network drops within 10 minutes: 5s, 15s, 45s. */
    fun autoRestartDelay(
        kind: FailureKind,
        exitCode: Int,
        upMs: Long?,
        recentAttempts: List<Long>,
        nowMs: Long,
    ): Long? {
        val retryable = kind == FailureKind.KILLED || kind == FailureKind.NETWORK_ERROR
        if (!retryable || exitCode == 0) return null
        if (kind == FailureKind.KILLED && (upMs == null || upMs <= 15_000L)) return null
        val count = recentAttempts.count { nowMs - it < 600_000L }
        return listOf(5_000L, 15_000L, 45_000L).getOrNull(count)
    }

    fun onManualModeChange(state: SafeState, safeEnabled: Boolean): SafeState {
        return when {
            safeEnabled -> SafeState.ON
            state == SafeState.ON -> SafeState.PROBATION
            else -> SafeState.OFF
        }
    }

    data class Outcome(
        val state: SafeState,
        val strikes: Int,
        val engagedSafeMode: Boolean,
        val notice: String?,
    )

    fun onFailure(
        state: SafeState,
        strikes: Int,
        failure: RunFailure,
        autoSafe: Boolean = true,
    ): Outcome {
        if (failure.safeMode || !failure.kind.countsTowardSafeMode) {
            return Outcome(state, strikes, false, null)
        }
        val nextStrikes = strikes + 1
        return when {
            state == SafeState.PROBATION -> Outcome(
                state = SafeState.ON,
                strikes = nextStrikes,
                engagedSafeMode = true,
                notice = "Normal runtime crashed again during probation; Safe Mode re-enabled (sessions preserved).",
            )
            nextStrikes >= STRIKE_LIMIT && autoSafe -> Outcome(
                state = SafeState.ON,
                strikes = nextStrikes,
                engagedSafeMode = true,
                notice = "Antigravity CLI failed twice at startup; Safe Mode enabled automatically to bypass custom rules/MCP.",
            )
            else -> Outcome(state, nextStrikes, false, null)
        }
    }
}
