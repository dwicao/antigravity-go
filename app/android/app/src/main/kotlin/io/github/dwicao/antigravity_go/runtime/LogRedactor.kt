package io.github.dwicao.antigravity_go.runtime

/**
 * Credential & ANSI masking before runtime output enters the tail buffer,
 * crash classifier, or Flutter logs (modeled on DSH-Go's LogRedactor.kt).
 */
class LogRedactor {
    private var privateKeyLines = 0

    fun line(raw: String): String {
        if (privateKeyLines >= PRIVATE_KEY_LINES) privateKeyLines = 0
        val clean = ANSI.replace(raw, "")
        val sb = StringBuilder()
        var at = 0
        while (at < clean.length || privateKeyLines != 0) {
            if (privateKeyLines != 0) {
                val end = KEY_END.find(clean, at)
                if (end == null) {
                    privateKeyLines++
                    return sb.append(MASK).toString()
                }
                sb.append(MASK).append(end.value)
                at = end.range.last + 1
                privateKeyLines = 0
            } else {
                val begin = KEY_BEGIN.find(clean, at)
                if (begin == null) return redact(sb.append(clean.substring(at)).toString())
                sb.append(clean, at, begin.range.first)
                val end = KEY_END.find(clean, begin.range.last + 1)
                if (end == null) {
                    privateKeyLines = 1
                    val prefix = redact(sb.toString())
                    return "$prefix${begin.value}"
                }
                sb.append(MASK)
                at = end.range.last + 1
            }
        }
        return redact(sb.toString())
    }

    companion object {
        private const val MASK = "••••"
        private const val PRIVATE_KEY_LINES = 128
        private const val MAX_LINE_LENGTH = 2000

        private val ANSI = Regex("""\x1B\[[0-9;?]*[ -/]*[@-~]""")
        private val KEY_BEGIN = Regex("""-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_END = Regex("""-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_BLOCK = Regex("""${KEY_BEGIN.pattern}[\s\S]*?(?:${KEY_END.pattern}|\z)""")
        private val URL_PASSWORD = Regex(
            """([a-z][a-z0-9+.-]{1,15}://[^:\s/@?#]{1,128}:)([^\s/@?#]+)(@)""",
            RegexOption.IGNORE_CASE,
        )
        private val AUTH_HEADER = Regex(
            """(?<![A-Za-z0-9_])(Bearer|Basic)\s+(?!•)[A-Za-z0-9._~+/=-]{6,}""",
            RegexOption.IGNORE_CASE,
        )
        private val PROVIDER_TOKENS = Regex(
            """(?<![A-Za-z0-9_])(?:AIza[0-9A-Za-z_-]{20,}|sk-[0-9A-Za-z_-]{16,}|""" +
                """gh[pousr]_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|""" +
                """glpat-[0-9A-Za-z_-]{16,}|hf_[0-9A-Za-z]{20,}|npm_[0-9A-Za-z]{20,}|""" +
                """(?:AKIA|ASIA)[A-Z0-9]{16})""",
        )
        private val JWT = Regex("""(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}""")

        fun redact(raw: String): String {
            var text = ANSI.replace(raw, "")
            if (text.length > MAX_LINE_LENGTH) {
                text = text.substring(0, MAX_LINE_LENGTH) + "…"
            }
            text = KEY_BLOCK.replace(text, "-----PRIVATE KEY REDACTED-----")
            text = URL_PASSWORD.replace(text) { m -> "${m.groupValues[1]}$MASK${m.groupValues[3]}" }
            text = AUTH_HEADER.replace(text) { m -> "${m.groupValues[1]} $MASK" }
            text = PROVIDER_TOKENS.replace(text) { m ->
                val v = m.value
                val keep = if (v.length > 8) v.substring(0, 6) else ""
                "$keep$MASK"
            }
            text = JWT.replace(text, "eyJ$MASK")
            return text
        }
    }
}
