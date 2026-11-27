package io.github.dwicao.antigravity_go.runtime

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionVariableStoreTest {
    @Test
    fun savesResolvesFieldsAndPreservesUnknownEnvVars() {
        val store = SessionVariableStore(inlineThresholdChars = 100)
        val jsonPayload = """{"cohort":"W1","users":[{"id":"u_1"},{"id":"u_2"}]}"""
        val entry = store.save(
            toolName = "terminal",
            rawOutput = jsonPayload,
            target = "query_users",
            explicitName = "visits",
        )
        assertEquals("visits", entry.name)
        assertEquals("W1", store.resolveText("\$visits.cohort"))
        assertEquals("u_2", store.resolveText("\${visits.users[1].id}"))
        assertEquals("2", store.resolveText("\$visits.users.length"))
        assertEquals("\$HOME/W1", store.resolveText("\$HOME/\$visits.cohort"))
        assertEquals("literal=\$visits", store.resolveText("literal=\\\$visits"))
    }

    @Test
    fun formatCompactHandleAndResolveJsonArgsWorkCorrectly() {
        val store = SessionVariableStore(inlineThresholdChars = 120)
        val huge = "START\n" + "line_data\n".repeat(100) + "END"
        val entry = store.save(toolName = "read_file", rawOutput = huge, explicitName = "big_doc")
        val handle = store.formatCompactHandle(entry, headChars = 50, tailChars = 30)
        assertTrue(handle.contains("[VAR STORED: \$big_doc"))
        assertTrue(handle.length < huge.length)

        val resolvedArgs = store.resolveJsonArgs(
            JSONObject()
                .put("save_as", "big_doc")
                .put("content", "\$big_doc"),
        )
        assertEquals("big_doc", resolvedArgs.getString("save_as"))
        assertEquals(huge, resolvedArgs.getString("content"))
    }
}
