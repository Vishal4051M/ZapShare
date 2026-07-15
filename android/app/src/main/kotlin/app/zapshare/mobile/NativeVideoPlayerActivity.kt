package app.zapshare.mobile

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.app.Activity
import android.app.UiModeManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.*
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.util.TypedValue
import android.view.*
import android.widget.*
import androidx.media3.common.*
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.text.CueGroup
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import kotlin.math.abs

/**
 * Full-screen native video player Activity using SurfaceView + ExoPlayer.
 * Netflix/VLC-style overlay UI with touch gestures, cast control, and D-pad support.
 */
@UnstableApi
class NativeVideoPlayerActivity : Activity() {

    // ── Views ────────────────────────────────────────────────────────────────
    private lateinit var rootLayout: FrameLayout
    private lateinit var videoFrame: AspectRatioFrameLayout
    private lateinit var surfaceView: SurfaceView

    // Top bar
    private lateinit var topBar: LinearLayout
    private lateinit var titleView: TextView
    private lateinit var backButton: ImageView
    private lateinit var settingsBtn: ImageView

    // Center controls
    private lateinit var centerRow: LinearLayout
    private lateinit var rewindBtn: ImageView
    private lateinit var playPauseBtn: ImageView
    private lateinit var forwardBtn: ImageView

    // Bottom bar
    private lateinit var bottomBar: LinearLayout
    private lateinit var seekBar: SeekBar
    private lateinit var positionText: TextView
    private lateinit var durationText: TextView
    private lateinit var speedBtn: TextView
    private lateinit var audioBtn: ImageView
    private lateinit var subtitleBtn: ImageView
    private lateinit var lockBtn: ImageView
    private lateinit var fitBtn: ImageView

    // Subtitle rendering
    private lateinit var subtitleView: SubtitleView

    // Overlays
    private lateinit var loadingSpinner: ProgressBar
    private lateinit var actionIndicator: LinearLayout
    private lateinit var actionIcon: ImageView
    private lateinit var actionLabel: TextView
    private lateinit var volumeOverlay: LinearLayout
    private lateinit var volumeBar: ProgressBar
    private lateinit var volumeText: TextView
    private lateinit var brightnessOverlay: LinearLayout
    private lateinit var brightnessBar: ProgressBar
    private lateinit var brightnessText: TextView
    private lateinit var doubleTapOverlay: FrameLayout
    private lateinit var doubleTapLabel: TextView
    private lateinit var menuOverlay: FrameLayout
    private lateinit var lockUnlockBtn: ImageView
    private lateinit var speedMenu: LinearLayout

    // Gradients
    private lateinit var topGradient: View
    private lateinit var bottomGradient: View

    // ── Player ───────────────────────────────────────────────────────────────
    private var player: ExoPlayer? = null
    private var trackSelector: DefaultTrackSelector? = null

    // ── State ────────────────────────────────────────────────────────────────
    private var controlsVisible = true
    private var isPlaying = false
    private var duration = 0L
    private var position = 0L
    private var isSurfaceReady = false
    private var pendingPlay = false
    private var isLocked = false
    private var currentSpeed = 1.0f
    private var currentVolume = 1.0f
    private var currentBrightness = 0.5f
    private var videoAspectRatio = 16f / 9f
    private var exitOverlay: FrameLayout? = null
    private val isExitShowing get() = exitOverlay?.visibility == View.VISIBLE

    // ── Subtitle style ───────────────────────────────────────────────────────
    private val subtitleColors = intArrayOf(Color.WHITE, 0xFFFFD600.toInt(), 0xFF00E5FF.toInt(), 0xFFB9FF66.toInt())
    private val subtitleBgColors = intArrayOf(Color.TRANSPARENT, 0xB3000000.toInt(), 0xCC000000.toInt())
    private val subtitleSizeScale = floatArrayOf(0.85f, 1.0f, 1.15f, 1.35f)
    private val subtitleBottomPads = floatArrayOf(0.05f, 0.12f, 0.18f, 0.24f)
    private var subtitleColorIndex = 0
    private var subtitleBgIndex = 0
    private var subtitleSizeIndex = 1
    private var subtitlePosIndex = 1
    private var subtitleTrackCount = 0
    private var subtitleTrackIndex = 0  // 0 = Off, otherwise 1-based index into subtitleTrackLabels
    private var subtitleTrackOptions: List<String> = emptyList()

    // ── Aspect ratio ─────────────────────────────────────────────────────────
    private var currentFitIndex = 0
    private val fitModes = arrayOf("Fit", "Fill", "Stretch", "16:9", "4:3")

    // ── Menu ─────────────────────────────────────────────────────────────────
    private var menuVisible = false
    private var currentMenuType = MENU_NONE
    private var menuSelectedIndex = 0
    private var menuItems = listOf<String>()
    private lateinit var menuListView: ListView
    private lateinit var menuCard: LinearLayout
    private lateinit var menuTitle: TextView
    private lateinit var menuAdapter: NativeMenuAdapter
    private val menuPanelWidth get() = dp(if (isTvDevice) 320 else 280)
    private val speedOptions = floatArrayOf(0.25f, 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f)
    private var speedMenuSelectedIndex = 3

    private var subtitleTrackLabels: List<String> = emptyList()

    // ── TV detection ─────────────────────────────────────────────────────────
    private var isTvDevice = false

    // ── Audio output device ──────────────────────────────────────────────────
    private var audioOutputLabels: List<String> = emptyList()
    private var audioOutputDevices: List<AudioDeviceInfo?> = emptyList()  // null = default
    private var selectedAudioOutputIndex = 0
    private var isCastSourceAudio = false
    // Tracks the intended audio track index while audio is disabled (cast source mode).
    // isTrackSelected() returns false for all tracks when audio is disabled, so we
    // can't detect the active track from currentTracks — we track it ourselves here.
    private var castAudioTrackIndex: Int = 0
    // AudioFocusRequest reference for API 26+ so we can explicitly abandon it
    private var audioFocusRequest: android.media.AudioFocusRequest? = null

    // ── D-pad seek state (VLC-style hold-to-seek) ────────────────────────────
    private var isSeeking = false
    private var isDraggingSeekBar = false
    private var isQuietSeeking = false
    private var seekAccumulated = 0L
    private var seekTargetPosition = 0L
    private val seekResetRunnable = Runnable { finishSeekBurst() }

    // ── Cast / Remote Control (via MethodChannel relay) ─────────────────────
    private var castControllerIp: String? = null
    private var isCastActive = false

    // ── Gesture state ────────────────────────────────────────────────────────
    private var isVerticalDragging = false
    private var swipeSide = -1
    private var swipeStartY = 0f
    private var swipeStartValue = 0f
    private var lastTapTime = 0L
    private var lastTapX = 0f
    private var tapCount = 0

    // ── Back callback for API 33+ ─────────────────────────────────────────────
    private var backCallback: Any? = null  // OnBackInvokedCallback (stored as Any for API compat)

    // ── Handlers ─────────────────────────────────────────────────────────────
    private val mainHandler = Handler(Looper.getMainLooper())
    private val hideControlsRunnable = Runnable { hideControls() }
    private val positionRunnable = object : Runnable {
        override fun run() {
            updateProgress()
            mainHandler.postDelayed(this, if (isTvDevice) 500L else 250L)
        }
    }

    companion object {
        const val EXTRA_SOURCE = "source"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE_PATH = "subtitlePath"
        const val EXTRA_START_POSITION = "position"
        const val EXTRA_CAST_CONTROLLER_IP = "castControllerIp"
        const val EXTRA_DEVICE_ID = "deviceId"
        const val RESULT_POSITION = "position"

        private const val MENU_NONE = 0
        private const val MENU_MAIN = 1
        private const val MENU_AUDIO = 2
        private const val MENU_SUBTITLE = 3
        private const val MENU_AUDIO_DEVICE = 4

        private const val ACCENT = 0xFFFFD600.toInt()
        private const val ACCENT_DIM = 0x26FFD600  // 0.15 opacity accent (matching Flutter)
        private const val ACCENT_BORDER = 0x66FFD600  // 0.4 opacity accent border
        private const val BG_DARK = 0xFF0A0D12.toInt()   // deep charcoal for posh feel
        private const val CARD_BG = 0xF015171C.toInt()   // richer card tone
        private const val PILL_BG = 0x33202830.toInt()   // translucent slate pills
        private const val PILL_BORDER = 0x26FFFFFF       // subtle border
        private const val CIRCLE_BG = 0x26202830         // matches pill hue
        private const val CIRCLE_BORDER = 0x40FFFFFF     // brighter ring

        // ── Static cast relay ────────────────────────────────────────────
        // MethodChannel reference set by MainActivity at startup
        @JvmStatic var castRelay: io.flutter.plugin.common.MethodChannel? = null
        // Active instance for forwarding commands from Flutter
        @JvmStatic var activeInstance: NativeVideoPlayerActivity? = null

        /** Called from MainActivity MethodChannel handler when Dart sends a cast command */
        @JvmStatic
        fun handleCastCommandFromDart(action: String, seekPosition: Double?, volume: Double?, trackIndex: Int? = null, propertyValue: Any? = null): Boolean {
            val instance = activeInstance ?: return false
            Handler(Looper.getMainLooper()).post {
                try {
                    when (action) {
                        "play" -> instance.player?.play()
                        "pause" -> instance.player?.pause()
                        "seek" -> seekPosition?.let { if (it >= 0) instance.player?.seekTo((it * 1000).toLong()) }
                        "volume" -> volume?.let { instance.currentVolume = it.toFloat().coerceIn(0f, 1f); instance.player?.volume = instance.currentVolume }
                        "stop" -> instance.finishWithPosition()
                        "ping" -> { /* status is sent by Dart-side timer via getStatus */ }
                        "setAudioTrack" -> trackIndex?.let { instance.selectAudioTrack(it) }
                        "setSubtitleTrack" -> trackIndex?.let { if (it < 0) instance.disableSubtitles() else instance.selectSubtitleTrack(it) }
                        "setAudioOutput" -> {
                            val output = propertyValue as? String
                            if (output != null) {
                                instance.selectAudioOutputDeviceByName(output)
                            }
                        }
                    }
                    // Push immediately so the controller mirrors play/pause/seek/track changes without waiting for the poll timer.
                    instance.pushCastStatusToFlutter()
                } catch (e: Exception) {
                    android.util.Log.w("NativeVideoPlayer", "Cast relay error", e)
                }
            }
            return true
        }

        /** Called from MainActivity MethodChannel handler when Dart requests current status */
        @JvmStatic
        fun getStatusForDart(): Map<String, Any?> {
            val instance = activeInstance ?: return mapOf("active" to false)
            val p = instance.player
            val audioLabels = if (p != null) instance.getAudioTrackLabels(p) else emptyList()
            val subtitleLabels = if (p != null) instance.getSubtitleTrackLabels(p) else emptyList()

            // Find active track indices
            var activeAudioIdx: Int? = null
            var activeSubIdx: Int? = null
            if (p != null) {
                var aIdx = 0
                for (group in p.currentTracks.groups) {
                    if (group.type == C.TRACK_TYPE_AUDIO) {
                        for (i in 0 until group.length) {
                            if (group.isTrackSelected(i)) activeAudioIdx = aIdx
                            aIdx++
                        }
                    }
                }
                var sIdx = 0
                for (group in p.currentTracks.groups) {
                    if (group.type == C.TRACK_TYPE_TEXT) {
                        for (i in 0 until group.length) {
                            if (group.isTrackSelected(i)) activeSubIdx = sIdx
                            sIdx++
                        }
                    }
                }
            }

            // Find active track names for precise matching on the phone
            var activeAudioTrackLabel: String? = null
            if (p != null) {
                var aIdx = 0
                for (group in p.currentTracks.groups) {
                    if (group.type == C.TRACK_TYPE_AUDIO) {
                        for (i in 0 until group.length) {
                             if (instance.isCastSourceAudio) {
                                 if (aIdx == instance.castAudioTrackIndex) {
                                     val fmt = group.getTrackFormat(i)
                                     activeAudioTrackLabel = fmt.label ?: fmt.language
                                 }
                             } else if (group.isTrackSelected(i)) {
                                 val fmt = group.getTrackFormat(i)
                                 activeAudioTrackLabel = fmt.label ?: fmt.language
                             }
                             aIdx++
                        }
                    }
                }
            }

            return mapOf(
                "active" to true,
                "position" to instance.position / 1000.0,
                "duration" to instance.duration / 1000.0,
                "buffered" to (p?.bufferedPosition ?: 0L) / 1000.0,
                "isPlaying" to instance.isPlaying,
                "isBuffering" to (p?.playbackState == Player.STATE_BUFFERING),
                "volume" to instance.currentVolume.toDouble(),
                "fileName" to (instance.intent.getStringExtra(EXTRA_TITLE) ?: ""),
                // Stream specific tracks
                "audioTracks" to audioLabels.map { it.replace(" ✓", "") },
                "subtitleTracks" to subtitleLabels.map { it.replace(" ✓", "") },
                "activeAudioTrack" to if (instance.isCastSourceAudio) instance.castAudioTrackIndex else activeAudioIdx,
                "activeAudioTrackLabel" to activeAudioTrackLabel,
                "activeSubtitleTrack" to activeSubIdx,
                "audioOutput" to if (instance.isCastSourceAudio) "castSource" else "default"
            )
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            detectTvDevice()
            buildUI()
            makeFullScreen()
            initPlayer()
            initCast()
            scheduleHideControls()
            requestInitialFocus()
            registerBackCallback()
        } catch (e: Exception) {
            android.util.Log.e("NativeVideoPlayer", "onCreate crashed", e)
            showFatalError("Player failed to start: ${e.message}")
        }
    }

