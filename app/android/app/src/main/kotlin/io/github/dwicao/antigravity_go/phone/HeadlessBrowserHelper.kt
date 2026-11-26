package io.github.dwicao.antigravity_go.phone

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.github.dwicao.antigravity_go.runtime.UrlSafetyGuard
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Isolated headless offscreen WebView automation handler adopted from
 * antigravity-android PR #37 (`WebBrowserAutomationHandler`).
 *
 * Security model:
 * - Zero `@JavascriptInterface` bindings.
 * - File/content/geolocation/popup access disabled.
 * - Strict `http://` / `https://` allowlist enforced on navigation & redirects.
 */
object HeadlessBrowserHelper {
    private const val DEFAULT_WIDTH = 1080
    private const val DEFAULT_HEIGHT = 1920
    private const val DEFAULT_NAV_TIMEOUT_MS = 15_000L
    private const val DEFAULT_EVAL_TIMEOUT_MS = 10_000L
    private const val MAX_CONSOLE_LOGS = 200

    private val mainHandler = Handler(Looper.getMainLooper())
    private val opLock = Any()
    private val consoleLock = Any()
    private val consoleBuffer = ArrayDeque<JSONObject>()
    private val navCounter = AtomicLong(0L)

    @Volatile private var webView: WebView? = null
    @Volatile private var viewportWidth = DEFAULT_WIDTH
    @Volatile private var viewportHeight = DEFAULT_HEIGHT
    @Volatile private var activeNavId = 0L
    @Volatile private var activeNavLatch: CountDownLatch? = null
    @Volatile private var lastLoadError: String? = null
    @Volatile private var lastLoadedUrl: String = ""

    fun handle(context: Context, payload: JSONObject): JSONObject {
        val appCtx = context.applicationContext
        val action = payload.optString("action", "").trim().lowercase(Locale.ROOT)
        synchronized(opLock) {
            return when (action) {
                "navigate" -> handleNavigate(appCtx, payload)
                "eval", "evaluate" -> handleEval(appCtx, payload.optString("script", ""), payload.optLong("timeoutMs", DEFAULT_EVAL_TIMEOUT_MS))
                "click" -> handleClick(appCtx, payload.optString("selector", ""))
                "type", "fill" -> handleType(appCtx, payload.optString("selector", ""), payload.optString("text", ""))
                "get_text", "snapshot" -> handleGetText(appCtx, payload.optInt("maxChars", 16_000))
                "screenshot" -> handleScreenshot(appCtx, payload.optString("path", ""))
                "console_logs" -> handleConsoleLogs(payload.optBoolean("clear", false))
                "close" -> handleClose()
                else -> err("Unsupported phone_browser action: $action")
            }
        }
    }

