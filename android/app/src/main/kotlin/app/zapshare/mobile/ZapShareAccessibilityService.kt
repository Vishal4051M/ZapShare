package app.zapshare.mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent
import android.os.Bundle
import android.view.KeyEvent
import android.accessibilityservice.AccessibilityServiceInfo

class ZapShareAccessibilityService : AccessibilityService() {

    companion object {
        var instance: ZapShareAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val info = AccessibilityServiceInfo()
        info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or 
                     AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                     AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        serviceInfo = info
        android.util.Log.d("ZapShareAccess", "Accessibility Service Connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used for input injection
    }

    override fun onInterrupt() {
        instance = null
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    fun tap(x: Float, y: Float) {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
            .build()
        dispatchGesture(gesture, null, null)
    }

    fun longPress(x: Float, y: Float) {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 800))
            .build()
        dispatchGesture(gesture, null, null)
    }

    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, duration: Long) {
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration.coerceAtLeast(100)))
            .build()
        dispatchGesture(gesture, null, null)
    }

    fun performGlobalActionCompat(action: Int): Boolean {
        return performGlobalAction(action)
    }

    fun injectText(textToAppend: String): Boolean {
        val focusedNode = findBestEditableInput() ?: return false
        
        var currentText = focusedNode.text?.toString() ?: ""
        
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            if (focusedNode.isShowingHintText) {
                currentText = ""
            }
            val hintText = focusedNode.hintText?.toString()
            if (hintText != null && currentText.trim() == hintText.trim()) {
                currentText = ""
            }
        }
        
        // Zero-cursor heuristic: if the field claims to have text but cursor is at 0, it's very likely a hint
        if (currentText.isNotEmpty() && focusedNode.textSelectionStart <= 0 && focusedNode.textSelectionEnd <= 0) {
            currentText = ""
        }

        val start = focusedNode.textSelectionStart
        val end = focusedNode.textSelectionEnd

        val newText = if (currentText.isEmpty()) {
            textToAppend
        } else if (start >= 0 && end >= 0) {
            val s = minOf(start, end)
            val e = maxOf(start, end)
            currentText.substring(0, s) + textToAppend + currentText.substring(e)
        } else {
            currentText + textToAppend
        }

        val arguments = Bundle()
        arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
        val success = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        
        // Restore cursor position forward
        if (success) {
            val selArgs = Bundle()
            val newPos = if (currentText.isEmpty()) textToAppend.length else minOf(start, end).coerceAtLeast(0) + textToAppend.length
            selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newPos)
            selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newPos)
            focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
        }
        
        focusedNode.recycle()
        return success
    }

    fun injectBackspace(): Boolean {
        val focusedNode = findBestEditableInput() ?: return false
        
        var currentText = focusedNode.text?.toString() ?: ""

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            if (focusedNode.isShowingHintText) {
                currentText = ""
            }
            val hintText = focusedNode.hintText?.toString()
            if (hintText != null && currentText.trim() == hintText.trim()) {
                currentText = ""
            }
        }
        
        // Zero-cursor heuristic
        if (currentText.isNotEmpty() && focusedNode.textSelectionStart <= 0 && focusedNode.textSelectionEnd <= 0) {
            currentText = ""
        }

        return if (currentText.isNotEmpty()) {
            val start = focusedNode.textSelectionStart
            val end = focusedNode.textSelectionEnd
            
            val newText = if (start > 0 && start == end) {
                // Delete one char before the cursor
                currentText.substring(0, start - 1) + currentText.substring(start)
            } else if (start != end && start >= 0 && end >= 0) {
                // Delete highlighted selection
                val s = minOf(start, end)
                val e = maxOf(start, end)
                currentText.substring(0, s) + currentText.substring(e)
            } else {
                // Fallback: delete last char
                currentText.substring(0, currentText.length - 1)
            }

            val arguments = Bundle()
            arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
            val success = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
            
            // Restore cursor position backwards
            if (success && start > 0 && start == end) {
                val selArgs = Bundle()
                val newPos = start - 1
                selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newPos)
                selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newPos)
                focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
            }
            
            focusedNode.recycle()
            success
        } else {
            focusedNode.recycle()
            true
        }
    }

    fun injectEnter(): Boolean {
        val focusedNode = findBestEditableInput() ?: return false
        // Try to trigger the action associated with the node (often works like Enter)
        val success = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)
        focusedNode.recycle()
        return success
    }

    private fun findBestEditableInput(): android.view.accessibility.AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        
        // 1. Try formal focus
        val focus = root.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT)
        if (focus != null && focus.isEditable) return focus
        
        // 2. Manual search for any active focused editable node
        val backupFocus = searchFocusedEditableNode(root)
        if (backupFocus != null) return backupFocus
        
        // 3. Fallback: find the first visible editable node on screen (fixes App Drawer search box)
        return findAnyEditableNode(root)
    }

    private fun searchFocusedEditableNode(node: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = searchFocusedEditableNode(child)
            if (result != null) return result
        }
        return null
    }

    private fun findAnyEditableNode(node: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
        if (node.isEditable && node.isVisibleToUser) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = findAnyEditableNode(child)
            if (result != null) return result
        }
        return null
    }
}