    private fun registerBackCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val callback = OnBackInvokedCallback { handleBackPress() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback
            )
            backCallback = callback
        }
    }

    private fun detectTvDevice() {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        isTvDevice = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }

    override fun onResume() {
        super.onResume()
        makeFullScreen()
        try { player?.let { if (it.playbackState == Player.STATE_READY) it.play() } } catch (_: Exception) {}
    }

    override fun onPause() {
        super.onPause()
        try { player?.pause() } catch (_: Exception) {}
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && backCallback != null) {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(backCallback as OnBackInvokedCallback)
            backCallback = null
        }
        mainHandler.removeCallbacksAndMessages(null)
        stopCast()
        try { player?.release() } catch (_: Exception) {}
        player = null
        super.onDestroy()
    }

    override fun onBackPressed() {
        // Dismiss exit overlay first if showing
        if (isExitShowing) { dismissExitOverlay(); return }
        if (handleBackPress()) return else super.onBackPressed()
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Full-screen setup
    // ═════════════════════════════════════════════════════════════════════════

    private fun makeFullScreen() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
        }
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
    }

    private fun requestInitialFocus() {
        rootLayout.isFocusable = true
        rootLayout.isFocusableInTouchMode = true
        if (isTvDevice) {
            playPauseBtn.post { playPauseBtn.requestFocus() }
        } else {
            rootLayout.requestFocus()
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()
    private fun dpf(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics)

    private fun roundedBg(color: Int, radiusDp: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = dpf(radiusDp)
    }

    private fun applyFocusHighlight(
        target: View,
        normalBg: () -> Drawable,
        focusedBg: () -> Drawable,
        onFocus: (() -> Unit)? = null,
        onBlur: (() -> Unit)? = null
    ) {
        target.onFocusChangeListener = View.OnFocusChangeListener { v, hasFocus ->
            v.background = if (hasFocus) focusedBg() else normalBg()
            // Use elevation glow instead of scale — scale causes clipping on TV
            v.animate().cancel()
            v.animate()
                .scaleX(1.0f).scaleY(1.0f)  // never scale: avoids container clipping
                .setDuration(120).start()
            if (hasFocus) {
                v.elevation = dpf(18)
                onFocus?.invoke()
            } else {
                v.elevation = dpf(4)
                onBlur?.invoke()
            }
        }
    }

    private fun circleBg(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL; setColor(color)
    }

    /** Pill button background matching Flutter _buildPillButton: dark fill + subtle border */
    private fun pillBg(active: Boolean = false) = GradientDrawable().apply {
        setColor(if (active) 0x40FFD600 else PILL_BG)
        cornerRadius = dpf(10)
        setStroke(if (active) dp(2) else dp(1), if (active) ACCENT else PILL_BORDER)
    }

    /** Circle button background matching Flutter _buildCircleButton: dark fill + subtle border */
    private fun circleBtnBg(filled: Boolean = false) = if (filled) {
        GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(ACCENT) }
    } else {
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL; setColor(CIRCLE_BG)
            setStroke((dpf(1) * 1.5f).toInt(), CIRCLE_BORDER)
        }
    }

    private fun youtubeSeekDrawable(): Drawable {
        // Thicker, higher-contrast track/buffer/progress for visibility on TV and dark backgrounds
        val radius = dpf(4)
        val track = GradientDrawable().apply { shape = GradientDrawable.RECTANGLE; setColor(0x80FFFFFF.toInt()); cornerRadius = radius }
        val buffer = GradientDrawable().apply { shape = GradientDrawable.RECTANGLE; setColor(0x669CA3B2); cornerRadius = radius }
        val progress = GradientDrawable().apply { shape = GradientDrawable.RECTANGLE; setColor(ACCENT); cornerRadius = radius }
        val bufferClip = ClipDrawable(buffer, Gravity.START, ClipDrawable.HORIZONTAL)
        val progressClip = ClipDrawable(progress, Gravity.START, ClipDrawable.HORIZONTAL)
        return LayerDrawable(arrayOf(track, bufferClip, progressClip)).apply {
            setId(0, android.R.id.background)
            setId(1, android.R.id.secondaryProgress)
            setId(2, android.R.id.progress)
            val insetV = dp(6)
            setLayerInset(0, 0, insetV, 0, insetV)
            setLayerInset(1, 0, insetV, 0, insetV)
            setLayerInset(2, 0, insetV, 0, insetV)
        }
    }

    private fun youtubeSeekThumb(): Drawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL; setColor(ACCENT)
        setSize(dp(14), dp(14))
        setStroke(dp(2), 0xCCFFFFFF.toInt())
    }

    // ── Custom vector icon drawables (sharp, no blur) ────────────────────────

    /** Creates a play triangle icon drawable */
    private fun playIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL; isDither = true }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat(); val cx = w * 0.48f; val cy = h * 0.5f
                val halfH = h * 0.3f; val halfBase = w * 0.18f
                val path = Path().apply {
                    moveTo(cx - halfBase, cy - halfH)
                    lineTo(cx - halfBase, cy + halfH)
                    lineTo(cx + halfBase * 1.6f, cy)
                    close()
                }
                canvas.drawPath(path, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a pause icon drawable (two bars) */
    private fun pauseIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL; isDither = true }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                val barW = w * 0.16f; val gap = w * 0.12f; val top = h * 0.22f; val bot = h * 0.78f
                canvas.drawRoundRect(w * 0.5f - gap - barW, top, w * 0.5f - gap, bot, barW * 0.4f, barW * 0.4f, paint)
                canvas.drawRoundRect(w * 0.5f + gap, top, w * 0.5f + gap + barW, bot, barW * 0.4f, barW * 0.4f, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a rewind icon (double left-pointing chevrons, centered) */
    private fun rewindIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL; isDither = true }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat(); val cy = h * 0.5f
                val arrowH = h * 0.28f; val arrowW = w * 0.22f; val spacing = w * 0.06f
                val totalW = 2 * arrowW + spacing
                val left = (w - totalW) / 2
                // First left-pointing arrow
                val path1 = Path().apply {
                    moveTo(left, cy)
                    lineTo(left + arrowW, cy - arrowH)
                    lineTo(left + arrowW, cy + arrowH)
                    close()
                }
                canvas.drawPath(path1, paint)
                // Second left-pointing arrow
                val path2 = Path().apply {
                    moveTo(left + arrowW + spacing, cy)
                    lineTo(left + 2 * arrowW + spacing, cy - arrowH)
                    lineTo(left + 2 * arrowW + spacing, cy + arrowH)
                    close()
                }
                canvas.drawPath(path2, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a forward icon (double right-pointing chevrons, centered) */
    private fun forwardIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL; isDither = true }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat(); val cy = h * 0.5f
                val arrowH = h * 0.28f; val arrowW = w * 0.22f; val spacing = w * 0.06f
                val totalW = 2 * arrowW + spacing
                val left = (w - totalW) / 2
                // First right-pointing arrow
                val path1 = Path().apply {
                    moveTo(left, cy - arrowH)
                    lineTo(left, cy + arrowH)
                    lineTo(left + arrowW, cy)
                    close()
                }
                canvas.drawPath(path1, paint)
                // Second right-pointing arrow
                val path2 = Path().apply {
                    moveTo(left + arrowW + spacing, cy - arrowH)
                    lineTo(left + arrowW + spacing, cy + arrowH)
                    lineTo(left + 2 * arrowW + spacing, cy)
                    close()
                }
                canvas.drawPath(path2, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a back arrow icon (chevron left) */
    private fun backArrowIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.1f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
            }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                val path = Path().apply { moveTo(w * 0.6f, h * 0.25f); lineTo(w * 0.35f, h * 0.5f); lineTo(w * 0.6f, h * 0.75f) }
                canvas.drawPath(path, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a settings/gear icon */
    private fun settingsIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.06f }
            private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }
            override fun draw(canvas: Canvas) {
                val b = bounds; val cx = b.centerX().toFloat(); val cy = b.centerY().toFloat()
                val r = b.width() * 0.23f; val or = b.width() * 0.38f
                canvas.drawCircle(cx, cy, r, paint)
                // Draw 6 gear teeth as small rects around the circle
                for (i in 0 until 6) {
                    val angle = Math.toRadians(i * 60.0)
                    val tx = cx + (or * Math.cos(angle)).toFloat()
                    val ty = cy + (or * Math.sin(angle)).toFloat()
                    canvas.drawCircle(tx, ty, b.width() * 0.06f, fillPaint)
                }
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a; fillPaint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf; fillPaint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a subtitle/CC icon */
    private fun subtitleIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.06f }
            private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = color; textAlign = Paint.Align.CENTER; textSize = sz * 0.3f
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                val rect = RectF(w * 0.12f, h * 0.25f, w * 0.88f, h * 0.75f)
                canvas.drawRoundRect(rect, w * 0.06f, w * 0.06f, borderPaint)
                canvas.drawText("CC", w * 0.5f, h * 0.58f, textPaint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { borderPaint.alpha = a; textPaint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { borderPaint.colorFilter = cf; textPaint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates an audio/speaker icon */
    private fun audioIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }
            private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.06f }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                // Speaker cone
                val path = Path().apply {
                    moveTo(w * 0.2f, h * 0.38f); lineTo(w * 0.35f, h * 0.38f); lineTo(w * 0.5f, h * 0.22f)
                    lineTo(w * 0.5f, h * 0.78f); lineTo(w * 0.35f, h * 0.62f); lineTo(w * 0.2f, h * 0.62f); close()
                }
                canvas.drawPath(path, paint)
                // Sound arcs
                canvas.drawArc(RectF(w * 0.52f, h * 0.3f, w * 0.72f, h * 0.7f), -40f, 80f, false, arcPaint)
                canvas.drawArc(RectF(w * 0.58f, h * 0.2f, w * 0.82f, h * 0.8f), -40f, 80f, false, arcPaint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a; arcPaint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf; arcPaint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates a lock icon */
    private fun lockIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.07f }
            private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                // Lock body
                canvas.drawRoundRect(RectF(w * 0.25f, h * 0.45f, w * 0.75f, h * 0.8f), w * 0.06f, w * 0.06f, fillPaint)
                // Lock shackle
                canvas.drawArc(RectF(w * 0.3f, h * 0.2f, w * 0.7f, h * 0.55f), 180f, 180f, false, paint)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a; fillPaint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf; fillPaint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    /** Creates an aspect ratio icon */
    private fun aspectRatioIcon(color: Int, sizeDp: Int): Drawable {
        val sz = dp(sizeDp)
        return object : Drawable() {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = sz * 0.06f }
            override fun draw(canvas: Canvas) {
                val b = bounds; val w = b.width().toFloat(); val h = b.height().toFloat()
                canvas.drawRoundRect(RectF(w * 0.15f, h * 0.25f, w * 0.85f, h * 0.75f), w * 0.04f, w * 0.04f, paint)
                // Corner arrows
                val ap = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = paint.color; style = Paint.Style.FILL }
                val s = w * 0.1f
                // Top-left corner arrow
                canvas.drawRect(w * 0.15f, h * 0.25f, w * 0.15f + s, h * 0.25f + w * 0.06f, ap)
                canvas.drawRect(w * 0.15f, h * 0.25f, w * 0.15f + w * 0.06f, h * 0.25f + s, ap)
                // Bottom-right corner arrow
                canvas.drawRect(w * 0.85f - s, h * 0.75f - w * 0.06f, w * 0.85f, h * 0.75f, ap)
                canvas.drawRect(w * 0.85f - w * 0.06f, h * 0.75f - s, w * 0.85f, h * 0.75f, ap)
            }
            override fun getIntrinsicWidth() = sz
            override fun getIntrinsicHeight() = sz
            override fun setAlpha(a: Int) { paint.alpha = a }
            override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
            override fun getOpacity() = PixelFormat.TRANSLUCENT
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // UI Construction
    // ═════════════════════════════════════════════════════════════════════════

    private fun buildUI() {
        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            isFocusable = true
            isFocusableInTouchMode = true
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            clipChildren = false
            clipToPadding = false
        }
        setContentView(rootLayout)

        buildSurfaceView()
        buildSubtitleView()
        buildLoadingSpinner()
        buildTopGradient()
        buildBottomGradient()
        buildTopBar()
        buildCenterControls()
        buildBottomBar()
        buildActionIndicator()
        buildVolumeOverlay()
        buildBrightnessOverlay()
        buildDoubleTapOverlay()
        buildMenuOverlay()
        buildLockButton()
        buildSpeedMenu()
        buildTouchLayer()
        setupFocusGraph()
    }

    private fun setupFocusGraph() {
        // Center cluster
        rewindBtn.nextFocusRightId = playPauseBtn.id
        rewindBtn.nextFocusUpId = backButton.id
        rewindBtn.nextFocusDownId = seekBar.id
        playPauseBtn.nextFocusLeftId = rewindBtn.id
        playPauseBtn.nextFocusRightId = forwardBtn.id
        playPauseBtn.nextFocusUpId = subtitleBtn.id
        playPauseBtn.nextFocusDownId = seekBar.id
        forwardBtn.nextFocusLeftId = playPauseBtn.id
        forwardBtn.nextFocusUpId = fitBtn.id
        forwardBtn.nextFocusDownId = seekBar.id

        // Seek row links
        seekBar.nextFocusUpId = playPauseBtn.id
        seekBar.nextFocusDownId = speedBtn.id

        // Bottom pills - horizontal row
        audioBtn.nextFocusUpId = seekBar.id
        audioBtn.nextFocusRightId = speedBtn.id
        audioBtn.nextFocusLeftId = audioBtn.id
        audioBtn.nextFocusDownId = audioBtn.id
        speedBtn.nextFocusLeftId = audioBtn.id
        speedBtn.nextFocusUpId = seekBar.id
        speedBtn.nextFocusRightId = lockBtn.id
        speedBtn.nextFocusDownId = speedBtn.id
        lockBtn.nextFocusLeftId = speedBtn.id
        lockBtn.nextFocusUpId = seekBar.id
        lockBtn.nextFocusRightId = lockBtn.id
        lockBtn.nextFocusDownId = lockBtn.id

        // Top bar
        backButton.nextFocusRightId = subtitleBtn.id
        backButton.nextFocusDownId = playPauseBtn.id
        subtitleBtn.nextFocusLeftId = backButton.id
        subtitleBtn.nextFocusRightId = fitBtn.id
        subtitleBtn.nextFocusDownId = playPauseBtn.id
        fitBtn.nextFocusLeftId = subtitleBtn.id
        fitBtn.nextFocusRightId = settingsBtn.id
        fitBtn.nextFocusDownId = playPauseBtn.id
        settingsBtn.nextFocusLeftId = fitBtn.id
        settingsBtn.nextFocusDownId = playPauseBtn.id
    }

    private fun buildSurfaceView() {
        videoFrame = AspectRatioFrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER
            )
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        }
        surfaceView = SurfaceView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER
            )
            keepScreenOn = true
        }
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                isSurfaceReady = true
                player?.setVideoSurfaceHolder(holder)
                if (pendingPlay) { pendingPlay = false; player?.play() }
            }
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                isSurfaceReady = false; player?.clearVideoSurface()
            }
        })
        videoFrame.addView(surfaceView)
        rootLayout.addView(videoFrame)
    }

    private fun buildSubtitleView() {
        subtitleView = SubtitleView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            setUserDefaultStyle()
            setUserDefaultTextSize()
            // Ignore embedded styling so user-selected colors/backgrounds always apply
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
            setStyle(CaptionStyleCompat(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, null))
        }
        applySubtitleStyle()
        rootLayout.addView(subtitleView)
    }

    private fun buildLoadingSpinner() {
        loadingSpinner = ProgressBar(this).apply {
            layoutParams = FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER)
            indeterminateTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            visibility = View.VISIBLE
        }
        rootLayout.addView(loadingSpinner)
    }

    private fun buildTopGradient() {
        topGradient = View(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, dp(120), Gravity.TOP
            )
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0xE6000000.toInt(), 0x00000000))
        }
        rootLayout.addView(topGradient)
    }

    private fun buildBottomGradient() {
        bottomGradient = View(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, dp(200), Gravity.BOTTOM
            )
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP, intArrayOf(0xE6000000.toInt(), 0x00000000))
        }
        rootLayout.addView(bottomGradient)
    }

    // ── Top Bar ──────────────────────────────────────────────────────────────

    private fun buildTopBar() {
        topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            clipChildren = false
            clipToPadding = false
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP
            ).also { it.setMargins(dp(8), dp(8), dp(8), 0) }
        }

        // Back button - pill style matching Flutter
        backButton = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(backArrowIcon(Color.WHITE, 22))
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(40))
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = pillBg()
            setOnClickListener { showExitConfirmDialog() }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(backButton, { pillBg() }, {
            GradientDrawable().apply { setColor(0x40FFD600); cornerRadius = dpf(10); setStroke(dp(2), ACCENT) }
        })
        topBar.addView(backButton)

        topBar.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(dp(8), 0) })

        // Title - matching Flutter's GoogleFonts.outfit w600
        titleView = TextView(this).apply {
            text = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotEmpty() } ?: "Video"
            setTextColor(Color.WHITE)
            textSize = 16f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        topBar.addView(titleView)

        // Subtitle pill button - matching Flutter's top bar
        subtitleBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(subtitleIcon(0xB3FFFFFF.toInt(), 20))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38)).also { it.setMargins(dp(8), 0, 0, 0) }
            setPadding(dp(9), dp(9), dp(9), dp(9))
            background = pillBg()
            setOnClickListener { openSubtitleMenu() }
            setOnLongClickListener {
                cycleSubtitleTrack(); true
            }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(subtitleBtn, { pillBg() }, {
            GradientDrawable().apply { setColor(0x40FFD600); cornerRadius = dpf(10); setStroke(dp(2), ACCENT) }
        })
        topBar.addView(subtitleBtn)

        // Aspect ratio pill button
        fitBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(aspectRatioIcon(0xB3FFFFFF.toInt(), 20))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38)).also { it.setMargins(dp(8), 0, 0, 0) }
            setPadding(dp(9), dp(9), dp(9), dp(9))
            background = pillBg()
            setOnClickListener { cycleAspectRatio() }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(fitBtn, { pillBg() }, {
            GradientDrawable().apply { setColor(0x40FFD600); cornerRadius = dpf(10); setStroke(dp(2), ACCENT) }
        })
        topBar.addView(fitBtn)

        // Settings pill button (opens main menu for audio/speed etc.)
        settingsBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(settingsIcon(0xB3FFFFFF.toInt(), 20))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38)).also { it.setMargins(dp(8), 0, 0, 0) }
            setPadding(dp(9), dp(9), dp(9), dp(9))
            background = pillBg()
            setOnClickListener { openMainMenu() }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(settingsBtn, { pillBg() }, {
            GradientDrawable().apply { setColor(0x40FFD600); cornerRadius = dpf(10); setStroke(dp(2), ACCENT) }
        })
        topBar.addView(settingsBtn)

        rootLayout.addView(topBar)
    }

    // ── Center Controls ──────────────────────────────────────────────────────

    private fun buildCenterControls() {
        centerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            clipChildren = false
            clipToPadding = false
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER
            )
        }

        // Rewind 10s - 48dp circle with border (matching Flutter _buildCircleButton size:48, iconSize:30)
        rewindBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(rewindIcon(Color.WHITE, 30))
            layoutParams = LinearLayout.LayoutParams(dp(54), dp(54)).also { it.setMargins(0, 0, dp(32), 0) }
            setPadding(dp(6), dp(6), dp(6), dp(6))
            background = circleBtnBg(filled = false)
            setOnClickListener { seekRelative(-10_000); showActionBrief(rewindIcon(ACCENT, 24), "-10s"); animatePress(this) }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(rewindBtn, { circleBtnBg(filled = false) }, {
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(ACCENT_DIM); setStroke(dp(3), ACCENT) }
        })
        centerRow.addView(rewindBtn)

        // Play/Pause - large filled yellow circle (no padding clipping)
        playPauseBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(pauseIcon(Color.BLACK, 44))
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72))
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = circleBtnBg(filled = true)
            setOnClickListener { togglePlayPause(); animatePress(this) }
            isFocusable = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            elevation = dpf(10)
            clipToOutline = false
            outlineProvider = null
        }
        applyFocusHighlight(
            playPauseBtn,
            { circleBtnBg(filled = true) },
            {
                GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(0xFFFFE033.toInt())  // brighter accent fill on focus
                    setStroke(dp(3), Color.WHITE) // white ring to pop on dark BG
                }
            },
            onFocus = { playPauseBtn.elevation = dpf(20) },
            onBlur  = { playPauseBtn.elevation = dpf(10) }
        )
        centerRow.addView(playPauseBtn)

        // Forward 10s - 48dp circle with border (matching Flutter)
        forwardBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(forwardIcon(Color.WHITE, 30))
            layoutParams = LinearLayout.LayoutParams(dp(54), dp(54)).also { it.setMargins(dp(32), 0, 0, 0) }
            setPadding(dp(6), dp(6), dp(6), dp(6))
            background = circleBtnBg(filled = false)
            setOnClickListener { seekRelative(10_000); showActionBrief(forwardIcon(ACCENT, 24), "+10s"); animatePress(this) }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(forwardBtn, { circleBtnBg(filled = false) }, {
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(ACCENT_DIM); setStroke(dp(3), ACCENT) }
        })
        centerRow.addView(forwardBtn)

        rootLayout.addView(centerRow)
    }

    // ── Bottom Bar ───────────────────────────────────────────────────────────

    private fun buildBottomBar() {
        bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            clipToPadding = false
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM
            ).also { it.setMargins(dp(16), 0, dp(16), dp(12)) }
        }

        // Seek bar - slim track, crisp thumb (closer to Flutter look)
        seekBar = SeekBar(this).apply {
            id = View.generateViewId()
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40))
            progressDrawable = youtubeSeekDrawable()
            thumb = youtubeSeekThumb()
            splitTrack = false
            thumbOffset = dp(8)
            minHeight = dp(14)
            maxHeight = dp(14)
            max = 1000
            keyProgressIncrement = 25  // 2.5% steps for D-pad
            setPadding(dp(10), dp(8), dp(10), dp(8))
            progressTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            secondaryProgressTintList = android.content.res.ColorStateList.valueOf(0x669CA3B2.toInt())
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(0x80FFFFFF.toInt())
            thumbTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, progress: Int, fromUser: Boolean) {
                    if (fromUser && duration > 0) {
                        positionText.text = formatTime(duration * progress / 1000)
                    }
                }
                override fun onStartTrackingTouch(sb: SeekBar) {
                    isDraggingSeekBar = true
                    mainHandler.removeCallbacks(hideControlsRunnable)
                }
                override fun onStopTrackingTouch(sb: SeekBar) {
                    isDraggingSeekBar = false
                    if (duration > 0) {
                        player?.seekTo(duration * sb.progress / 1000)
                        if (isCastActive) pushCastStatusToFlutter()
                    }
                    scheduleHideControls()
                }
            })
            setOnKeyListener { _, keyCode, event ->
                if (event.action != KeyEvent.ACTION_DOWN) return@setOnKeyListener false
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT -> { handleSeekKey(-10_000L); return@setOnKeyListener true }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> { handleSeekKey(10_000L); return@setOnKeyListener true }
                }
                false
            }
            onFocusChangeListener = View.OnFocusChangeListener { v, hasFocus ->
                v.alpha = if (hasFocus) 1f else 0.6f
                if (hasFocus) {
                    v.animate().scaleY(1.3f).setDuration(120).start()
                    showActionBrief(playIcon(ACCENT, 20), "◄/► Seek")
                } else {
                    v.animate().scaleY(1.0f).setDuration(120).start()
                }
            }
        }
        bottomBar.addView(seekBar)

        // Time + buttons row (matching Flutter bottom bar: time on left, audio pill + speed pill on right)
        val timeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(8) }
        }

        // Position / Duration text (matching Flutter GoogleFonts.outfit w500 13px)
        positionText = TextView(this).apply {
            text = "0:00"
            setTextColor(0xB3FFFFFF.toInt()) // Colors.white70
            textSize = 13f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        timeRow.addView(positionText)
        timeRow.addView(TextView(this).apply {
            text = " / "
            setTextColor(0xB3FFFFFF.toInt())
            textSize = 13f
        })
        durationText = TextView(this).apply {
            text = "0:00"
            setTextColor(0xB3FFFFFF.toInt())
            textSize = 13f
        }
        timeRow.addView(durationText)

        // Spacer
        timeRow.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 0, 1f) })

        // Audio track pill button (matching Flutter's audio track quick button)
        audioBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(audioIcon(0xB3FFFFFF.toInt(), 14))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(30)).also { it.setMargins(dp(10), 0, 0, 0) }
            setPadding(dp(10), dp(5), dp(10), dp(5))
            background = GradientDrawable().apply {
                setColor(0x1AFFFFFF) // Colors.white.withOpacity(0.1)
                cornerRadius = dpf(16)
                setStroke(dp(1), 0x26FFFFFF) // Colors.white.withOpacity(0.15)
            }
            setOnClickListener { openAudioMenu() }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(audioBtn,
            {
                GradientDrawable().apply {
                    setColor(0x1AFFFFFF); cornerRadius = dpf(16); setStroke(dp(1), 0x26FFFFFF)
                }
            },
            {
                GradientDrawable().apply {
                    setColor(0x33FFD600); cornerRadius = dpf(16); setStroke(dp(3), ACCENT)
                }
            }
        )
        timeRow.addView(audioBtn)

        // Speed pill button (matching Flutter's speed button)
        speedBtn = TextView(this).apply {
            id = View.generateViewId()
            text = "1.0x"
            setTextColor(0xB3FFFFFF.toInt()) // Colors.white70
            textSize = 12f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(30)).also { it.setMargins(dp(10), 0, 0, 0) }
            setPadding(dp(12), dp(5), dp(12), dp(5))
            background = GradientDrawable().apply {
                setColor(0x1AFFFFFF)
                cornerRadius = dpf(16)
                setStroke(dp(1), 0x26FFFFFF)
            }
            setOnClickListener { toggleSpeedMenu() }
            isFocusable = true
        }
        applyFocusHighlight(speedBtn,
            {
                GradientDrawable().apply { setColor(0x1AFFFFFF); cornerRadius = dpf(16); setStroke(dp(1), 0x26FFFFFF) }
            },
            {
                GradientDrawable().apply { setColor(0x33FFD600); cornerRadius = dpf(16); setStroke(dp(3), ACCENT) }
            }
        )
        timeRow.addView(speedBtn)

        // Lock pill button
        lockBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(lockIcon(0xB3FFFFFF.toInt(), 16))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(30)).also { it.setMargins(dp(10), 0, 0, 0) }
            setPadding(dp(10), dp(5), dp(10), dp(5))
            background = GradientDrawable().apply {
                setColor(0x1AFFFFFF)
                cornerRadius = dpf(16)
                setStroke(dp(1), 0x26FFFFFF)
            }
            setOnClickListener { toggleLock() }
            isFocusable = true
            scaleType = ImageView.ScaleType.CENTER
        }
        applyFocusHighlight(lockBtn,
            {
                GradientDrawable().apply { setColor(0x1AFFFFFF); cornerRadius = dpf(16); setStroke(dp(1), 0x26FFFFFF) }
            },
            {
                GradientDrawable().apply { setColor(0x33FFD600); cornerRadius = dpf(16); setStroke(dp(3), ACCENT) }
            }
        )
        timeRow.addView(lockBtn)

        bottomBar.addView(timeRow)
        rootLayout.addView(bottomBar)
    }

    // ── Action Indicator ─────────────────────────────────────────────────────

    private fun buildActionIndicator() {
        actionIndicator = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL
            ).also { (it as FrameLayout.LayoutParams).topMargin = dp(50) }
            background = GradientDrawable().apply {
                setColor(0xF015171C.toInt()); cornerRadius = dpf(14)
                setStroke(dp(1), 0x66FFD600)
            }
            setPadding(dp(20), dp(12), dp(20), dp(12))
            visibility = View.GONE; elevation = dpf(8)
        }
        actionIcon = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(22), dp(22)).also { it.setMargins(0, 0, dp(10), 0) }
        }
        actionIndicator.addView(actionIcon)
        actionLabel = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 14f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
        }
        actionIndicator.addView(actionLabel)
        rootLayout.addView(actionIndicator)
    }

    // ── Volume Overlay ───────────────────────────────────────────────────────

    private fun buildVolumeOverlay() {
        volumeOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = FrameLayout.LayoutParams(dp(46), dp(180), Gravity.CENTER_VERTICAL or Gravity.START).also { it.leftMargin = dp(24) }
            background = GradientDrawable().apply {
                setColor(0xF015171C.toInt()); cornerRadius = dpf(23)
                setStroke(dp(1), 0x66FFD600)
            }
            setPadding(dp(8), dp(12), dp(8), dp(12)); visibility = View.GONE; elevation = dpf(8)
        }
        val vIcon = ImageView(this).apply {
            setImageDrawable(audioIcon(ACCENT, 20))
            layoutParams = LinearLayout.LayoutParams(dp(20), dp(20))
        }
        volumeOverlay.addView(vIcon)
        volumeBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = LinearLayout.LayoutParams(dp(4), dp(100)).also { it.topMargin = dp(8); it.bottomMargin = dp(8) }
            max = 100; progress = 100
            progressTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(0x1FFFFFFF) // 0.12 opacity white
            rotation = -90f
        }
        volumeOverlay.addView(volumeBar)
        volumeText = TextView(this).apply {
            text = "100"
            setTextColor(0xB3FFFFFF.toInt()) // white70
            textSize = 11f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        volumeOverlay.addView(volumeText)
        rootLayout.addView(volumeOverlay)
    }

    // ── Brightness Overlay ───────────────────────────────────────────────────

    private fun buildBrightnessOverlay() {
        brightnessOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = FrameLayout.LayoutParams(dp(46), dp(180), Gravity.CENTER_VERTICAL or Gravity.END).also { it.rightMargin = dp(24) }
            background = GradientDrawable().apply {
                setColor(0xF015171C.toInt()); cornerRadius = dpf(23)
                setStroke(dp(1), 0x66FFD600)
            }
            setPadding(dp(8), dp(12), dp(8), dp(12)); visibility = View.GONE; elevation = dpf(8)
        }
        val bIcon = ImageView(this).apply {
            setImageDrawable(object : Drawable() {
                private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ACCENT; style = Paint.Style.STROKE; strokeWidth = dp(20) * 0.08f }
                override fun draw(canvas: Canvas) {
                    val b = bounds; val cx = b.centerX().toFloat(); val cy = b.centerY().toFloat(); val r = b.width() * 0.35f
                    canvas.drawCircle(cx, cy, r, paint)
                    for (i in 0 until 8) {
                        val angle = Math.toRadians(i * 45.0)
                        val x1 = cx + (r * 1.2f * Math.cos(angle)).toFloat(); val y1 = cy + (r * 1.2f * Math.sin(angle)).toFloat()
                        val x2 = cx + (r * 1.5f * Math.cos(angle)).toFloat(); val y2 = cy + (r * 1.5f * Math.sin(angle)).toFloat()
                        canvas.drawLine(x1, y1, x2, y2, paint)
                    }
                }
                override fun getIntrinsicWidth() = dp(20)
                override fun getIntrinsicHeight() = dp(20)
                override fun setAlpha(a: Int) {} ; override fun setColorFilter(cf: ColorFilter?) {} ; override fun getOpacity() = PixelFormat.TRANSLUCENT
            })
            layoutParams = LinearLayout.LayoutParams(dp(20), dp(20))
        }
        brightnessOverlay.addView(bIcon)
        brightnessBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = LinearLayout.LayoutParams(dp(4), dp(100)).also { it.topMargin = dp(8); it.bottomMargin = dp(8) }
            max = 100; progress = 50
            progressTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(0x1FFFFFFF)
            rotation = -90f
        }
        brightnessOverlay.addView(brightnessBar)
        brightnessText = TextView(this).apply {
            text = "50"
            setTextColor(0xB3FFFFFF.toInt())
            textSize = 11f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        brightnessOverlay.addView(brightnessText)
        rootLayout.addView(brightnessOverlay)
    }

    // ── Double-Tap Overlay ───────────────────────────────────────────────────

    private fun buildDoubleTapOverlay() {
        doubleTapOverlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            visibility = View.GONE
        }
        doubleTapLabel = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 16f
            typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
            gravity = Gravity.CENTER; setShadowLayer(4f, 0f, 2f, Color.BLACK)
        }
        doubleTapOverlay.addView(doubleTapLabel)
        rootLayout.addView(doubleTapOverlay)
    }

    // ── Menu Overlay ─────────────────────────────────────────────────────────

    private fun buildMenuOverlay() {
        menuOverlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            setBackgroundColor(0x00000000); visibility = View.GONE
            setOnClickListener { closeMenu() }
        }
        menuCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(0xF3141619.toInt())
                cornerRadii = floatArrayOf(dpf(20), dpf(20), 0f, 0f, 0f, 0f, dpf(20), dpf(20))
            }
            layoutParams = FrameLayout.LayoutParams(menuPanelWidth, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.END)
            setPadding(0, dp(8), 0, dp(16)); elevation = dpf(24)
            setOnClickListener { /* consume clicks inside panel */ }
        }
        // Panel header row with title and close hint
        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(16), dp(16), dp(12))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        menuTitle = TextView(this).apply {
            text = "Settings"; setTextColor(ACCENT); textSize = 16f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        headerRow.addView(menuTitle)
        // Close / swipe hint arrow
        headerRow.addView(TextView(this).apply {
            text = "›"; setTextColor(0x66FFFFFF); textSize = 22f; gravity = Gravity.CENTER
            setPadding(dp(8), 0, dp(8), 0)
            setOnClickListener { closeMenu() }
        })
        menuCard.addView(headerRow)
        menuCard.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).also { it.setMargins(dp(16), 0, dp(16), dp(4)) }
            setBackgroundColor(0x22FFFFFF)
        })
        menuAdapter = NativeMenuAdapter(this)
        menuListView = ListView(this).apply {
            adapter = menuAdapter; divider = ColorDrawable(0x11FFFFFF); dividerHeight = dp(1)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
            isFocusable = true
            setPadding(dp(8), dp(4), dp(8), dp(12)); clipToPadding = false
            setSelector(android.R.color.transparent)
            setOnItemClickListener { _, _, pos, _ -> onMenuItemClicked(pos) }
        }
        menuCard.addView(menuListView)
        menuOverlay.addView(menuCard)
        rootLayout.addView(menuOverlay)
    }

    /** Show the side panel with slide-in animation. No-op on sub-menu transitions (panel already visible). */
    private fun showMenuPanel() {
        if (menuOverlay.visibility == View.VISIBLE && menuVisible) {
            // Sub-menu transition: panel is already open, just keep state updated
            mainHandler.removeCallbacks(hideControlsRunnable)
            return
        }
        menuOverlay.setBackgroundColor(0x99000000.toInt())
        menuOverlay.alpha = 0f
        menuOverlay.visibility = View.VISIBLE
        menuVisible = true
        menuCard.translationX = menuPanelWidth.toFloat()
        menuCard.animate().translationX(0f).setDuration(260).setInterpolator(DecelerateInterpolator(1.8f)).start()
        menuOverlay.animate().alpha(1f).setDuration(260).start()
        mainHandler.removeCallbacks(hideControlsRunnable)
    }

    // ── Lock Button ──────────────────────────────────────────────────────────

    private fun buildLockButton() {
        lockUnlockBtn = ImageView(this).apply {
            id = View.generateViewId()
            setImageDrawable(lockIcon(0xB3FFFFFF.toInt(), 20))
            layoutParams = FrameLayout.LayoutParams(dp(38), dp(38), Gravity.CENTER_VERTICAL or Gravity.END).also { it.rightMargin = dp(16) }
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = pillBg(false); elevation = dpf(8)
            visibility = View.GONE
            setOnClickListener { toggleLock() }
            isFocusable = true
        }
        rootLayout.addView(lockUnlockBtn)
    }

    // ── Speed Menu ───────────────────────────────────────────────────────────

    private fun buildSpeedMenu() {
        speedMenu = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(CARD_BG); cornerRadius = dpf(16)
                setStroke(dp(1), 0x14FFFFFF)
            }
            layoutParams = FrameLayout.LayoutParams(dp(100), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).also { it.setMargins(0, 0, dp(16), dp(80)) }
            setPadding(dp(4), dp(8), dp(4), dp(8)); elevation = dpf(12); visibility = View.GONE
        }
        // Header label
        speedMenu.addView(TextView(this).apply {
            text = "SPEED"; setTextColor(0xFF9E9E9E.toInt()); textSize = 10f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER; letterSpacing = 0.12f
            setPadding(0, 0, 0, dp(6))
        })
        speedOptions.forEachIndexed { idx, speed ->
            val isActive = abs(currentSpeed - speed) < 0.01f
            speedMenu.addView(TextView(this).apply {
                text = "${speed}x"; setTextColor(if (isActive) ACCENT else 0xB3FFFFFF.toInt()); textSize = 14f
                typeface = if (isActive) Typeface.create("sans-serif-medium", Typeface.BOLD) else Typeface.create("sans-serif-medium", Typeface.NORMAL)
                gravity = Gravity.CENTER; isFocusable = true; isFocusableInTouchMode = true
                val lp = LinearLayout.LayoutParams(dp(70), LinearLayout.LayoutParams.WRAP_CONTENT).also { it.setMargins(dp(4), dp(1), dp(4), dp(1)) }
                layoutParams = lp; setPadding(dp(12), dp(8), dp(12), dp(8))
                background = if (isActive) roundedBg(ACCENT_DIM, 8) else null; tag = speed
                setOnClickListener { speedMenuSelectedIndex = idx; setPlaybackSpeed(speed); speedMenu.visibility = View.GONE }
            })
        }
        rootLayout.addView(speedMenu)
    }

    // ── Touch Layer ──────────────────────────────────────────────────────────

    private fun buildTouchLayer() {
        var downX = 0f; var downY = 0f; var downTime = 0L; var isDragging = false
        rootLayout.setOnTouchListener { _, event ->
            if (isLocked && lockUnlockBtn.visibility == View.VISIBLE && isPointInside(lockUnlockBtn, event.rawX, event.rawY)) return@setOnTouchListener false
            if (isLocked) {
                if (event.action == MotionEvent.ACTION_UP) {
                    lockUnlockBtn.visibility = if (lockUnlockBtn.visibility == View.VISIBLE) View.GONE else View.VISIBLE
                }
                return@setOnTouchListener true
            }
            if (menuVisible || speedMenu.visibility == View.VISIBLE || isInteractiveTouch(event.rawX, event.rawY)) return@setOnTouchListener false
            val sw = rootLayout.width.toFloat(); val sh = rootLayout.height.toFloat()
            when (event.action) {
                MotionEvent.ACTION_DOWN -> { downX = event.x; downY = event.y; downTime = System.currentTimeMillis(); isDragging = false; isVerticalDragging = false; swipeSide = -1 }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.x - downX; val dy = event.y - downY
                    if (!isDragging && abs(dy) > dp(15) && abs(dy) > abs(dx) * 1.5f) {
                        isDragging = true; isVerticalDragging = true
                        swipeSide = if (downX < sw * 0.45f) 0 else if (downX > sw * 0.55f) 1 else -1
                        swipeStartY = downY; swipeStartValue = if (swipeSide == 0) currentBrightness else currentVolume
                    }
                    if (isVerticalDragging && swipeSide != -1) {
                        val deltaPct = (swipeStartY - event.y) / (sh * 0.65f)
                        if (swipeSide == 0) {
                            currentBrightness = (swipeStartValue + deltaPct).coerceIn(0.01f, 1f)
                            setBrightness(currentBrightness); showBrightnessOvl()
                        } else {
                            currentVolume = (swipeStartValue + deltaPct).coerceIn(0f, 1f)
                            player?.volume = currentVolume; showVolumeOvl()
                        }
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (isVerticalDragging) {
                        isVerticalDragging = false
                        mainHandler.postDelayed({ volumeOverlay.visibility = View.GONE; brightnessOverlay.visibility = View.GONE }, 600)
                    } else if (!isDragging && System.currentTimeMillis() - downTime < 300) {
                        handleTap(event.x, sw)
                    }
                    isDragging = false
                }
            }
            true
        }
    }

    private fun isInteractiveTouch(rawX: Float, rawY: Float): Boolean {
        val targets = listOf<View>(topBar, bottomBar, centerRow, menuOverlay, speedMenu, lockUnlockBtn, actionIndicator)
        return targets.any { isPointInside(it, rawX, rawY) }
    }

    private fun isPointInside(view: View, rawX: Float, rawY: Float): Boolean {
        if (!view.isShown) return false
        val loc = IntArray(2); view.getLocationOnScreen(loc)
        val x = rawX.toInt(); val y = rawY.toInt()
        return x >= loc[0] && x <= loc[0] + view.width && y >= loc[1] && y <= loc[1] + view.height
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Tap handling
    // ═════════════════════════════════════════════════════════════════════════

    private fun handleTap(x: Float, screenWidth: Float) {
        val now = System.currentTimeMillis()
        if (now - lastTapTime < 350 && abs(x - lastTapX) < dp(100)) {
            tapCount++; mainHandler.removeCallbacksAndMessages("singleTap")
            if (x < screenWidth * 0.4f) { seekRelative(-10_000); showDoubleTapSeek(false, tapCount) }
            else if (x > screenWidth * 0.6f) { seekRelative(10_000); showDoubleTapSeek(true, tapCount) }
        } else {
            tapCount = 1
            mainHandler.postDelayed({
                if (menuVisible) closeMenu()
                else if (speedMenu.visibility == View.VISIBLE) speedMenu.visibility = View.GONE
                else toggleControls()
            }, "singleTap", 350)
        }
        lastTapTime = now; lastTapX = x
    }

    private fun showDoubleTapSeek(forward: Boolean, count: Int) {
        doubleTapLabel.text = if (forward) "Forward ${count * 10}s" else "Rewind ${count * 10}s"
        doubleTapLabel.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or (if (forward) Gravity.END else Gravity.START)
        ).also { if (forward) it.rightMargin = dp(60) else it.leftMargin = dp(60) }
        doubleTapOverlay.background = if (forward)
            GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(0x00000000, 0x44FFD600.toInt()))
        else GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(0x44FFD600.toInt(), 0x00000000))
        doubleTapOverlay.visibility = View.VISIBLE
        mainHandler.removeCallbacksAndMessages("doubleTap")
        mainHandler.postDelayed({ doubleTapOverlay.visibility = View.GONE; tapCount = 0 }, "doubleTap", 700)
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Overlay helpers
    // ═════════════════════════════════════════════════════════════════════════

    private fun showVolumeOvl() {
        volumeBar.progress = (currentVolume * 100).toInt()
        volumeText.text = "${(currentVolume * 100).toInt()}"
        volumeOverlay.visibility = View.VISIBLE
    }

    private fun showBrightnessOvl() {
        brightnessBar.progress = (currentBrightness * 100).toInt()
        brightnessText.text = "${(currentBrightness * 100).toInt()}"
        brightnessOverlay.visibility = View.VISIBLE
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Subtitle styling
    // ═════════════════════════════════════════════════════════════════════════

    private fun applySubtitleStyle() {
        val fg = subtitleColors[subtitleColorIndex % subtitleColors.size]
        val bg = subtitleBgColors[subtitleBgIndex % subtitleBgColors.size]
        val sizeScale = subtitleSizeScale[subtitleSizeIndex % subtitleSizeScale.size]
        val pad = subtitleBottomPads[subtitlePosIndex % subtitleBottomPads.size]
        // Apply both backgroundColor and windowColor so the bg is visible on all renderers
        subtitleView.setStyle(CaptionStyleCompat(fg, bg, bg, CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, null))
        subtitleView.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * sizeScale)
        subtitleView.setBottomPaddingFraction(pad)
    }

    private fun subtitleColorLabel() = when (subtitleColorIndex % subtitleColors.size) {
        0 -> "White"; 1 -> "Yellow"; 2 -> "Cyan"; else -> "Lime"
    }

    private fun subtitleBgLabel() = when (subtitleBgIndex % subtitleBgColors.size) {
        0 -> "Transparent"; 1 -> "Dim"; else -> "Solid"
    }

    private fun subtitleSizeLabel() = when (subtitleSizeIndex % subtitleSizeScale.size) {
        0 -> "Small"; 1 -> "Normal"; 2 -> "Large"; else -> "XL"
    }

    private fun subtitlePosLabel() = when (subtitlePosIndex % subtitleBottomPads.size) {
        0 -> "Low"; 1 -> "Mid"; 2 -> "High"; else -> "Top"
    }

    private fun cycleSubtitleColor() { subtitleColorIndex = (subtitleColorIndex + 1) % subtitleColors.size; applySubtitleStyle(); refreshSubtitleMenuOptions() }
    private fun cycleSubtitleBg() { subtitleBgIndex = (subtitleBgIndex + 1) % subtitleBgColors.size; applySubtitleStyle(); refreshSubtitleMenuOptions(); showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle BG: ${subtitleBgLabel()}") }
    private fun cycleSubtitleSize() { subtitleSizeIndex = (subtitleSizeIndex + 1) % subtitleSizeScale.size; applySubtitleStyle(); refreshSubtitleMenuOptions(); showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle Size: ${subtitleSizeLabel()}") }
    private fun cycleSubtitlePos() { subtitlePosIndex = (subtitlePosIndex + 1) % subtitleBottomPads.size; applySubtitleStyle(); refreshSubtitleMenuOptions(); showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle Position: ${subtitlePosLabel()}") }

    private fun setBrightness(value: Float) {
        val lp = window.attributes; lp.screenBrightness = value.coerceIn(0.01f, 1f); window.attributes = lp
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Controls visibility (animated)
    // ═════════════════════════════════════════════════════════════════════════

    private fun toggleControls() { if (controlsVisible) hideControls() else { showControls(); scheduleHideControls() } }

    private fun showControls() {
        controlsVisible = true
        // Immediately sync seek bar to current position to avoid stale display
        updateProgress()
        // Only request focus if nothing interactive currently has focus
        if (isTvDevice) {
            val cur = currentFocus
            if (cur == null || cur == rootLayout) playPauseBtn.requestFocus()
        }
        fadeViews(1f, topBar, topGradient, bottomBar, bottomGradient, centerRow)
    }

    private fun hideControls() {
        if (menuVisible || speedMenu.visibility == View.VISIBLE) return
        controlsVisible = false
        fadeViews(0f, topBar, topGradient, bottomBar, bottomGradient, centerRow)
    }

    private fun fadeViews(alpha: Float, vararg views: View) {
        for (v in views) {
            v.animate().alpha(alpha).setDuration(250).setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationStart(a: Animator) { if (alpha > 0f) v.visibility = View.VISIBLE }
                override fun onAnimationEnd(a: Animator) { if (alpha == 0f) v.visibility = View.GONE }
            }).start()
        }
    }

    private fun scheduleHideControls() {
        showControls(); mainHandler.removeCallbacks(hideControlsRunnable)
        mainHandler.postDelayed(hideControlsRunnable, 4000)
    }

    private fun showActionBrief(iconRes: Int, text: String) {
        actionIcon.setImageResource(iconRes); actionLabel.text = text
        showActionBriefCommon()
    }

    private fun showActionBrief(drawable: Drawable, text: String) {
        actionIcon.setImageDrawable(drawable); actionLabel.text = text
        showActionBriefCommon()
    }

    private fun showActionBriefCommon() {
        actionIndicator.visibility = View.VISIBLE; actionIndicator.alpha = 1f
        mainHandler.removeCallbacksAndMessages("actionHide")
        mainHandler.postDelayed({
            actionIndicator.animate().alpha(0f).setDuration(200).setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(a: Animator) { actionIndicator.visibility = View.GONE }
            }).start()
        }, "actionHide", 1000)
    }

    private fun animatePress(v: View) {
        v.animate().scaleX(0.85f).scaleY(0.85f).setDuration(100).withEndAction {
            v.animate().scaleX(1f).scaleY(1f).setDuration(100).start()
        }.start()
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Lock
    // ═════════════════════════════════════════════════════════════════════════

    private fun toggleLock() {
        isLocked = !isLocked
        if (isLocked) {
            hideControls(); lockUnlockBtn.visibility = View.VISIBLE
            lockUnlockBtn.setImageDrawable(lockIcon(ACCENT, 20))
            lockUnlockBtn.background = pillBg(true)
            showActionBrief(lockIcon(ACCENT, 24), "Locked")
        } else {
            lockUnlockBtn.setImageDrawable(lockIcon(0xB3FFFFFF.toInt(), 20))
            lockUnlockBtn.background = pillBg(false)
            lockUnlockBtn.visibility = View.GONE; showControls(); scheduleHideControls()
            showActionBrief(lockIcon(ACCENT, 24), "Unlocked")
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Speed
    // ═════════════════════════════════════════════════════════════════════════

    private fun toggleSpeedMenu() {
        if (speedMenu.visibility == View.VISIBLE) {
            speedMenu.visibility = View.GONE
        } else {
            speedMenuSelectedIndex = speedOptions.indexOfFirst { abs(it - currentSpeed) < 0.01f }.takeIf { it >= 0 } ?: 3
            refreshSpeedMenu(); speedMenu.visibility = View.VISIBLE; mainHandler.removeCallbacks(hideControlsRunnable)
            if (speedMenu.childCount > 1) speedMenu.getChildAt(speedMenuSelectedIndex + 1)?.requestFocus()
        }
    }

    private fun refreshSpeedMenu() {
        for (i in 1 until speedMenu.childCount) {
            val btn = speedMenu.getChildAt(i) as? TextView ?: continue
            val speed = btn.tag as? Float ?: continue
            val isActive = abs(currentSpeed - speed) < 0.01f
            val isSelected = (i - 1) == speedMenuSelectedIndex
            val color = when {
                isActive -> ACCENT
                isSelected -> 0xFFFFFFFF.toInt()
                else -> 0xB3FFFFFF.toInt()
            }
            btn.setTextColor(color)
            btn.typeface = when {
                isActive -> Typeface.create("sans-serif-medium", Typeface.BOLD)
                isSelected -> Typeface.create("sans-serif-medium", Typeface.BOLD)
                else -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
            }
            btn.background = when {
                isActive -> roundedBg(ACCENT_DIM, 8)
                isSelected -> roundedBg(0x22FFFFFF, 8)
                else -> null
            }
        }
    }

    private fun setPlaybackSpeed(speed: Float) {
        currentSpeed = speed; speedMenuSelectedIndex = speedOptions.indexOfFirst { abs(it - speed) < 0.01f }.takeIf { it >= 0 } ?: speedMenuSelectedIndex
        player?.setPlaybackParameters(PlaybackParameters(speed))
        speedBtn.text = "${speed}x"
        showActionBrief(playIcon(ACCENT, 24), "${speed}x"); scheduleHideControls()
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Aspect ratio
    // ═════════════════════════════════════════════════════════════════════════

    private fun cycleAspectRatio() {
        currentFitIndex = (currentFitIndex + 1) % fitModes.size
        applyAspectRatio(fitModes[currentFitIndex])
        showActionBrief(aspectRatioIcon(ACCENT, 24), fitModes[currentFitIndex]); scheduleHideControls()
    }

    private fun applyAspectRatio(mode: String, ratioOverride: Float? = null) {
        val ratio = ratioOverride ?: videoAspectRatio
        when (mode) {
            "Fit" -> {
                videoFrame.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                videoFrame.setAspectRatio(ratio)
                player?.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            }
            "Fill" -> {
                videoFrame.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                videoFrame.setAspectRatio(ratio)
                player?.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING)
            }
            "Stretch" -> {
                videoFrame.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
                videoFrame.setAspectRatio(ratio)
                player?.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING)
            }
            "16:9" -> {
                videoFrame.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                videoFrame.setAspectRatio(16f / 9f)
                player?.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            }
            "4:3" -> {
                videoFrame.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                videoFrame.setAspectRatio(4f / 3f)
                player?.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ExoPlayer Init
    // ═════════════════════════════════════════════════════════════════════════

    private fun initPlayer() {
        try { initPlayerInternal() } catch (e: Exception) {
            android.util.Log.e("NativeVideoPlayer", "initPlayer crashed, retrying safe", e)
            try { initPlayerSafe() } catch (e2: Exception) {
                showFatalError("Cannot initialize player:\n${e.message}\n\nSafe-mode also failed:\n${e2.message}")
            }
        }
    }

    private fun initPlayerInternal() {
        // Reset cast-source state for new media
        isCastSourceAudio = false
        castAudioTrackIndex = 0
        selectedAudioOutputIndex = 0

        trackSelector = DefaultTrackSelector(this).apply {
            // Disable tunneling to avoid rare video-freeze/audio-only states after long seeks on some TVs
            parameters = buildUponParameters()
                .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
                .setForceLowestBitrate(false)
                .setTunnelingEnabled(false)
                .build()
        }
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                if (isTvDevice) 20_000 else 50_000,
                if (isTvDevice) 40_000 else 100_000,
                if (isTvDevice) 1_500 else 2_500,
                if (isTvDevice) 3_000 else 5_000
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .setBackBuffer(if (isTvDevice) 10_000 else 15_000, true)
            .build()
        val renderersFactory = DefaultRenderersFactory(this).apply {
            setEnableDecoderFallback(true) // Allow falling back to software decoder for EAC3 if hardware fails
            setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
        }
        player = ExoPlayer.Builder(this).setTrackSelector(trackSelector!!).setLoadControl(loadControl).setRenderersFactory(renderersFactory).build()
        configurePlayer(); attachSurfaceAndLoadMedia()
    }

    private fun initPlayerSafe() {
        player?.release(); player = null; trackSelector = null
        trackSelector = DefaultTrackSelector(this).apply {
            parameters = buildUponParameters().setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE).setTunnelingEnabled(false).build()
        }
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                if (isTvDevice) 20_000 else 50_000,
                if (isTvDevice) 40_000 else 100_000,
                if (isTvDevice) 1_500 else 2_500,
                if (isTvDevice) 3_000 else 5_000
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .setBackBuffer(if (isTvDevice) 10_000 else 15_000, true)
            .build()
        val renderersFactory = DefaultRenderersFactory(this).apply { setEnableDecoderFallback(true); setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER) }
        player = ExoPlayer.Builder(this).setTrackSelector(trackSelector!!).setLoadControl(loadControl).setRenderersFactory(renderersFactory).build()
        configurePlayer(); attachSurfaceAndLoadMedia()
    }

    private fun configurePlayer() {
        player?.apply {
            try { videoChangeFrameRateStrategy = C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS } catch (_: Exception) {}
            try { setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT) } catch (_: Exception) {}
            // Use exact seeking for perfect audio/video synchronization (even on large MP4 files)
            try { setSeekParameters(androidx.media3.exoplayer.SeekParameters.EXACT) } catch (_: Exception) {}
            addListener(object : Player.Listener {
                override fun onCues(cueGroup: CueGroup) {
                    mainHandler.post { subtitleView.setCues(cueGroup.cues) }
                }
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    val aspect = if (videoSize.height == 0) 1f else (videoSize.width * videoSize.pixelWidthHeightRatio) / videoSize.height
                    videoAspectRatio = aspect
                    mainHandler.post { applyAspectRatio(fitModes[currentFitIndex], aspect) }
                }
                override fun onPlaybackStateChanged(state: Int) {
                    when (state) {
                        Player.STATE_BUFFERING -> mainHandler.post { loadingSpinner.visibility = View.VISIBLE }
                        Player.STATE_READY -> mainHandler.post { loadingSpinner.visibility = View.GONE; this@NativeVideoPlayerActivity.duration = this@apply.duration.coerceAtLeast(0) }
                        Player.STATE_ENDED -> mainHandler.post { finishWithPosition() }
                        else -> {}
                    }
                }
                override fun onIsPlayingChanged(playing: Boolean) {
                    this@NativeVideoPlayerActivity.isPlaying = playing
                    mainHandler.post {
                        updatePlayPauseIcon()
                        pushCastStatusToFlutter()
                    }
                }
                override fun onPlayerError(error: PlaybackException) {
                    android.util.Log.e("NativeVideoPlayer", "Playback error: ${error.errorCode} ${error.message}", error)
                    if (isTvDevice && (error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED || error.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED)) {
                        mainHandler.post { retryWithoutTunneledPlayback() }; return
                    }
                    mainHandler.post { showFatalError("Playback error (${error.errorCode}):\n${error.message}") }
                }
            })
        }
    }

    private fun attachSurfaceAndLoadMedia() {
        if (isSurfaceReady) player?.setVideoSurfaceHolder(surfaceView.holder) else pendingPlay = true
        loadMedia(); mainHandler.post(positionRunnable)
        // Force the first audio track (index 0) on load to prevent language-based 
        // auto-selection from skipping track 1 (e.g. Hindi) in favor of English.
        mainHandler.postDelayed({ selectAudioTrack(0) }, 1200)
    }

    private fun loadMedia() { try { loadMediaInternal() } catch (e: Exception) { showFatalError("Cannot load video:\n${e.message}") } }

    private fun loadMediaInternal() {
        val source = intent.getStringExtra(EXTRA_SOURCE)
        if (source.isNullOrEmpty()) { showFatalError("No video source provided."); return }
        val subtitlePath = intent.getStringExtra(EXTRA_SUBTITLE_PATH)
        val startPos = intent.getLongExtra(EXTRA_START_POSITION, 0L)
        val uri = when {
            source.startsWith("http://") || source.startsWith("https://") -> Uri.parse(source)
            source.startsWith("content://") -> Uri.parse(source)
            else -> Uri.parse("file://$source")
        }
        val builder = MediaItem.Builder().setUri(uri)
        if (!subtitlePath.isNullOrEmpty()) {
            val subUri = when {
                subtitlePath.startsWith("content://") || subtitlePath.startsWith("http") -> Uri.parse(subtitlePath)
                else -> Uri.parse("file://$subtitlePath")
            }
            val mimeType = when {
                subtitlePath.endsWith(".srt", true) -> MimeTypes.APPLICATION_SUBRIP
                subtitlePath.endsWith(".vtt", true) -> MimeTypes.TEXT_VTT
                subtitlePath.endsWith(".ass", true) || subtitlePath.endsWith(".ssa", true) -> MimeTypes.TEXT_SSA
                else -> MimeTypes.APPLICATION_SUBRIP
            }
            builder.setSubtitleConfigurations(listOf(MediaItem.SubtitleConfiguration.Builder(subUri).setMimeType(mimeType).setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build()))
        }
        player?.setMediaItem(builder.build()); player?.prepare()
        if (startPos > 0) player?.seekTo(startPos)
        player?.playWhenReady = true
    }

    private fun retryWithoutTunneledPlayback() {
        try {
            trackSelector?.let { it.parameters = it.buildUponParameters().setTunnelingEnabled(false).build() }
            showActionBrief(playIcon(ACCENT, 24), "Retrying…")
            player?.let { val pos = it.currentPosition; it.stop(); loadMedia(); if (pos > 0) it.seekTo(pos) }
        } catch (e: Exception) {
            try { initPlayerSafe() } catch (e2: Exception) { showFatalError("Cannot play: ${e.message}\nRetry failed: ${e2.message}") }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Playback controls
    // ═════════════════════════════════════════════════════════════════════════

    private fun togglePlayPause() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
        pushCastStatusToFlutter()
        scheduleHideControls()
    }

    private fun seekRelative(deltaMs: Int) = seekRelative(deltaMs.toLong())

    private fun seekRelative(deltaMs: Long) {
        player?.let {
            it.seekTo((it.currentPosition + deltaMs).coerceIn(0, duration.coerceAtLeast(1)))
            updateProgress()
            if (isCastActive) pushCastStatusToFlutter()
        }
    }

    private fun updatePlayPauseIcon() {
        playPauseBtn.setImageDrawable(if (isPlaying) pauseIcon(Color.BLACK, 44) else playIcon(Color.BLACK, 44))
    }

    private fun updateProgress() {
        val p = player ?: return
        position = p.currentPosition
        if (duration <= 0) duration = p.duration.coerceAtLeast(0)
        if (controlsVisible && duration > 0 && !isDraggingSeekBar && !isSeeking) {
            seekBar.progress = (position * 1000 / duration).toInt().coerceIn(0, 1000)
            seekBar.secondaryProgress = (p.bufferedPosition * 1000 / duration).toInt().coerceIn(0, 1000)
            positionText.text = formatTime(position)
            durationText.text = formatTime(duration)
        }
    }

    private fun formatTime(ms: Long): String {
        if (ms <= 0) return "0:00"
        val s = ms / 1000; val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Menu
    // ═════════════════════════════════════════════════════════════════════════

    private fun refreshSubtitleMenuOptions() {
        if (currentMenuType != MENU_SUBTITLE) return
        val totalTracks = subtitleTrackOptions.size - 1
        val trackLabel = when {
            subtitleTrackOptions.isEmpty() -> "Track ◄ None ►"
            subtitleTrackIndex == 0 -> "Track ◄ Off ►"
            else -> {
                val safeLabel = subtitleTrackOptions.getOrElse(subtitleTrackIndex) { "Track" }
                val countLabel = if (totalTracks > 0) "${subtitleTrackIndex}/${totalTracks}" else ""
                "Track ◄ ${if (countLabel.isEmpty()) safeLabel else "$countLabel · $safeLabel"} ►"
            }
        }
        val extras = listOf(
            "Color ◄ ${subtitleColorLabel()} ►",
            "Background ◄ ${subtitleBgLabel()} ►",
            "Size ◄ ${subtitleSizeLabel()} ►",
            "Position ◄ ${subtitlePosLabel()} ►"
        )
        menuItems = listOf("← Back", trackLabel) + extras
        menuSelectedIndex = menuSelectedIndex.coerceIn(0, menuItems.lastIndex)
        menuAdapter.setItems(menuItems, menuSelectedIndex)
    }

    private fun openMainMenu() {
        currentMenuType = MENU_MAIN; menuSelectedIndex = 0; menuTitle.text = "Settings"
        menuItems = listOf("🎵  Audio Track", "�  Audio Output", "�💬  Subtitles", "⚡  Playback Speed", "✕  Close")
        menuAdapter.setItems(menuItems, menuSelectedIndex); menuListView.setSelection(0)
        showMenuPanel()
    }

    private fun openAudioMenu() {
        val p = player ?: return; val tracks = getAudioTrackLabels(p)
        if (tracks.isEmpty()) { showActionBrief(audioIcon(ACCENT, 24), "No audio tracks"); return }
        currentMenuType = MENU_AUDIO; menuSelectedIndex = 0; menuTitle.text = "Audio Track"
        menuItems = listOf("← Back") + tracks; menuAdapter.setItems(menuItems, menuSelectedIndex)
        menuListView.setSelection(0); showMenuPanel()
    }

    private fun openSubtitleMenu() {
        val p = player ?: return
        val rawLabels = getSubtitleTrackLabels(p)
        subtitleTrackLabels = rawLabels.map { it.replace(" ✓", "") }
        subtitleTrackCount = subtitleTrackLabels.size
        subtitleTrackOptions = listOf("Off") + subtitleTrackLabels
        subtitleTrackIndex = resolveCurrentSubtitleIndex(p)
        currentMenuType = MENU_SUBTITLE
        menuSelectedIndex = 1 // focus the track row for quick left/right cycling
        menuTitle.text = "Subtitles"
        refreshSubtitleMenuOptions(); menuListView.setSelection(menuSelectedIndex)
        showMenuPanel()
        showActionBrief(subtitleIcon(ACCENT, 24), "Use ◄/► to switch tracks; tap for styles")
    }

    private fun buildAudioOutputDeviceList() {
        val labels = mutableListOf<String>()
        val devices = mutableListOf<AudioDeviceInfo?>()  // null = default

        // Default option (always available)
        labels.add("Default (This Device)")
        devices.add(null)

        // Enumerate connected output devices
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val seen = mutableSetOf<String>()
            for (device in outputDevices) {
                val name = device.productName?.toString()?.takeIf { it.isNotEmpty() && it != "null" } ?: continue
                if (name in seen) continue
                when (device.type) {
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> {
                        seen.add(name)
                        labels.add("\uD83C\uDFA7  $name (Bluetooth)")
                        devices.add(device)
                    }
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    AudioDeviceInfo.TYPE_WIRED_HEADSET -> {
                        seen.add(name)
                        labels.add("\uD83C\uDFA7  $name")
                        devices.add(device)
                    }
                    AudioDeviceInfo.TYPE_USB_DEVICE,
                    AudioDeviceInfo.TYPE_USB_HEADSET -> {
                        seen.add(name)
                        labels.add("\uD83D\uDD0C  $name (USB)")
                        devices.add(device)
                    }
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> {
                        if ("Speaker" !in seen) {
                            seen.add("Speaker")
                            labels.add("\uD83D\uDD0A  Built-in Speaker")
                            devices.add(device)
                        }
                    }
                }
            }
        }

        // Cast Source option (only when casting)
        if (isCastActive) {
            labels.add("\uD83D\uDCF1  Cast Source (Phone)")
            devices.add(null)  // handled specially
        }

        audioOutputLabels = labels
        audioOutputDevices = devices
    }

    private fun openAudioDeviceMenu() {
        buildAudioOutputDeviceList()
        currentMenuType = MENU_AUDIO_DEVICE
        menuSelectedIndex = 0
        menuTitle.text = "Audio Output"
        menuItems = listOf("← Back") + audioOutputLabels.mapIndexed { idx, label ->
            if (idx == selectedAudioOutputIndex) "$label  ✓" else label
        }
        menuAdapter.setItems(menuItems, menuSelectedIndex)
        menuListView.setSelection(0)
        showMenuPanel()
    }

    fun selectAudioOutputDeviceByName(name: String) {
        if (audioOutputLabels.isEmpty()) {
            buildAudioOutputDeviceList()
        }
        if (name == "remote") {
            val idx = audioOutputLabels.indexOfFirst { it.contains("Cast Source") || it.contains("Phone") }
            if (idx != -1) {
                selectAudioOutputDevice(idx)
            } else {
                isCastSourceAudio = true
                castAudioTrackIndex = getCurrentAudioTrackIndex() ?: castAudioTrackIndex
                player?.let {
                    it.trackSelectionParameters = it.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                        .build()
                    it.volume = currentVolume
                    it.setAudioAttributes(
                        AudioAttributes.Builder()
                            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                            .setUsage(C.USAGE_MEDIA)
                            .build(),
                        false
                    )
                    releaseAudioFocus()
                }
                showActionBrief(audioIcon(ACCENT, 24), "Audio \u2192 Cast Source")
                pushCastStatusToFlutter()
            }
        } else {
            val idx = audioOutputLabels.indexOfFirst { it.contains("Default") || it.contains("Speaker") }
            if (idx != -1) {
                selectAudioOutputDevice(idx)
            } else {
                selectAudioOutputDevice(0)
            }
        }
    }

    private fun selectAudioOutputDevice(index: Int) {
        if (index < 0 || index >= audioOutputLabels.size) return
        selectedAudioOutputIndex = index

        // Check if Cast Source was selected (last item when casting)
        val isCastSource = isCastActive && index == audioOutputLabels.size - 1
        val wasCastSource = isCastSourceAudio
        isCastSourceAudio = isCastSource

        if (isCastSource) {
            // Remember current active track so Flutter can mirror it locally
            castAudioTrackIndex = getCurrentAudioTrackIndex() ?: castAudioTrackIndex
            // Completely disable audio track rendering on TV so zero audio leaks from speakers.
            // We keep the track selection override so: (a) status reporting is correct, and
            // (b) if user switches tracks on TV, the override is already in place.
            player?.let {
                it.trackSelectionParameters = it.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                    .build()
                it.volume = currentVolume  // keep volume state consistent

                // CRITICAL: Tell ExoPlayer to relinquish Android audio focus.
                // If ExoPlayer keeps audio focus, the OS will silently block or duck
                // any other audio player (media_kit on the phone) that tries to play.
                // We must explicitly set handleAudioFocus=false so media_kit can claim focus.
                it.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .setUsage(C.USAGE_MEDIA)
                        .build(),
                    false  // handleAudioFocus = false → release audio focus
                )

                // Belt-and-suspenders: also abandon focus directly via AudioManager on
                // Android 8+ (API 26). Some OEM ROMs don't honour ExoPlayer's release when
                // the activity is in a foreground window — this guarantees focus is freed.
                releaseAudioFocus()
            }
            showActionBrief(audioIcon(ACCENT, 24), "Audio \u2192 Cast Source")
            // Push immediately so Flutter starts the local audio player right away
            pushCastStatusToFlutter()
        } else {
            // Clear cast-source flag FIRST so pushCastStatusToFlutter reports audioOutput=default
            isCastSourceAudio = false

            // Restore ExoPlayer's audio focus handling before re-enabling the audio renderer.
            // This ensures the TV gets audio focus back so it can actually output sound.
            player?.setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                true  // handleAudioFocus = true → reclaim audio focus
            )
            // Reclaim audio focus directly via AudioManager as well, matching the release above
            requestAudioFocus()

            // Re-enable audio track rendering on the TV and restore volume
            player?.let { p ->
                // Apply the track override BEFORE enabling the audio renderer
                val manualOverride = getAudioTrackOverride()
                p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
                    .apply { if (manualOverride != null) setOverrideForType(manualOverride) }
                    .build()
                p.volume = currentVolume

                // ExoPlayer doesn't always restart the audio renderer just from parameter
                // changes. A micro-seek at the current position flushes the renderer and
                // guarantees audio comes back immediately.
                mainHandler.postDelayed({
                    player?.let { q ->
                        if (q.playbackState == Player.STATE_READY) {
                            q.seekTo(q.currentPosition)
                            q.volume = currentVolume
                        }
                    }
                    // Push status AFTER flush so Flutter sees audioOutput=default and stops
                    // its local audio player.
                    pushCastStatusToFlutter()
                }, 80)
            }

            // Also push immediately (before the 80ms flush) so Flutter can begin tearing
            // down the local audio player without waiting for the delayed push.
            pushCastStatusToFlutter()

            if (!wasCastSource) {
                // Route audio to selected device (API 23+)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val device = audioOutputDevices.getOrNull(index)
                    try {
                        player?.setPreferredAudioDevice(device)
                    } catch (e: Exception) {
                        android.util.Log.e("NativeVideoPlayer", "Failed to set audio device", e)
                    }
                }
                val label = audioOutputLabels.getOrElse(index) { "Default" }
                showActionBrief(audioIcon(ACCENT, 24), "Audio \u2192 $label")
            }
        }
    }

    private fun getCurrentAudioTrackIndex(): Int? {
        val p = player ?: return null
        var idx = 0
        for (group in p.currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_AUDIO) {
                for (i in 0 until group.length) {
                    if (group.isTrackSelected(i)) return idx
                    idx++
                }
            }
        }
        return null
    }

    private fun getAudioTrackOverride(): TrackSelectionOverride? {
        val p = player ?: return null
        var idx = 0
        for (group in p.currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_AUDIO) {
                for (i in 0 until group.length) {
                    if (idx == castAudioTrackIndex) {
                        return TrackSelectionOverride(group.mediaTrackGroup, listOf(i))
                    }
                    idx++
                }
            }
        }
        return null
    }

    private fun closeMenu() {
        menuOverlay.animate().cancel(); menuCard.animate().cancel()
        menuOverlay.visibility = View.GONE; menuOverlay.alpha = 1f; menuCard.translationX = 0f
        menuVisible = false; currentMenuType = MENU_NONE; scheduleHideControls()
    }

    private fun onMenuItemClicked(index: Int) {
        when (currentMenuType) {
            MENU_MAIN -> when (index) { 0 -> openAudioMenu(); 1 -> openAudioDeviceMenu(); 2 -> openSubtitleMenu(); 3 -> { closeMenu(); toggleSpeedMenu() }; 4 -> closeMenu() }
            MENU_AUDIO -> if (index == 0) openMainMenu() else { selectAudioTrack(index - 1); closeMenu() }
            MENU_AUDIO_DEVICE -> if (index == 0) openMainMenu() else { selectAudioOutputDevice(index - 1); closeMenu() }
            MENU_SUBTITLE -> {
                when (index) {
                    0 -> openMainMenu()
                    1 -> { cycleSubtitleTrackCarousel(next = true) }
                    2 -> cycleSubtitleColor()
                    3 -> cycleSubtitleBg()
                    4 -> cycleSubtitleSize()
                    5 -> cycleSubtitlePos()
                }
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Track selection
    // ═════════════════════════════════════════════════════════════════════════

    private fun getAudioTrackLabels(p: ExoPlayer): List<String> {
        val labels = mutableListOf<String>()
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_AUDIO) { for (i in 0 until group.length) {
            val fmt = group.getTrackFormat(i); val label = fmt.label ?: fmt.language?.let { "Audio ($it)" } ?: "Audio ${labels.size + 1}"
            labels.add("$label${if (group.isTrackSelected(i)) " ✓" else ""}")
        }}}
        return labels
    }

    private fun getSubtitleTrackLabels(p: ExoPlayer): List<String> {
        val labels = mutableListOf<String>()
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_TEXT) { for (i in 0 until group.length) {
            val fmt = group.getTrackFormat(i); val label = fmt.label ?: fmt.language?.let { "Subtitle ($it)" } ?: "Subtitle ${labels.size + 1}"
            labels.add("$label${if (group.isTrackSelected(i)) " ✓" else ""}")
        }}}
        return labels
    }

    private fun resolveCurrentSubtitleIndex(p: ExoPlayer): Int {
        val disabled = p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
        if (disabled) return 0
        var idx = 0
        for (group in p.currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_TEXT) {
                for (i in 0 until group.length) {
                    if (group.isTrackSelected(i)) return idx + 1
                    idx++
                }
            }
        }
        return 0
    }

    private fun selectAudioTrack(trackIndex: Int) {
        val p = player ?: return; var idx = 0
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_AUDIO) { for (i in 0 until group.length) {
            if (idx == trackIndex) {
                // When in Cast Source mode, we disable the track renderer to avoid TV audio leaks,
                // but we MUST apply the track selection override so the underlying decoder
                // state is correct (for status reporting and eventual restoration when we
                // switch back to TV audio).
                p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, listOf(i)))
                    .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, isCastSourceAudio)
                    .build()

                if (isCastSourceAudio) {
                    // Update our authoritative track index. Flutter will read this from
                    // activeAudioTrack in the next status push and switch the phone audio.
                    castAudioTrackIndex = trackIndex
                } else {
                    // Flush the audio renderer with a micro-seek to avoid MediaCodec errors
                    // (especially with DD+/EAC3 codecs).
                    mainHandler.postDelayed({
                        player?.let { q ->
                            if (q.playbackState == Player.STATE_READY) {
                                q.seekTo(q.currentPosition)
                            }
                        }
                    }, 80)
                }

                val suffix = if (isCastSourceAudio) " → Phone" else ""
                showActionBrief(audioIcon(ACCENT, 24), "Audio ${trackIndex + 1}$suffix")
                // Push immediately so Flutter receives the new activeAudioTrack and
                // calls _switchLocalAudioTrack on the phone side without delay.
                pushCastStatusToFlutter()
                return
            }
            idx++
        }}}
    }

    private fun selectSubtitleTrack(trackIndex: Int) {
        val p = player ?: return; var idx = 0
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_TEXT) { for (i in 0 until group.length) {
            if (idx == trackIndex) { p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, listOf(i))).build(); showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle ${trackIndex + 1}"); return }
            idx++
        }}}
    }

    private fun disableSubtitles() {
        player?.trackSelectionParameters = player!!.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
        showActionBrief(subtitleIcon(ACCENT, 24), "Subtitles Off")
    }

    // ═════════════════════════════════════════════════════════════════════════
    // D-pad / Keyboard
    // ═════════════════════════════════════════════════════════════════════════

    // ══════════════════════════════════════════════════════════════════════════
    // Key dispatch — intercept before views consume events (required for TV remote)
    // ══════════════════════════════════════════════════════════════════════════

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when {
                // Exit overlay: only intercept BACK; all other keys go to focused buttons
                isExitShowing -> if (event.keyCode == KeyEvent.KEYCODE_BACK) { dismissExitOverlay(); return true }
                // Speed menu: intercept all navigation before any view processes it
                speedMenu.visibility == View.VISIBLE -> if (handleSpeedMenuKey(event.keyCode)) return true
                // Settings panel: intercept so remote OK navigates menu instead of triggering background UI
                menuVisible -> if (handleMenuKey(event.keyCode)) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        // If exit overlay is showing let button focus/click navigate normally
        if (isExitShowing) return super.onKeyDown(keyCode, event)
        if (speedMenu.visibility == View.VISIBLE) return handleSpeedMenuKey(keyCode) || super.onKeyDown(keyCode, event)
        if (menuVisible) return handleMenuKey(keyCode) || super.onKeyDown(keyCode, event)

        // ── D-pad left/right ──
        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
            if (!controlsVisible) {
                // Controls hidden: skip 10s with indicator only, no controls shown
                val delta = if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 10_000L else -10_000L
                handleSeekKeyQuiet(delta)
                return true
            }
            // Controls visible: if focused on seek bar, seek; otherwise navigate focus
            if (currentFocus == seekBar) {
                val delta = if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 10_000L else -10_000L
                handleSeekKey(delta)
                return true
            }
            scheduleHideControls()
            return moveFocusOrNudge(keyCode, consumeWhenTv = true)
        }

        // ── D-pad up/down: always navigate ──
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
            if (!controlsVisible) {
                showControls(); scheduleHideControls()
                playPauseBtn.requestFocus()
                return true
            }
            scheduleHideControls()
            return moveFocusOrNudge(keyCode, consumeWhenTv = true)
        }

        // Show controls for OK/Enter and other keys
        val wasControlsHidden = !controlsVisible
        if (!controlsVisible) { showControls(); scheduleHideControls() }

        // ── OK / Enter / Space ──
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER
            || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER || keyCode == KeyEvent.KEYCODE_SPACE) {
            if (wasControlsHidden) { togglePlayPause(); return true }
            currentFocus?.let { if (it != rootLayout && it.performClick()) return true }
            togglePlayPause(); return true
        }

        return when (keyCode) {
            KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_SETTINGS -> { openMainMenu(); true }
            KeyEvent.KEYCODE_MEDIA_PLAY -> { player?.play(); true }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { player?.pause(); true }
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { togglePlayPause(); true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { handleSeekKey(10_000L); true }
            KeyEvent.KEYCODE_MEDIA_REWIND -> { handleSeekKey(-10_000L); true }
            KeyEvent.KEYCODE_MEDIA_STOP -> { showExitConfirmDialog(); true }
            KeyEvent.KEYCODE_BACK -> handleBackPress()
            KeyEvent.KEYCODE_A -> { cycleAudioTrack(); true }
            KeyEvent.KEYCODE_S -> { cycleSubtitleTrack(); true }
            KeyEvent.KEYCODE_M -> { openMainMenu(); true }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    private fun handleSeekKeyCommon(deltaMs: Long, quiet: Boolean) {
        mainHandler.removeCallbacks(seekResetRunnable)
        if (!isSeeking) {
            isSeeking = true
            seekTargetPosition = player?.currentPosition ?: 0L
        }
        seekAccumulated += deltaMs
        seekTargetPosition = (seekTargetPosition + deltaMs).coerceIn(0, duration.coerceAtLeast(1))
        isQuietSeeking = quiet

        // Show accumulated seek amount
        val totalSec = seekAccumulated / 1000
        val prefix = if (seekAccumulated >= 0) "+" else ""
        val icon = if (seekAccumulated >= 0) forwardIcon(ACCENT, 24) else rewindIcon(ACCENT, 24)
        showActionBrief(icon, "${prefix}${totalSec}s")

        // Update UI progress in real-time
        if (duration > 0) {
            seekBar.progress = (seekTargetPosition * 1000 / duration).toInt().coerceIn(0, 1000)
            positionText.text = formatTime(seekTargetPosition)
        }

        if (!quiet && !controlsVisible) {
            controlsVisible = true
            fadeViews(1f, topBar, topGradient, bottomBar, bottomGradient, centerRow)
        }

        // Debounce to detect when user stops pressing/holding the key
        mainHandler.postDelayed(seekResetRunnable, 400)
    }

    /** VLC/Netflix-style seek: accumulates seeks while key is held, shows total, commits on release */
    private fun handleSeekKey(deltaMs: Long) {
        handleSeekKeyCommon(deltaMs, false)
    }

    /** Quiet seek: skip without showing controls overlay, only show indicator */
    private fun handleSeekKeyQuiet(deltaMs: Long) {
        handleSeekKeyCommon(deltaMs, true)
    }

    private fun finishSeekBurst() {
        val wasQuiet = isQuietSeeking
        val targetPos = seekTargetPosition
        seekAccumulated = 0L
        isSeeking = false
        isQuietSeeking = false

        // Commit a single seek operation when D-pad is released
        player?.let {
            it.seekTo(targetPos)
            if (isCastActive) pushCastStatusToFlutter()
        }

        if (!wasQuiet) scheduleHideControls()
    }

    private fun handleMenuKey(keyCode: Int): Boolean {
        val n = menuItems.size
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> { menuSelectedIndex = (menuSelectedIndex - 1 + n) % n; menuAdapter.setItems(menuItems, menuSelectedIndex); menuListView.setSelection(menuSelectedIndex); return true }
            KeyEvent.KEYCODE_DPAD_DOWN -> { menuSelectedIndex = (menuSelectedIndex + 1) % n; menuAdapter.setItems(menuItems, menuSelectedIndex); menuListView.setSelection(menuSelectedIndex); return true }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                if (currentMenuType == MENU_SUBTITLE) {
                    if (menuSelectedIndex == 1) {
                        cycleSubtitleTrackCarousel(next = keyCode == KeyEvent.KEYCODE_DPAD_RIGHT)
                        return true
                    }
                    val extrasStart = 2
                    when (menuSelectedIndex) {
                        extrasStart -> { cycleSubtitleColor(); return true }
                        extrasStart + 1 -> { cycleSubtitleBg(); return true }
                        extrasStart + 2 -> { cycleSubtitleSize(); return true }
                        extrasStart + 3 -> { cycleSubtitlePos(); return true }
                    }
                }
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> { onMenuItemClicked(menuSelectedIndex); return true }
            KeyEvent.KEYCODE_BACK -> { when (currentMenuType) { MENU_AUDIO, MENU_SUBTITLE, MENU_AUDIO_DEVICE -> openMainMenu(); else -> closeMenu() }; return true }
        }
        return false
    }

    private fun cycleSubtitleTrackCarousel(next: Boolean) {
        if (subtitleTrackOptions.isEmpty()) {
            subtitleTrackOptions = listOf("Off")
            subtitleTrackIndex = 0
        }
        val total = subtitleTrackOptions.size
        subtitleTrackIndex = (subtitleTrackIndex + if (next) 1 else -1 + total) % total
        if (subtitleTrackIndex == 0) {
            disableSubtitles()
        } else {
            selectSubtitleTrack(subtitleTrackIndex - 1)
        }
        refreshSubtitleMenuOptions()
        menuAdapter.setItems(menuItems, menuSelectedIndex)
        menuListView.setSelection(menuSelectedIndex)
    }

    private fun handleBackPress(): Boolean {
        when {
            menuOverlay.visibility == View.VISIBLE || menuVisible -> { closeMenu(); return true }
            speedMenu.visibility == View.VISIBLE -> { speedMenu.visibility = View.GONE; scheduleHideControls(); return true }
            isExitShowing -> { dismissExitOverlay(); return true }
            isLocked -> { return true }
            controlsVisible -> { hideControls(); return true }
            else -> { showExitConfirmDialog(); return true }
        }
    }

    private fun moveFocusOrNudge(keyCode: Int, consumeWhenTv: Boolean = false): Boolean {
        val direction = when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT -> View.FOCUS_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> View.FOCUS_RIGHT
            KeyEvent.KEYCODE_DPAD_UP -> View.FOCUS_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> View.FOCUS_DOWN
            else -> return false
        }
        val anchor = currentFocus ?: playPauseBtn
        val next = anchor.focusSearch(direction)
        if (next != null && next != anchor && next != rootLayout) {
            next.requestFocus()
            return true
        }
        return consumeWhenTv
    }

    private fun handleSpeedMenuKey(keyCode: Int): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> {
                speedMenuSelectedIndex = (speedMenuSelectedIndex - 1 + speedOptions.size) % speedOptions.size
                refreshSpeedMenu(); return true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                speedMenuSelectedIndex = (speedMenuSelectedIndex + 1) % speedOptions.size
                refreshSpeedMenu(); return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                setPlaybackSpeed(speedOptions[speedMenuSelectedIndex]); speedMenu.visibility = View.GONE; scheduleHideControls(); return true
            }
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_LEFT -> { speedMenu.visibility = View.GONE; scheduleHideControls(); return true }
        }
        return false
    }

    private fun adjustVolume(delta: Float) {
        if (isCastSourceAudio) {
            showActionBrief(audioIcon(ACCENT, 24), "Audio on Cast Source")
            return
        }
        player?.let {
            currentVolume = (it.volume + delta).coerceIn(0f, 1f); it.volume = currentVolume; showVolumeOvl()
            mainHandler.removeCallbacksAndMessages("volHide")
            mainHandler.postDelayed({ volumeOverlay.visibility = View.GONE }, "volHide", 1500)
            pushCastStatusToFlutter()
        }
    }

    private fun cycleAudioTrack() {
        val p = player ?: return
        val audioGroups = mutableListOf<Pair<Tracks.Group, Int>>()
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_AUDIO) { for (i in 0 until group.length) audioGroups.add(Pair(group, i)) } }
        if (audioGroups.isEmpty()) { showActionBrief(audioIcon(ACCENT, 24), "No audio tracks"); return }
        // In cast-source mode, isTrackSelected() returns false for all tracks because the
        // audio renderer is disabled. Use castAudioTrackIndex as the authoritative current track.
        val cur = if (isCastSourceAudio) castAudioTrackIndex
                  else audioGroups.indexOfFirst { it.first.isTrackSelected(it.second) }.takeIf { it >= 0 } ?: 0
        val next = (cur + 1) % audioGroups.size; val (ng, nt) = audioGroups[next]
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(ng.mediaTrackGroup, listOf(nt)))
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, isCastSourceAudio)
            .build()
        if (isCastSourceAudio) {
            castAudioTrackIndex = next
        } else {
            // Flush renderer to avoid EAC3/DD+ codec errors after track switch
            mainHandler.postDelayed({
                player?.let { q -> if (q.playbackState == Player.STATE_READY) q.seekTo(q.currentPosition) }
            }, 80)
        }
        val suffix = if (isCastSourceAudio) " → Phone" else ""
        showActionBrief(audioIcon(ACCENT, 24), "Audio ${next + 1}/${audioGroups.size}$suffix")
        // Push immediately so Flutter receives the new activeAudioTrack and mirrors it on phone
        pushCastStatusToFlutter()
    }

    private fun cycleSubtitleTrack() {
        val p = player ?: return
        val subGroups = mutableListOf<Pair<Tracks.Group, Int>>()
        for (group in p.currentTracks.groups) { if (group.type == C.TRACK_TYPE_TEXT) { for (i in 0 until group.length) subGroups.add(Pair(group, i)) } }
        val disabled = p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
        if (subGroups.isEmpty()) { if (disabled) showActionBrief(subtitleIcon(ACCENT, 24), "No subtitles") else disableSubtitles(); return }
        if (disabled) {
            val (g, t) = subGroups[0]; p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, listOf(t))).build()
            showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle 1/${subGroups.size}")
        } else {
            val cur = subGroups.indexOfFirst { it.first.isTrackSelected(it.second) }
            if (cur == subGroups.size - 1 || cur == -1) disableSubtitles() else {
                val (ng, nt) = subGroups[cur + 1]; p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(ng.mediaTrackGroup, listOf(nt))).build()
                showActionBrief(subtitleIcon(ACCENT, 24), "Subtitle ${cur + 2}/${subGroups.size}")
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Cast / Remote Control (MethodChannel relay — no UDP socket)
    // ═════════════════════════════════════════════════════════════════════════

    private fun pushCastStatusToFlutter() {
        if (!isCastActive) return
        val payload = getStatusForDart()
        try {
            mainHandler.post {
                try { castRelay?.invokeMethod("statusChanged", payload) } catch (e: Exception) {
                    android.util.Log.w("NativeVideoPlayer", "Cast status push failed", e)
                }
            }
        } catch (_: Exception) {}
    }

    /**
     * Explicitly abandon Android audio focus so another app/player (media_kit on the phone)
     * can claim it. Called when entering Cast Source mode.
     */
    private fun releaseAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            // setAudioAttributes(_, false) above is the primary mechanism — ExoPlayer uses it
            // to abandon focus it holds internally. As belt-and-suspenders for older ROMs,
            // we also set the stream volume change flag so the system re-evaluates focus.
            // Note: abandonAudioFocus(null) is a no-op on API 26+ so we skip it.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // On API 26+ ExoPlayer's setAudioAttributes(_, false) is sufficient.
                // Nothing more to do here — just log.
                android.util.Log.d("NativeVideoPlayer", "Audio focus surrendered via setAudioAttributes")
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
                android.util.Log.d("NativeVideoPlayer", "Audio focus released (legacy API)")
            }
        } catch (e: Exception) {
            android.util.Log.w("NativeVideoPlayer", "Error releasing audio focus: ${e.message}")
        }
    }

    /**
     * Request Android audio focus back for ExoPlayer after leaving Cast Source mode.
     */
    private fun requestAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val req = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(true)
                    .setOnAudioFocusChangeListener { }
                    .build()
                audioFocusRequest = req
                val result = am.requestAudioFocus(req)
                android.util.Log.d("NativeVideoPlayer", "Audio focus requested: $result")
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
                android.util.Log.d("NativeVideoPlayer", "Audio focus requested (legacy)")
            }
        } catch (e: Exception) {
            android.util.Log.w("NativeVideoPlayer", "Error requesting audio focus: ${e.message}")
        }
    }

    private fun initCast() {
        castControllerIp = intent.getStringExtra(EXTRA_CAST_CONTROLLER_IP)
        if (castControllerIp.isNullOrEmpty()) return
        isCastActive = true
        activeInstance = this
        android.util.Log.d("NativeVideoPlayer", "Cast relay active, controller=$castControllerIp")
    }

    private fun stopCast() {
        if (isCastActive) {
            // Push one last status with active=false so the sender knows immediately.
            // Converting to mutable map so we can override the active field.
            val payload = getStatusForDart().toMutableMap()
            payload["active"] = false
            try {
                mainHandler.post {
                    try { castRelay?.invokeMethod("statusChanged", payload) } catch (_: Exception) {}
                }
            } catch (_: Exception) {}
        }
        isCastActive = false
        if (activeInstance == this) activeInstance = null
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Result / finish
    // ═════════════════════════════════════════════════════════════════════════

    private fun finishWithPosition() {
        try { setResult(RESULT_OK, Intent().apply { putExtra(RESULT_POSITION, player?.currentPosition ?: 0L) }) }
        catch (_: Exception) { setResult(RESULT_OK, Intent().apply { putExtra(RESULT_POSITION, 0L) }) }
        finish()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) { @Suppress("DEPRECATION") overridePendingTransition(0, android.R.anim.fade_out) }
    }

    private fun showExitConfirmDialog() {
        if (isExitShowing) return
        val overlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            setBackgroundColor(0x99000000.toInt())
            setOnClickListener { /* consume — only buttons dismiss */ }
        }
        exitOverlay = overlay

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply { setColor(0xFF15171C.toInt()); cornerRadius = dpf(16); setStroke(dp(1), 0x33FFFFFF) }
            layoutParams = FrameLayout.LayoutParams(dp(300), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
            setPadding(dp(24), dp(24), dp(24), dp(20)); elevation = dpf(24)
        }
        card.addView(TextView(this).apply {
            text = "Exit Player?"; setTextColor(Color.WHITE); textSize = 18f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.bottomMargin = dp(10) }
        })
        card.addView(TextView(this).apply {
            text = "Are you sure you want to quit playback?"; setTextColor(0xCCFFFFFF.toInt()); textSize = 14f
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.bottomMargin = dp(20) }
        })
        val btnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        val cancelBtnId = View.generateViewId(); val exitBtnId = View.generateViewId()
        val cancelBtn = TextView(this).apply {
            id = cancelBtnId; text = "Cancel"; setTextColor(0xCCFFFFFF.toInt()); textSize = 14f; gravity = Gravity.CENTER
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = roundedBg(0x22FFFFFF, 10); setPadding(dp(20), dp(12), dp(20), dp(12))
            isFocusable = true; isFocusableInTouchMode = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.marginEnd = dp(12) }
            nextFocusRightId = exitBtnId
            setOnClickListener { dismissExitOverlay() }
            onFocusChangeListener = View.OnFocusChangeListener { v, f -> v.background = if (f) roundedBg(0x44FFFFFF, 10) else roundedBg(0x22FFFFFF, 10) }
        }
        val exitBtn = TextView(this).apply {
            id = exitBtnId; text = "Exit"; setTextColor(Color.BLACK); textSize = 14f; gravity = Gravity.CENTER
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            background = roundedBg(ACCENT, 10); setPadding(dp(20), dp(12), dp(20), dp(12))
            isFocusable = true; isFocusableInTouchMode = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            nextFocusLeftId = cancelBtnId
            setOnClickListener { finishWithPosition() }
            onFocusChangeListener = View.OnFocusChangeListener { v, f -> v.background = if (f) roundedBg(0xFFFFE066.toInt(), 10) else roundedBg(ACCENT, 10) }
        }
        btnRow.addView(cancelBtn); btnRow.addView(exitBtn)
        card.addView(btnRow); overlay.addView(card); rootLayout.addView(overlay)

        // Animate: fade-in overlay + scale-up card
        overlay.alpha = 0f; overlay.animate().alpha(1f).setDuration(180).start()
        card.scaleX = 0.92f; card.scaleY = 0.92f
        card.animate().scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(DecelerateInterpolator(1.5f)).start()
        cancelBtn.post { cancelBtn.requestFocus() }  // default focus on Cancel for safe TV navigation
    }

    private fun dismissExitOverlay() {
        val ov = exitOverlay ?: return
        ov.animate().alpha(0f).setDuration(150).withEndAction {
            rootLayout.removeView(ov)
            if (exitOverlay === ov) exitOverlay = null
        }.start()
    }

    private fun showFatalError(message: String) {
        try { player?.stop(); player?.release(); player = null } catch (_: Exception) {}
        try { loadingSpinner.visibility = View.GONE } catch (_: Exception) {}
        if (!::rootLayout.isInitialized) {
            val f = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }; setContentView(f)
            f.addView(TextView(this).apply { text = "⚠️ $message\n\nPress BACK to return."; setTextColor(Color.WHITE); textSize = 18f; setPadding(48, 48, 48, 48); gravity = Gravity.CENTER; layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT) })
            f.setOnClickListener { finishWithPosition() }; return
        }
        val overlay = FrameLayout(this).apply { setBackgroundColor(0xEE000000.toInt()); layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT) }
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER); setPadding(dp(40), dp(40), dp(40), dp(40)) }
        col.addView(TextView(this).apply { text = "⚠️"; textSize = 48f; gravity = Gravity.CENTER; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.bottomMargin = dp(16) } })
        col.addView(TextView(this).apply { text = "Playback Error"; setTextColor(ACCENT); textSize = 20f; typeface = Typeface.create("sans-serif-medium", Typeface.BOLD); gravity = Gravity.CENTER; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.bottomMargin = dp(12) } })
        col.addView(TextView(this).apply { text = message; setTextColor(0xCCFFFFFF.toInt()); textSize = 14f; gravity = Gravity.CENTER; maxLines = 10; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).also { it.bottomMargin = dp(24) } })
        col.addView(TextView(this).apply { text = "Go Back"; setTextColor(Color.BLACK); textSize = 14f; typeface = Typeface.create("sans-serif-medium", Typeface.BOLD); gravity = Gravity.CENTER; setPadding(dp(24), dp(12), dp(24), dp(12)); background = roundedBg(ACCENT, 8); isFocusable = true; setOnClickListener { finishWithPosition() } })
        overlay.addView(col); overlay.setOnClickListener { finishWithPosition() }; rootLayout.addView(overlay)
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Menu Adapter
    // ═════════════════════════════════════════════════════════════════════════

    inner class NativeMenuAdapter(context: Context) : BaseAdapter() {
        private var items = listOf<String>()
        private var selectedIndex = 0
        fun setItems(newItems: List<String>, sel: Int) { items = newItems; selectedIndex = sel; notifyDataSetChanged() }
        override fun getCount() = items.size
        override fun getItem(pos: Int) = items[pos]
        override fun getItemId(pos: Int) = pos.toLong()
        override fun getView(pos: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(parent.context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = AbsListView.LayoutParams(AbsListView.LayoutParams.MATCH_PARENT, AbsListView.LayoutParams.WRAP_CONTENT)
                setPadding(dp(2), dp(4), dp(2), dp(4))
            }
            val tv = if (row.childCount == 0) TextView(parent.context).also { row.addView(it) } else row.getChildAt(0) as TextView
            tv.text = items[pos]
            tv.textSize = 14f
            tv.isFocusable = false
            tv.setPadding(dp(18), dp(14), dp(18), dp(14))

            val isSel = pos == selectedIndex
            if (isSel) {
                tv.setTextColor(BG_DARK)
                tv.background = roundedBg(ACCENT, 10)
                tv.typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                tv.animate().translationX(dp(6).toFloat()).setDuration(120).start()
            } else {
                tv.setTextColor(Color.WHITE)
                tv.background = roundedBg(0x26FFFFFF, 10)
                tv.typeface = Typeface.DEFAULT
                tv.animate().translationX(0f).setDuration(120).start()
            }
            return row
        }
    }
}