    fun isHttpOrHttpsUrl(raw: String?): Boolean {
        if (raw.isNullOrBlank()) return false
        val uri = runCatching { Uri.parse(raw.trim()) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
        return (scheme == "http" || scheme == "https") && !uri.host.isNullOrBlank()
    }

    private fun handleNavigate(context: Context, payload: JSONObject): JSONObject {
        val url = payload.optString("url", "").trim()
        if (!isHttpOrHttpsUrl(url)) {
            return err("Only http:// and https:// URLs are allowed")
        }
        val guard = UrlSafetyGuard.evaluateUrl(url)
        if (!guard.allowed && !isLoopbackHost(url)) {
            return err(guard.reason)
        }
        viewportWidth = payload.optInt("width", DEFAULT_WIDTH).coerceIn(320, 2160)
        viewportHeight = payload.optInt("height", DEFAULT_HEIGHT).coerceIn(320, 3840)
        val timeoutMs = payload.optLong("timeoutMs", DEFAULT_NAV_TIMEOUT_MS).coerceIn(1000L, 25_000L)

        val latch = CountDownLatch(1)
        val navId = navCounter.incrementAndGet()
        activeNavId = navId
        activeNavLatch = latch
        lastLoadError = null

        val initErr = AtomicReference<String?>(null)
        val ready = CountDownLatch(1)
        mainHandler.post {
            try {
                val wv = ensureWebViewOnMain(context)
                layoutOffscreen(wv)
                wv.loadUrl(url)
            } catch (t: Throwable) {
                initErr.set(t.message ?: t.toString())
            } finally {
                ready.countDown()
            }
        }
        ready.await(5, TimeUnit.SECONDS)
        initErr.get()?.let { return err(it) }

        val finished = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        val titleRef = AtomicReference("")
        val curUrlRef = AtomicReference(lastLoadedUrl.ifEmpty { url })
        runOnMainSync {
            val wv = webView ?: return@runOnMainSync
            titleRef.set(wv.title.orEmpty())
            curUrlRef.set(wv.url.orEmpty().ifEmpty { lastLoadedUrl })
        }
        return JSONObject()
            .put("allowed", true)
            .put("ok", finished && lastLoadError == null)
            .put("timedOut", !finished)
            .put("url", curUrlRef.get())
            .put("title", titleRef.get())
            .apply { lastLoadError?.let { put("error", it) } }
    }

    private fun handleEval(context: Context, script: String, timeoutMs: Long): JSONObject {
        val cleanScript = script.trim()
        if (cleanScript.isEmpty()) return err("Missing script")
        if (webView == null) return err("No active page; call navigate first")

        val wrapped = """
            (function(){
              try {
                var r = (function(){ return ($cleanScript); })();
                return JSON.stringify({ok:true, value: r === undefined ? null : r});
              } catch (e) {
                try {
                  var r2 = (function(){ $cleanScript })();
                  return JSON.stringify({ok:true, value: r2 === undefined ? null : r2});
                } catch (e2) {
                  return JSON.stringify({ok:false, error: String(e2)});
                }
              }
            })();
        """.trimIndent()

        val rawOut = evaluateRawJs(context, wrapped, timeoutMs.coerceIn(500L, 25_000L))
            ?: return err("JavaScript evaluation timed out")
        val decoded = decodeEvaluateJavascriptResult(rawOut)
        return runCatching {
            val parsed = JSONObject(decoded)
            JSONObject()
                .put("allowed", true)
                .put("ok", parsed.optBoolean("ok", false))
                .put("value", parsed.opt("value"))
                .apply { if (parsed.has("error")) put("error", parsed.optString("error")) }
        }.getOrElse {
            JSONObject().put("allowed", true).put("ok", true).put("value", decoded)
        }
    }

    private fun handleClick(context: Context, selector: String): JSONObject {
        val clean = selector.trim()
        if (clean.isEmpty()) return err("Missing selector")
        val js = """
            (function(){
              var el = document.querySelector(${JSONObject.quote(clean)});
              if (!el) return {clicked:false, error:'Element not found'};
              el.scrollIntoView({block:'center', inline:'center'});
              el.click();
              return {clicked:true, tag: el.tagName};
            })()
        """.trimIndent()
        return handleEval(context, js, DEFAULT_EVAL_TIMEOUT_MS)
    }

    private fun handleType(context: Context, selector: String, text: String): JSONObject {
        val clean = selector.trim()
        if (clean.isEmpty()) return err("Missing selector")
        val js = """
            (function(){
              var el = document.querySelector(${JSONObject.quote(clean)});
              if (!el) return {typed:false, error:'Element not found'};
              el.focus();
              if ('value' in el) {
                el.value = ${JSONObject.quote(text)};
              } else {
                el.textContent = ${JSONObject.quote(text)};
              }
              el.dispatchEvent(new Event('input', {bubbles:true}));
              el.dispatchEvent(new Event('change', {bubbles:true}));
              return {typed:true, length: ${text.length}};
            })()
        """.trimIndent()
        return handleEval(context, js, DEFAULT_EVAL_TIMEOUT_MS)
    }

    private fun handleGetText(context: Context, maxChars: Int): JSONObject {
        val limit = maxChars.coerceIn(256, 65536)
        val js = """
            (function(){
              var text = (document.body && document.body.innerText) ? document.body.innerText : '';
              return {
                url: location.href,
                title: document.title || '',
                text: text.slice(0, $limit),
                truncated: text.length > $limit
              };
            })()
        """.trimIndent()
        return handleEval(context, js, DEFAULT_EVAL_TIMEOUT_MS)
    }

    private fun handleScreenshot(context: Context, requestedPath: String): JSONObject {
        if (webView == null) return err("No active page; call navigate first")
        val shotDir = File(context.cacheDir, "browser_screenshots").apply { mkdirs() }
        val outFile = if (requestedPath.isNotBlank()) {
            val candidate = File(requestedPath)
            if (candidate.isAbsolute) candidate else File(shotDir, candidate.name)
        } else {
            File(shotDir, "browser_${System.currentTimeMillis()}.png")
        }
        outFile.parentFile?.mkdirs()

        val errRef = AtomicReference<String?>(null)
        runOnMainSync {
            try {
                val wv = webView ?: throw IllegalStateException("WebView closed")
                layoutOffscreen(wv)
                val bmp = Bitmap.createBitmap(viewportWidth, viewportHeight, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                wv.draw(canvas)
                FileOutputStream(outFile).use { fos ->
                    bmp.compress(Bitmap.CompressFormat.PNG, 95, fos)
                }
                bmp.recycle()
            } catch (t: Throwable) {
                errRef.set(t.message ?: t.toString())
            }
        }
        errRef.get()?.let { return err(it) }
        return JSONObject()
            .put("allowed", true)
            .put("ok", true)
            .put("path", outFile.absolutePath)
            .put("width", viewportWidth)
            .put("height", viewportHeight)
            .put("bytes", outFile.length())
    }

    private fun handleConsoleLogs(clear: Boolean): JSONObject {
        val arr = JSONArray()
        synchronized(consoleLock) {
            for (item in consoleBuffer) arr.put(item)
            if (clear) consoleBuffer.clear()
        }
        return JSONObject().put("allowed", true).put("ok", true).put("logs", arr)
    }

    private fun handleClose(): JSONObject {
        runOnMainSync {
            webView?.let { wv ->
                runCatching {
                    wv.stopLoading()
                    wv.loadUrl("about:blank")
                    wv.destroy()
                }
            }
            webView = null
        }
        synchronized(consoleLock) { consoleBuffer.clear() }
        return JSONObject().put("allowed", true).put("ok", true).put("closed", true)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun ensureWebViewOnMain(context: Context): WebView {
        webView?.let { return it }
        val wv = WebView(context)
        wv.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setGeolocationEnabled(false)
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                safeBrowsingEnabled = true
            }
        }
        wv.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val u = request?.url?.toString()
                return !isHttpOrHttpsUrl(u)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                lastLoadedUrl = url.orEmpty()
                if (activeNavId > 0) {
                    activeNavLatch?.countDown()
                }
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: android.webkit.WebResourceError?,
            ) {
                if (request?.isForMainFrame == true) {
                    lastLoadError = error?.description?.toString() ?: "Page load error"
                    activeNavLatch?.countDown()
                }
            }
        }
        wv.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(msg: ConsoleMessage?): Boolean {
                if (msg != null) {
                    synchronized(consoleLock) {
                        if (consoleBuffer.size >= MAX_CONSOLE_LOGS) consoleBuffer.removeFirst()
                        consoleBuffer.addLast(
                            JSONObject()
                                .put("level", msg.messageLevel().name.lowercase(Locale.ROOT))
                                .put("message", msg.message().orEmpty())
                                .put("line", msg.lineNumber())
                        )
                    }
                }
                return true
            }
        }
        webView = wv
        return wv
    }

    private fun layoutOffscreen(wv: WebView) {
        val wSpec = View.MeasureSpec.makeMeasureSpec(viewportWidth, View.MeasureSpec.EXACTLY)
        val hSpec = View.MeasureSpec.makeMeasureSpec(viewportHeight, View.MeasureSpec.EXACTLY)
        wv.measure(wSpec, hSpec)
        wv.layout(0, 0, viewportWidth, viewportHeight)
    }

    private fun evaluateRawJs(context: Context, js: String, timeoutMs: Long): String? {
        val resRef = AtomicReference<String?>(null)
        val latch = CountDownLatch(1)
        mainHandler.post {
            val wv = webView ?: ensureWebViewOnMain(context)
            wv.evaluateJavascript(js) { value ->
                resRef.set(value)
                latch.countDown()
            }
        }
        return if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) resRef.get() else null
    }

    private fun decodeEvaluateJavascriptResult(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed == "null" || trimmed.isEmpty()) return ""
        return runCatching {
            val tok = JSONTokener(trimmed).nextValue()
            tok as? String ?: trimmed
        }.getOrDefault(trimmed)
    }

    private fun runOnMainSync(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        val latch = CountDownLatch(1)
        mainHandler.post {
            try {
                block()
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
    }

    private fun isLoopbackHost(url: String): Boolean {
        val host = runCatching { Uri.parse(url).host?.lowercase(Locale.ROOT) }.getOrNull() ?: return false
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private fun err(message: String): JSONObject =
        JSONObject().put("allowed", false).put("ok", false).put("error", message)
}
