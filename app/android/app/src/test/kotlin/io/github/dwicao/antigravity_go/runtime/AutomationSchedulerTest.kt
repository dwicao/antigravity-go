package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutomationSchedulerTest {
    @Test
    fun disabledAutomationReturnsNull() {
        val item = JSONObject()
            .put("enabled", false)
            .put("scheduleLabel", "Every 15m")
        assertNull(AutomationScheduler.computeNextDueMillis(item, 1_000_000L))
    }

    @Test
    fun minuteIntervalSchedulesNowWhenNeverRunAndNextAfterLastRun() {
        val now = 1_700_000_000_000L
        val neverRun = JSONObject()
            .put("enabled", true)
            .put("scheduleLabel", "Every 15m")
        assertEquals(now, AutomationScheduler.computeNextDueMillis(neverRun, now))

        val ranRecently = JSONObject()
            .put("enabled", true)
            .put("scheduleLabel", "Every 15m")
            .put("lastRunAt", "2023-11-14T22:13:20Z")
        val next = AutomationScheduler.computeNextDueMillis(ranRecently, 1_700_000_000_000L)!!
        assertTrue(next > 1_700_000_000_000L)
    }
}
