package io.github.dwicao.antigravity_go.runtime

import io.github.dwicao.antigravity_go.phone.PhoneControlCoordinator
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStreamWriter
import java.util.Base64
import java.util.Collections
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal class TerminalProc(
    val process: Process,
    val command: String,
    val startedAtMs: Long = System.currentTimeMillis(),
    val output: StringBuffer = StringBuffer(),
    @Volatile var exitCode: Int? = null,
)

internal data class ActiveAcp(
    val process: Process,
    val writer: OutputStreamWriter,
    val env: Map<String, String>,
    val defaultCwd: File,
    val agent: String? = null,
    val workerSignature: String = "",
    @Volatile var promptSummary: String,
    val startedAtMs: Long = System.currentTimeMillis(),
    val nextId: AtomicInteger = AtomicInteger(1),
    @Volatile var sessionId: String? = null,
    @Volatile var currentTurnId: String? = null,
    @Volatile var promptReqId: Int = -1,
    @Volatile var newSessionReqId: Int = -1,
    @Volatile var promptSent: Boolean = false,
    @Volatile var pendingPromptText: String? = null,
    @Volatile var pendingPromptAttachments: List<String> = emptyList(),
    @Volatile var lastModelId: String? = null,
    @Volatile var lastEffort: String? = null,
    @Volatile var lastModeCli: String? = null,
    @Volatile var pendingModelId: String? = null,
    @Volatile var pendingEffort: String? = null,
    @Volatile var pendingModeCli: String? = null,
    @Volatile var standbyReady: Boolean = false,
    @Volatile var onAuthRetryTurn: (() -> Boolean)? = null,
    val claimSignal: CompletableFuture<String> = CompletableFuture(),
    val configLock: Any = Any(),
    val pendingConfigReqIds: MutableSet<Int> = Collections.synchronizedSet(mutableSetOf()),
    val cancelled: AtomicBoolean = AtomicBoolean(false),
    val exitEmittedTurnIds: ConcurrentHashMap<String, Boolean> = ConcurrentHashMap(),
    val terminals: ConcurrentHashMap<String, TerminalProc> = ConcurrentHashMap(),
)

/**
 * JSON-RPC helpers for ACP `session/new`, `session/set_config_option`, and `session/prompt`
 * (including image attachments and live Phone Control MCP server registration).
 */
internal object AcpConfigAndPromptHelper {
    fun summarizeCommand(raw: String, maxLen: Int = 80): String {
        val singleLine = raw.trim().replace(Regex("\\s+"), " ")
        if (singleLine.isEmpty()) return "Shell command"
        return if (singleLine.length > maxLen) "${singleLine.take(maxLen - 1)}…" else singleLine
    }

    fun buildMcpServersArray(): JSONArray {
        val arr = JSONArray()
        val endpoint = PhoneControlCoordinator.currentMcpEndpoint()
        if (endpoint != null) {
            arr.put(
                JSONObject()
                    .put("type", "http")
                    .put("name", "phone-control")
                    .put("url", endpoint.url)
                    .put(
                        "headers",
                        JSONArray().put(
                            JSONObject()
                                .put("name", "Authorization")
                                .put("value", "Bearer ${endpoint.authToken}"),
                        ),
                    ),
            )
        }
        return arr
    }

    fun queueConfigOptions(
        active: ActiveAcp,
        writer: OutputStreamWriter,
        sessionId: String,
        modelId: String?,
        effort: String?,
        modeCli: String?,
        skipPermissions: Boolean,
    ) {
        if (!modelId.isNullOrBlank() && modelId != active.lastModelId) {
            active.lastModelId = modelId
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "model")
                            .put("value", modelId)
                    )
            )
        }
        val lowerModel = modelId?.lowercase().orEmpty()
        val effectiveEffort = effort?.takeIf {
            it.isNotBlank() &&
                !lowerModel.contains("orchestrator") &&
                !lowerModel.contains("gpt-oss")
        }
        if (effectiveEffort != null && effectiveEffort != active.lastEffort) {
            active.lastEffort = effectiveEffort
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "effort")
                            .put("value", effectiveEffort)
                    )
            )
        }
        val safeModeCli = when (modeCli?.lowercase()?.trim()) {
            null, "", "auto" -> if (skipPermissions) null else "default"
            else -> modeCli
        }
        if (!safeModeCli.isNullOrBlank() && safeModeCli != active.lastModeCli) {
            active.lastModeCli = safeModeCli
            val cfgId = active.nextId.getAndIncrement()
            active.pendingConfigReqIds.add(cfgId)
            sendJson(
                writer,
                JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", cfgId)
                    .put("method", "session/set_config_option")
                    .put(
                        "params",
                        JSONObject()
                            .put("sessionId", sessionId)
                            .put("configId", "mode")
                            .put("value", safeModeCli)
                    )
            )
        }
    }

    fun sendPromptRpc(
        writer: OutputStreamWriter,
        reqId: Int,
        sessionId: String,
        prompt: String,
        attachments: List<String>,
    ) {
        val blocks = JSONArray().put(
            JSONObject()
                .put("type", "text")
                .put("text", prompt)
        )
        for (rawPath in attachments) {
            val file = File(rawPath)
            if (!file.isFile) continue
            val ext = file.extension.lowercase()
            val mime = when (ext) {
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "gif" -> "image/gif"
                else -> null
            } ?: continue
            if (file.length() <= 0L || file.length() > 4L * 1024L * 1024L) continue
            runCatching {
                val b64 = Base64.getEncoder().encodeToString(file.readBytes())
                blocks.put(
                    JSONObject()
                        .put("type", "image")
                        .put("mimeType", mime)
                        .put("data", b64)
                )
            }
        }
        sendJson(
            writer,
            JSONObject()
                .put("jsonrpc", "2.0")
                .put("id", reqId)
                .put("method", "session/prompt")
                .put(
                    "params",
                    JSONObject()
                        .put("sessionId", sessionId)
                        .put("prompt", blocks)
                )
        )
    }

    fun sendJson(writer: OutputStreamWriter, obj: JSONObject) {
        synchronized(writer) {
            writer.write(obj.toString())
            writer.write("\n")
            writer.flush()
        }
    }
}
