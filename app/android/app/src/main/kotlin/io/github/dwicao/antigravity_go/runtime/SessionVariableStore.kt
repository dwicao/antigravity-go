package io.github.dwicao.antigravity_go.runtime

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Thread-safe pass-by-reference variable registry for native `agy acp` and
 * `PhoneMcpServer` tool outputs (`$v_term_*`, `$v_read_*`, `$v_phone_*`, `$v_last`).
 *
 * Only identifiers explicitly stored in this registry are ever resolved so
 * shell environment variables (`$PATH`, `$HOME`), currency (`$100`), or
 * source-code literals remain completely untouched.
 */
class SessionVariableStore(
    private val inlineThresholdChars: Int = 1_200,
    private val maxEntries: Int = 64,
    private val maxTotalChars: Int = 8 * 1024 * 1024,
) {
    data class Entry(
        val name: String,
        val toolName: String,
        val target: String,
        val rawValue: String,
        val charCount: Int,
        val lineCount: Int,
        val summary: String,
    )

    data class CachedFileRead(
        val path: String,
        val startLine: Int,
        val limit: Int,
        val modifiedMs: Long,
        val byteSize: Int,
        val contentHash: Int,
        val varName: String,
        val lineCount: Int,
    )

    companion object {
        @Volatile
        var enabled: Boolean = true

        @Volatile
        var compactPreviewMode: Boolean = true

        val shared = SessionVariableStore()

        private val LOCK_NAMES = setOf(
            "package-lock.json",
            "pnpm-lock.yaml",
            "yarn.lock",
            "cargo.lock",
            "pubspec.lock",
            "composer.lock",
            "gemfile.lock",
            "poetry.lock",
            "pods.manifest.lock",
        )

        fun isLockOrGeneratedFile(path: String): Boolean {
            val norm = path.trim().replace('\\', '/').lowercase()
            val name = norm.substringAfterLast('/')
            if (name in LOCK_NAMES) return true
            return name.endsWith(".g.dart") ||
                name.endsWith(".freezed.dart") ||
                name.endsWith(".min.js") ||
                name.endsWith(".min.css") ||
                name.endsWith(".bundle.js") ||
                name.endsWith(".js.map") ||
                name.endsWith(".css.map")
        }

        private fun quickHash(text: String): Int {
            var h = 0x811c9dc5.toInt()
            for (i in text.indices) {
                h = h xor text[i].code
                h *= 0x01000193
            }
            return h
        }

        private val VALID_NAME_RE = Regex("""^[A-Za-z_][A-Za-z0-9_]*$""")
        private val EXPR_RE = Regex(
            """\\?\$(\{([A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[(?:-?\d+(?::\d*)?|:\d+)\]))*)\}|([A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[(?:-?\d+(?::\d*)?|:\d+)\]))*))""",
        )

        internal fun summarizePayload(rawValue: String): String {
            val trimmed = rawValue.trim()
            val lines = if (rawValue.isEmpty()) 0 else rawValue.count { it == '\n' } + 1
            if ((trimmed.startsWith("{") && trimmed.endsWith("}")) ||
                (trimmed.startsWith("[") && trimmed.endsWith("]"))
            ) {
                val parsed = runCatching { JSONTokener(trimmed).nextValue() }.getOrNull()
                when (parsed) {
                    is JSONArray -> {
                        val firstObj = if (parsed.length() > 0) parsed.optJSONObject(0) else null
                        if (firstObj != null) {
                            val keys = firstObj.keys().asSequence().take(5).joinToString(", ")
                            return "JSON array (${parsed.length()} items, keys: $keys), ${rawValue.length} chars"
                        }
                        return "JSON array (${parsed.length()} items), ${rawValue.length} chars"
                    }
                    is JSONObject -> {
                        val keys = parsed.keys().asSequence().take(6).joinToString(", ")
                        return "JSON object (keys: $keys), ${rawValue.length} chars"
                    }
                }
            }
            return "$lines lines, ${rawValue.length} chars"
        }
    }

    private val vars = ConcurrentHashMap<String, Entry>()
    private val readCache = ConcurrentHashMap<String, CachedFileRead>()
    private val insertionOrder = ArrayDeque<String>()
    private val lock = Any()
    private val counter = AtomicInteger(0)

    @Volatile
    private var latestName: String? = null
    private var totalChars: Int = 0

    private fun readKey(path: String, startLine: Int, limit: Int): String =
        "${path.trim().replace('\\', '/')}|$startLine|$limit"

    fun checkFileRead(
        path: String,
        startLine: Int = 0,
        limit: Int = 0,
        currentContent: String,
        modifiedMs: Long = 0L,
    ): CachedFileRead? {
        if (!enabled || currentContent.length <= inlineThresholdChars) return null
        val key = readKey(path, startLine, limit)
        val rec = readCache[key] ?: return null
        if (rec.varName.isNotEmpty() && get(rec.varName) == null) {
            readCache.remove(key)
            return null
        }
        val hash = quickHash(currentContent)
        if (rec.byteSize == currentContent.length &&
            rec.contentHash == hash &&
            (modifiedMs == 0L || rec.modifiedMs == 0L || rec.modifiedMs == modifiedMs)
        ) {
            return rec
        }
        return null
    }

    fun recordFileRead(
        path: String,
        startLine: Int = 0,
        limit: Int = 0,
        content: String,
        varName: String,
        modifiedMs: Long = 0L,
    ) {
        if (content.length <= inlineThresholdChars) return
        val norm = path.trim().replace('\\', '/')
        val lines = if (content.isEmpty()) 0 else content.count { it == '\n' } + 1
        readCache[readKey(path, startLine, limit)] = CachedFileRead(
            path = norm,
            startLine = startLine,
            limit = limit,
            modifiedMs = modifiedMs,
            byteSize = content.length,
            contentHash = quickHash(content),
            varName = varName,
            lineCount = lines,
        )
    }

    fun invalidateFilePath(path: String) {
        val norm = path.trim().replace('\\', '/')
        readCache.entries.removeIf { it.value.path == norm }
    }

    fun clear() {
        synchronized(lock) {
            vars.clear()
            readCache.clear()
            insertionOrder.clear()
            latestName = null
            totalChars = 0
            counter.set(0)
        }
    }

    fun listEntries(): List<Entry> = synchronized(lock) {
        insertionOrder.mapNotNull { vars[it] }
    }

    fun get(name: String): Entry? {
        if (name == "v_last") {
            return latestName?.let { vars[it] }
        }
        return vars[name]
    }

    fun save(
        toolName: String,
        rawOutput: String,
        target: String = "",
        explicitName: String? = null,
    ): Entry {
        synchronized(lock) {
            val base = deriveBaseName(toolName, target, explicitName)
            var name = base
            if (explicitName == null || !VALID_NAME_RE.matches(base)) {
                while (vars.containsKey(name) || name == "v_last") {
                    name = "${base}_${counter.incrementAndGet()}"
                }
            }
            val old = vars.remove(name)
            if (old != null) {
                totalChars -= old.charCount
                insertionOrder.remove(name)
            }
            val lineCount = if (rawOutput.isEmpty()) 0 else rawOutput.count { it == '\n' } + 1
            val entry = Entry(
                name = name,
                toolName = toolName,
                target = target,
                rawValue = rawOutput,
                charCount = rawOutput.length,
                lineCount = lineCount,
                summary = summarizePayload(rawOutput),
            )
            vars[name] = entry
            insertionOrder.addLast(name)
            latestName = name
            totalChars += entry.charCount
            evictIfNeeded(protectName = name)
            return entry
        }
    }

    private fun evictIfNeeded(protectName: String) {
        while ((vars.size > maxEntries || totalChars > maxTotalChars) && insertionOrder.size > 1) {
            val first = insertionOrder.first()
            val candidate = if (first == protectName) {
                if (insertionOrder.size <= 1) break
                insertionOrder[1].also { insertionOrder.removeAt(1) }
            } else {
                insertionOrder.removeFirst()
            }
            vars.remove(candidate)?.let { removed ->
                totalChars -= removed.charCount
            }
        }
    }

    private fun deriveBaseName(
        toolName: String,
        target: String,
        explicitName: String?,
    ): String {
        val cleanExplicit = explicitName?.trim().orEmpty()
        if (cleanExplicit.isNotEmpty()) {
            val sanitized = cleanExplicit
                .removePrefix("$")
                .replace(Regex("""[^A-Za-z0-9_]+"""), "_")
                .replace(Regex("""_+"""), "_")
                .trim('_')
            if (sanitized.isNotEmpty()) {
                val fixed = if (sanitized[0].isDigit()) "v_$sanitized" else sanitized
                return if (fixed == "v_last") "v_last_val" else fixed.take(32)
            }
        }
        val n = counter.incrementAndGet()
        val lower = toolName.trim().lowercase()
        val prefix = when {
            lower.contains("read") -> "v_read"
            lower.contains("term") || lower.contains("shell") || lower.contains("shizuku") -> "v_term"
            lower.contains("phone") || lower.contains("screen") || lower.contains("browser") -> "v_phone"
            else -> "v_var"
        }
        val slug = target.trim()
            .substringAfterLast('/')
            .split(Regex("""\s+"""))
            .firstOrNull()
            .orEmpty()
            .lowercase()
            .replace(Regex("""[^a-z0-9]+"""), "_")
            .trim('_')
            .take(12)
        if (slug.isEmpty()) return "${prefix}_$n"
        return "${prefix}_${slug}_$n".take(28)
    }

    fun formatCompactHandle(
        entry: Entry,
        thresholdChars: Int = inlineThresholdChars,
        headChars: Int = -1,
        tailChars: Int = -1,
        offloadedPath: String? = null,
    ): String {
        if (!enabled || entry.charCount <= thresholdChars) {
            return entry.rawValue
        }
        val effHead = if (headChars >= 0) headChars else (if (compactPreviewMode) 600 else 1_200)
        val effTail = if (tailChars >= 0) tailChars else (if (compactPreviewMode) 400 else 800)
        val head = entry.rawValue.substring(0, effHead.coerceAtMost(entry.rawValue.length))
        val tailStart = (entry.rawValue.length - effTail).coerceAtLeast(head.length)
        val tail = entry.rawValue.substring(tailStart)
        val omitted = (tailStart - head.length).coerceAtLeast(0)
        return buildString {
            appendLine("[VAR STORED: \$${entry.name} | ${entry.summary}]")
            appendLine(
                "Reuse \$${entry.name} (or \$${entry.name}.field, \$${entry.name}[1:50], \$v_last) directly in `fs/write_text_file`, MCP tool args, or your final reply without re-typing. Use `var_inspect` for slices/grep.",
            )
            if (!offloadedPath.isNullOrBlank()) {
                appendLine("Full log also at: $offloadedPath")
            }
            appendLine("--- PREVIEW ---")
            appendLine(head)
            if (tail.isNotEmpty()) {
                appendLine("\n... [$omitted middle chars stored in \$${entry.name}] ...")
                append(tail)
            }
        }
    }

    fun resolveExpression(exprRaw: String): String? {
        val expr = exprRaw.trim()
        if (expr.isEmpty()) return null
        val sepIdx = expr.indexOfAny(charArrayOf('.', '['))
        val root = if (sepIdx < 0) expr else expr.substring(0, sepIdx)
        if (!VALID_NAME_RE.matches(root)) return null
        val entry = get(root) ?: return null
        if (sepIdx < 0) return entry.rawValue

        val steps = parseSteps(expr.substring(sepIdx)) ?: return null
        if (steps.isEmpty()) return entry.rawValue

        if (steps.size == 1 && steps[0].isSlice) {
            return sliceLines(entry.rawValue, steps[0].sliceStart!!, steps[0].sliceEnd)
        }
        if (steps.size == 1 && steps[0].field != null) {
            when (steps[0].field) {
                "lines" -> return entry.lineCount.toString()
                "chars" -> return entry.charCount.toString()
                "head" -> return sliceLines(entry.rawValue, 1, 20)
                "tail" -> {
                    val lines = entry.rawValue.lines()
                    val start = (lines.size - 19).coerceAtLeast(1)
                    return sliceLines(entry.rawValue, start, lines.size)
                }
            }
        }

        val trimmed = entry.rawValue.trim()
        var current: Any? = runCatching {
            if ((trimmed.startsWith("{") && trimmed.endsWith("}")) ||
                (trimmed.startsWith("[") && trimmed.endsWith("]"))
            ) {
                JSONTokener(trimmed).nextValue()
            } else {
                null
            }
        }.getOrNull()
        if (current == null) {
            if (steps.size == 1 && steps[0].field == "length") return entry.charCount.toString()
            return entry.rawValue
        }

        for (i in steps.indices) {
            val step = steps[i]
            val isLast = i == steps.lastIndex
            when {
                step.isSlice -> {
                    if (current is JSONArray) {
                        val s = (step.sliceStart!! - 1).coerceAtLeast(0)
                        val e = (step.sliceEnd ?: current.length()).coerceAtMost(current.length())
                        val nextArr = JSONArray()
                        for (idx in s until e) nextArr.put(current.get(idx))
                        current = nextArr
                    } else {
                        return sliceLines(current.toString(), step.sliceStart!!, step.sliceEnd)
                    }
                }
                step.index != null -> {
                    if (current is JSONArray) {
                        val len = current.length()
                        val idx = if (step.index < 0) len + step.index else step.index
                        if (idx < 0 || idx >= len) return ""
                        current = current.get(idx)
                    } else {
                        return ""
                    }
                }
                step.field != null -> {
                    val field = step.field
                    when (current) {
                        is JSONObject -> {
                            if (current.has(field)) {
                                current = current.opt(field)
                            } else if (isLast && field == "length") {
                                return current.length().toString()
                            } else if (isLast && field == "keys") {
                                return JSONArray(current.keys().asSequence().toList()).toString()
                            } else if (isLast && field == "json") {
                                return current.toString(2)
                            } else {
                                return ""
                            }
                        }
                        is JSONArray -> {
                            if (isLast && field == "length") return current.length().toString()
                            if (isLast && field == "json") return current.toString(2)
                            return ""
                        }
                        else -> {
                            if (isLast && field == "length") return current.toString().length.toString()
                            return ""
                        }
                    }
                }
            }
        }
        return when (current) {
            null, JSONObject.NULL -> "null"
            is JSONObject -> current.toString()
            is JSONArray -> current.toString()
            else -> current.toString()
        }
    }

    fun inspect(
        nameOrExpr: String,
        startLine: Int? = null,
        limit: Int? = null,
        grep: String? = null,
        maxChars: Int = 6_000,
    ): String {
        val clean = nameOrExpr.trim()
            .removePrefix("$")
            .let { if (it.startsWith("{") && it.endsWith("}")) it.substring(1, it.length - 1) else it }
        val resolved = resolveExpression(clean)
        if (resolved == null) {
            val available = listEntries().joinToString(", ") { "\$${it.name}" }
            return "Variable \"\$$clean\" not found. Available: ${available.ifEmpty { "(none)" }}"
        }
        var text = resolved
        if (!grep.isNullOrBlank()) {
            val re = Regex(grep, RegexOption.IGNORE_CASE)
            val lines = text.lines()
            val matches = ArrayList<String>()
            for (i in lines.indices) {
                if (re.containsMatchIn(lines[i])) {
                    matches.add("${i + 1}: ${lines[i]}")
                    if (matches.size >= 120) break
                }
            }
            text = if (matches.isEmpty()) "(no lines matched /$grep/)" else matches.joinToString("\n")
        } else if (startLine != null || limit != null) {
            val from = (startLine ?: 1).coerceAtLeast(1)
            val count = (limit ?: 120).coerceIn(1, 500)
            text = sliceLines(text, from, from + count - 1)
        }
        if (text.length > maxChars) {
            return "${text.substring(0, maxChars)}\n... [truncated at $maxChars chars; pass startLine/limit or grep]"
        }
        return text.ifEmpty { "(empty)" }
    }

    fun resolveText(input: String): String {
        if (!enabled || vars.isEmpty() || !input.contains('$')) return input
        return EXPR_RE.replace(input) { match ->
            val whole = match.value
            if (whole.startsWith("\\$")) {
                whole.substring(1)
            } else {
                val expr = match.groupValues[2].ifEmpty { match.groupValues[3] }
                resolveExpression(expr) ?: whole
            }
        }
    }

    fun resolveJsonArgs(args: JSONObject): JSONObject {
        if (!enabled || vars.isEmpty() || args.length() == 0) return args
        val out = JSONObject()
        val it = args.keys()
        while (it.hasNext()) {
            val key = it.next()
            val raw = args.opt(key)
            if (key == "save_as" || key == "var_name") {
                out.put(key, raw)
            } else {
                out.put(key, resolveJsonValue(raw))
            }
        }
        return out
    }

    private fun resolveJsonValue(value: Any?): Any? = when (value) {
        is String -> resolveText(value)
        is JSONObject -> resolveJsonArgs(value)
        is JSONArray -> JSONArray().also { arr ->
            for (i in 0 until value.length()) {
                arr.put(resolveJsonValue(value.opt(i)))
            }
        }
        else -> value
    }

    private data class Step(
        val field: String? = null,
        val index: Int? = null,
        val sliceStart: Int? = null,
        val sliceEnd: Int? = null,
        val isSlice: Boolean = false,
    )

    private fun parseSteps(tail: String): List<Step>? {
        val out = mutableListOf<Step>()
        var i = 0
        while (i < tail.length) {
            when (tail[i]) {
                '.' -> {
                    i++
                    val start = i
                    while (i < tail.length && (tail[i].isLetterOrDigit() || tail[i] == '_')) {
                        i++
                    }
                    val field = tail.substring(start, i)
                    if (field.isEmpty()) return null
                    out.add(Step(field = field))
                }
                '[' -> {
                    val close = tail.indexOf(']', i + 1)
                    if (close < 0) return null
                    val inner = tail.substring(i + 1, close).trim()
                    if (inner.contains(':')) {
                        val parts = inner.split(':')
                        if (parts.size != 2) return null
                        val s = if (parts[0].isEmpty()) 1 else parts[0].toIntOrNull() ?: return null
                        val e = if (parts[1].isEmpty()) null else parts[1].toIntOrNull() ?: return null
                        out.add(Step(sliceStart = s, sliceEnd = e, isSlice = true))
                    } else {
                        val idx = inner.toIntOrNull() ?: return null
                        out.add(Step(index = idx))
                    }
                    i = close + 1
                }
                else -> return null
            }
        }
        return out
    }

    private fun sliceLines(text: String, startLine: Int, endLine: Int?): String {
        if (text.isEmpty()) return ""
        val lines = text.split('\n')
        val startIdx = (startLine - 1).coerceIn(0, lines.size)
        val endIdx = endLine?.coerceIn(startIdx, lines.size) ?: lines.size
        if (startIdx >= lines.size) return ""
        return lines.subList(startIdx, endIdx).joinToString("\n")
    }
}
