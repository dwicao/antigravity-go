package io.github.dwicao.antigravity_go.runtime

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * Persists user-defined automations natively on Android, schedules wakeup alarms via
 * [AlarmManager] across process kills, and executes due prompts headlessly via [RuntimeController].
 */
object AutomationScheduler {
    private const val PREFS_NAME = "agy_native_automations"
    private const val KEY_LIST = "automations_json"
    private const val ALARM_REQUEST_CODE = 4201
    private val bgExecutor = Executors.newSingleThreadExecutor()

    private val minuteRegex = Regex("""every\s+(\d+)\s*m""")
    private val hourRegex = Regex("""every\s+(\d+)\s*h""")
    private val timeRegex = Regex("""(\d{1,2}):(\d{2})""")

    fun syncFromDart(context: Context, list: List<Map<String, Any?>>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existingRuns = readNativeRunMap(prefs.getString(KEY_LIST, null))
        val arr = JSONArray()
        for (item in list) {
            val id = item["id"]?.toString() ?: continue
            val obj = JSONObject()
            for ((k, v) in item) {
                if (v != null) obj.put(k, v)
            }
            val prev = existingRuns[id]
            val incomingMs = parseIsoMillis(item["lastRunAt"]?.toString())
            if (prev != null && prev.first > (incomingMs ?: 0L)) {
                obj.put("lastRunAt", prev.second)
                if (!prev.third.isNullOrBlank()) {
                    obj.put("lastStatus", prev.third)
                }
            }
            arr.put(obj)
        }
        prefs.edit().putString(KEY_LIST, arr.toString()).apply()
        scheduleNextAlarm(context)
    }

    fun readNativeRuns(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_LIST, null) ?: return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        runCatching {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                out.add(
                    mapOf(
                        "id" to obj.optString("id"),
                        "lastRunAt" to obj.optString("lastRunAt").takeIf { it.isNotBlank() },
                        "lastStatus" to obj.optString("lastStatus").takeIf { it.isNotBlank() },
                    )
                )
            }
        }
        return out
    }

    fun computeNextDueMillis(item: JSONObject, nowMs: Long = System.currentTimeMillis()): Long? {
        if (!item.optBoolean("enabled", true)) return null
        val raw = item.optString("scheduleLabel", "").trim().lowercase()
        if (raw.isEmpty()) return null
        val lastRunMs = parseIsoMillis(item.optString("lastRunAt").takeIf { it.isNotBlank() })

        minuteRegex.find(raw)?.let { m ->
            val mins = m.groupValues[1].toLongOrNull() ?: return null
            if (mins <= 0) return null
            return if (lastRunMs == null) nowMs else lastRunMs + mins * 60_000L
        }

        hourRegex.find(raw)?.let { m ->
            val hrs = m.groupValues[1].toLongOrNull() ?: return null
            if (hrs <= 0) return null
            return if (lastRunMs == null) nowMs else lastRunMs + hrs * 3_600_000L
        }

        if (raw.contains("hourly")) {
            return if (lastRunMs == null) nowMs else lastRunMs + 3_600_000L
        }

        timeRegex.find(raw)?.let { m ->
            val h = m.groupValues[1].toIntOrNull() ?: return null
            val min = m.groupValues[2].toIntOrNull() ?: return null
            if (h !in 0..23 || min !in 0..59) return null
            val zone = ZoneId.systemDefault()
            val nowZdt = ZonedDateTime.ofInstant(Instant.ofEpochMilli(nowMs), zone)
            val todayTarget = nowZdt.withHour(h).withMinute(min).withSecond(0).withNano(0)
            val todayMs = todayTarget.toInstant().toEpochMilli()
            if (lastRunMs == null || lastRunMs < todayMs) {
                return if (nowMs >= todayMs) nowMs else todayMs
            }
            return todayTarget.plusDays(1).toInstant().toEpochMilli()
        }

        return null
    }

    fun scheduleNextAlarm(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pending = alarmPendingIntent(context)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_LIST, null)
        if (raw.isNullOrBlank()) {
            am.cancel(pending)
            return
        }
        val nowMs = System.currentTimeMillis()
        var earliest: Long? = null
        runCatching {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val nextMs = computeNextDueMillis(obj, nowMs) ?: continue
                if (earliest == null || nextMs < earliest!!) {
                    earliest = nextMs
                }
            }
        }
        val target = earliest
        if (target == null) {
            am.cancel(pending)
            return
        }
        val triggerAt = maxOf(target, nowMs + 15_000L)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
        } else {
            am.set(AlarmManager.RTC_WAKEUP, triggerAt, pending)
        }
    }

    fun runDueHeadless(context: Context, onComplete: () -> Unit) {
        bgExecutor.submit {
            try {
                val appCtx = context.applicationContext
                val ctrl = RuntimeController.get(appCtx)
                if (!ctrl.binaryFile.exists()) return@submit
                val prefs = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val raw = prefs.getString(KEY_LIST, null) ?: return@submit
                val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return@submit
                val nowMs = System.currentTimeMillis()
                var changed = false

                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val nextDue = computeNextDueMillis(obj, nowMs) ?: continue
                    if (nextDue > nowMs) continue
                    val prompt = obj.optString("prompt", "").trim()
                    if (prompt.isEmpty()) continue
                    val modelId = modelIdForTier(obj.optString("modelTier", "flash"))
                    val (exitCode, _) = ctrl.runHeadlessPrompt(prompt, modelId, null)
                    obj.put("lastRunAt", DateTimeFormatter.ISO_INSTANT.format(Instant.now()))
                    obj.put(
                        "lastStatus",
                        if (exitCode == 0) "Completed (background)" else "Failed (exit $exitCode)",
                    )
                    changed = true
                }

                if (changed) {
                    prefs.edit().putString(KEY_LIST, arr.toString()).apply()
                }
                scheduleNextAlarm(appCtx)
            } finally {
                onComplete()
            }
        }
    }

    private fun modelIdForTier(tier: String): String = when (tier) {
        "flashLite" -> "gemini-3.8-flash"
        "pro" -> "gemini-4-neon"
        else -> "gemini-4-hydrogen"
    }

    private fun alarmPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context.applicationContext, AutomationAlarmReceiver::class.java).apply {
            action = AutomationAlarmReceiver.ACTION_CHECK_AUTOMATIONS
        }
        return PendingIntent.getBroadcast(
            context.applicationContext,
            ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun parseIsoMillis(iso: String?): Long? {
        if (iso.isNullOrBlank()) return null
        return runCatching { Instant.parse(iso).toEpochMilli() }.getOrNull()
    }

    private fun readNativeRunMap(raw: String?): Map<String, Triple<Long, String, String?>> {
        if (raw.isNullOrBlank()) return emptyMap()
        val map = HashMap<String, Triple<Long, String, String?>>()
        runCatching {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val id = obj.optString("id")
                val iso = obj.optString("lastRunAt")
                val ms = parseIsoMillis(iso) ?: continue
                val status = obj.optString("lastStatus").takeIf { it.isNotBlank() }
                map[id] = Triple(ms, iso, status)
            }
        }
        return map
    }
}
