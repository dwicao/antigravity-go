package io.github.dwicao.antigravity_go

import io.github.dwicao.antigravity_go.performance.PerformanceClassifier
import io.github.dwicao.antigravity_go.performance.RefreshRateCoordinator
import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import io.github.dwicao.antigravity_go.phone.SafetyGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DshAdoptFeaturesTest {

    @Before
    fun resetCoordinator() {
        PhoneControlCoordinator.clearActionLog()
        RefreshRateCoordinator.setMode("auto")
    }

    @Test
    fun performanceClassifierCategorizesTiersAndModes() {
        assertEquals("low", PerformanceClassifier.classifyDeviceTier(3500L, 8))
        assertEquals("low", PerformanceClassifier.classifyDeviceTier(8192L, 4))
        assertEquals("medium", PerformanceClassifier.classifyDeviceTier(6144L, 8))
        assertEquals("high", PerformanceClassifier.classifyDeviceTier(12288L, 8))

        assertEquals("max", PerformanceClassifier.normalizeRefreshMode("MAX"))
        assertEquals("system", PerformanceClassifier.normalizeRefreshMode("system"))
        assertEquals("auto", PerformanceClassifier.normalizeRefreshMode("unknown"))
    }

    @Test
    fun safetyGateEnforcesPerAppBlockAndKeepsPasswordProtected() {
        val rules = mapOf(
            "com.example.reader" to SafetyGate.AppRuleMode.ALLOW,
            "com.example.blocked" to SafetyGate.AppRuleMode.BLOCK,
        )

        val blocked = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.blocked",
            action = "tap",
            customRules = rules,
        )
        assertFalse(blocked.allowed)
        assertTrue(blocked.reason.contains("App Rule"))

        val allowed = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.reader",
            action = "tap",
            customRules = rules,
        )
        assertTrue(allowed.allowed)

        val passwordProtected = SafetyGate.evaluate(
            strictMode = true,
            packageName = "com.example.reader",
            action = "type",
            isPasswordField = true,
            customRules = rules,
        )
        assertFalse(passwordProtected.allowed)
    }

    @Test
    fun phoneCoordinatorRecordsAndClearsActionLog() {
        PhoneControlCoordinator.recordAction("tap", "Submit", true, "Permitted tap")
        PhoneControlCoordinator.recordAction("type", "Password", false, "Blocked")

        val entries = PhoneControlCoordinator.getActionLog()
        assertEquals(2, entries.size)
        assertEquals("type", entries[0]["action"])
        assertEquals(false, entries[0]["allowed"])

        PhoneControlCoordinator.clearActionLog()
        assertTrue(PhoneControlCoordinator.getActionLog().isEmpty())
    }
}
