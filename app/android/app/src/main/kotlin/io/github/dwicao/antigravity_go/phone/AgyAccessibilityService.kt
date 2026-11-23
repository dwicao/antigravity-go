package io.github.dwicao.antigravity_go.phone

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class AgyAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: AgyAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Screen state is inspected on demand.
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    fun currentPackageName(): String? = rootInActiveWindow?.packageName?.toString()

    fun isFocusedInputPassword(): Boolean {
        val root = rootInActiveWindow ?: return false
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        return focused.isPassword
    }

    fun describeFocusedInput(): Pair<String, Boolean> {
        val root = rootInActiveWindow ?: return "" to false
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return "" to false
        val label = listOfNotNull(
            focused.hintText?.toString(),
            focused.contentDescription?.toString(),
            focused.text?.toString(),
            focused.viewIdResourceName,
        ).filter { it.isNotBlank() }.joinToString(" ")
        return label to focused.isPassword
    }

    fun describeNodeAt(x: Float, y: Float): Pair<String, Boolean> {
        val root = rootInActiveWindow ?: return "" to false
        val ix = x.toInt()
        val iy = y.toInt()
        var bestLabel = ""
        var bestPassword = false
        var bestArea = Long.MAX_VALUE
        var visited = 0
        fun walk(node: AccessibilityNodeInfo?) {
            if (node == null || visited >= 120) return
            visited++
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (rect.contains(ix, iy)) {
                val area = rect.width().toLong() * rect.height().toLong()
                val label = listOfNotNull(
                    node.text?.toString(),
                    node.contentDescription?.toString(),
                    node.hintText?.toString(),
                    node.viewIdResourceName,
                ).filter { it.isNotBlank() }.joinToString(" ")
                if ((label.isNotEmpty() || node.isPassword) && area <= bestArea) {
                    bestArea = area
                    if (label.isNotEmpty()) bestLabel = label
                    if (node.isPassword) bestPassword = true
                }
                for (i in 0 until node.childCount) {
                    walk(node.getChild(i))
                }
            }
        }
        walk(root)
        return bestLabel to bestPassword
    }

    fun dumpTree(maxNodes: Int = 60): String {
        val root = rootInActiveWindow ?: return "(no active window)"
        val sb = StringBuilder()
        var count = 0
        fun walk(node: AccessibilityNodeInfo?, depth: Int) {
            if (node == null || count >= maxNodes) return
            count++
            val rect = Rect()
            node.getBoundsInScreen(rect)
            val text = node.text?.toString().orEmpty()
            val desc = node.contentDescription?.toString().orEmpty()
            if (text.isNotEmpty() || desc.isNotEmpty() || node.isClickable) {
                sb.append("  ".repeat(depth.coerceAtMost(6)))
                sb.append("[${node.className?.toString()?.substringAfterLast('.') ?: "View"}]")
                if (text.isNotEmpty()) sb.append(" text=\"$text\"")
                if (desc.isNotEmpty()) sb.append(" desc=\"$desc\"")
                if (node.isClickable) sb.append(" (clickable)")
                sb.append(" @${rect.centerX()},${rect.centerY()}\n")
            }
            for (i in 0 until node.childCount) {
                walk(node.getChild(i), depth + 1)
            }
        }
        walk(root, 0)
        return sb.toString()
    }

    fun tapAt(x: Float, y: Float): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 60)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGesture(gesture, null, null)
    }

    fun inputText(text: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }
}
