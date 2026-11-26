package io.github.dwicao.antigravity_go.phone

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Safely reads clipboard image URIs (max 12 MiB, refusing private file:// URIs)
 * and materializes them into `cacheDir/pasted_images/` for chat attachments.
 * Adopted from antigravity-android PR #37 (`ClipboardImageReader`).
 */
object ClipboardImageHelper {
    const val MAX_IMAGE_BYTES = 12 * 1024 * 1024 // 12 MiB
    private val mainHandler = Handler(Looper.getMainLooper())

    data class ClipboardImageRef(val uri: Uri, val mime: String)

    fun findPrimaryClipboardImage(context: Context): ClipboardImageRef? {
        val appCtx = context.applicationContext
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return inspectOnMain(appCtx)
        }
        val ref = AtomicReference<ClipboardImageRef?>(null)
        val latch = CountDownLatch(1)
        mainHandler.post {
            try {
                ref.set(inspectOnMain(appCtx))
            } catch (_: Throwable) {
            } finally {
                latch.countDown()
            }
        }
        latch.await(1500, TimeUnit.MILLISECONDS)
        return ref.get()
    }

    fun hasClipboardImage(context: Context): Boolean = findPrimaryClipboardImage(context) != null

    fun readClipboardImageToTempFile(context: Context): Map<String, Any?> {
        val appCtx = context.applicationContext
        val ref = findPrimaryClipboardImage(appCtx)
            ?: return mapOf("ok" to false, "error" to "no_clipboard_image")
        return copyImageUriToTempFile(appCtx, ref.uri, ref.mime)
    }

    fun copyImageUriToTempFile(
        context: Context,
        uri: Uri,
        hintMime: String? = null,
    ): Map<String, Any?> {
        val appCtx = context.applicationContext
        val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
        if (scheme == "file") {
            return mapOf("ok" to false, "error" to "blocked_file_uri")
        }
        if (scheme != "content") {
            return mapOf("ok" to false, "error" to "unsupported_uri_scheme")
        }

        val resolver = appCtx.contentResolver
        val rawMime = resolver.getType(uri)?.lowercase(Locale.ROOT)?.takeIf { it.startsWith("image/") }
            ?: hintMime?.lowercase(Locale.ROOT)?.takeIf { it.startsWith("image/") }
            ?: "image/png"

        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(rawMime)
            ?.takeIf { it.isNotBlank() }
            ?: when {
                rawMime.contains("jpeg") || rawMime.contains("jpg") -> "jpg"
                rawMime.contains("webp") -> "webp"
                rawMime.contains("gif") -> "gif"
                else -> "png"
            }

        val displayName = resolveDisplayName(appCtx, uri)
            ?: "pasted_${System.currentTimeMillis()}.$ext"
        val safeName = displayName.replace(Regex("""[^a-zA-Z0-9._-]"""), "_")
        val finalName = if (safeName.contains('.')) safeName else "$safeName.$ext"

        val outDir = File(appCtx.cacheDir, "pasted_images").apply { mkdirs() }
        pruneOldFiles(outDir)
        val outFile = File(outDir, "${System.currentTimeMillis()}_$finalName")

        return runCatching {
            var total = 0L
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    val buf = ByteArray(16 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_IMAGE_BYTES) {
                            outFile.delete()
                            return mapOf("ok" to false, "error" to "image_too_large")
                        }
                        output.write(buf, 0, n)
                    }
                }
            } ?: return mapOf("ok" to false, "error" to "open_stream_failed")

            if (total <= 0L) {
                outFile.delete()
                return mapOf("ok" to false, "error" to "empty_image")
            }

            mapOf(
                "ok" to true,
                "path" to outFile.absolutePath,
                "name" to finalName,
                "mime" to rawMime,
                "sizeBytes" to total,
            )
        }.getOrElse { e ->
            outFile.delete()
            mapOf("ok" to false, "error" to (e.message ?: "clipboard_read_failed"))
        }
    }

    private fun inspectOnMain(context: Context): ClipboardImageRef? {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount <= 0) return null
        val desc = clip.description
        val resolver = context.contentResolver

        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
            if (scheme != "content") continue
            val resolvedMime = resolver.getType(uri)?.lowercase(Locale.ROOT)
            if (resolvedMime != null && resolvedMime.startsWith("image/")) {
                return ClipboardImageRef(uri, resolvedMime)
            }
            if (desc != null && desc.hasMimeType("image/*")) {
                val explicit = (0 until desc.mimeTypeCount)
                    .map { desc.getMimeType(it).lowercase(Locale.ROOT) }
                    .firstOrNull { it.startsWith("image/") && it != ClipDescription.MIMETYPE_TEXT_PLAIN }
                    ?: "image/png"
                return ClipboardImageRef(uri, explicit)
            }
        }
        return null
    }

    private fun resolveDisplayName(context: Context, uri: Uri): String? {
        return runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        }.getOrNull()
    }

    private fun pruneOldFiles(dir: File) {
        val files = dir.listFiles() ?: return
        if (files.size <= 24) return
        files.sortedBy { it.lastModified() }.take(files.size - 24).forEach { runCatching { it.delete() } }
    }
}
