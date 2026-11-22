package io.github.dwicao.antigravity_go.phone

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetyGateTest {
    @Test
    fun blocksProtectedPackagesInStrictMode() {
        val bank = SafetyGate.evaluate(true, "com.chase.sig.android.bank", "tap", "Continue")
        assertFalse(bank.allowed)

        val wallet = SafetyGate.evaluate(true, "com.google.android.apps.walletnfcrel", "tap")
        assertFalse(wallet.allowed)

        val settings = SafetyGate.evaluate(true, "com.android.settings", "tap")
        assertFalse(settings.allowed)
    }

    @Test
    fun blocksSensitiveLabelsEvenInRegularApps() {
        val transfer = SafetyGate.evaluate(true, "com.example.app", "tap", "Confirm payment")
        assertFalse(transfer.allowed)
    }

    @Test
    fun allowsSafeAppInteractions() {
        val ok = SafetyGate.evaluate(true, "com.android.chrome", "tap", "Search")
        assertTrue(ok.allowed)
    }
}
