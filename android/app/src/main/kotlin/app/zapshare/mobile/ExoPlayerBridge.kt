package app.zapshare.mobile

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.*
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.PlaybackException
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.MimeTypes
import androidx.media3.common.text.Cue
import io.flutter.view.TextureRegistry
import androidx.media3.exoplayer.DefaultRenderersFactory

/**
 * Native ExoPlayer bridge for Flutter with full subtitle/audio track support.
 * Uses Flutter TextureRegistry to render video frames to a Flutter Texture widget.
 *
 * MethodChannel: zapshare.exoplayer
 * EventChannel:  zapshare.exoplayer.events
 */
@UnstableApi
class ExoPlayerBridge(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val methodChannel: MethodChannel,
    private val eventChannel: EventChannel
) : MethodChannel.MethodCallHandler {

    private var player: ExoPlayer? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var positionUpdateRunnable: Runnable? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> create(result)
                "open" -> {
                    val source = call.argument<String>("source")!!
                    val subtitlePath = call.argument<String>("subtitlePath")
                    open(source, subtitlePath, result)
                }
                "play" -> { player?.play(); result.success(null) }
                "pause" -> { player?.pause(); result.success(null) }
                "playOrPause" -> {
                    player?.let {
                        if (it.isPlaying) it.pause() else it.play()
                    }
                    result.success(null)
                }
                "seekTo" -> {
                    val position = call.argument<Number>("position")!!.toLong()
                    player?.seekTo(position)
                    result.success(null)
                }
                "setSpeed" -> {
                    val speed = call.argument<Number>("speed")!!.toFloat()
                    player?.setPlaybackSpeed(speed)
                    result.success(null)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")!!.toFloat()
                    player?.volume = volume
                    result.success(null)
                }
                "getSubtitleTracks" -> result.success(getSubtitleTracks())
                "getAudioTracks" -> result.success(getAudioTracks())
                "selectSubtitleTrack" -> {
                    val index = call.argument<Int>("index")!!
                    selectSubtitleTrack(index)
                    result.success(null)
                }
                "selectAudioTrack" -> {
                    val index = call.argument<Int>("index")!!
                    selectAudioTrack(index)
                    result.success(null)
                }
                "disableSubtitles" -> {
                    disableSubtitles()
                    result.success(null)
                }
                "enableSubtitles" -> {
                    enableSubtitles()
                    result.success(null)
                }
                "dispose" -> {
                    dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("EXOPLAYER_ERROR", e.message, e.stackTraceToString())
        }
    }

    private fun create(result: MethodChannel.Result) {
        android.util.Log.d("ExoPlayerBridge", "Creating player")

        textureEntry = textureRegistry.createSurfaceTexture()
        val st = textureEntry!!.surfaceTexture()
        st.setDefaultBufferSize(1920, 1080)
        surface = Surface(st)

        // Create custom LoadControl for smoother playback
        val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                50000,  // minBufferMs
                100000, // maxBufferMs
                2500,   // bufferForPlaybackMs
                5000    // bufferForPlaybackAfterRebufferMs
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .setBackBuffer(15000, true)
            .build()

        // Configure TrackSelector - keep it simple, let ExoPlayer pick optimal tracks
        val trackSelector = androidx.media3.exoplayer.trackselection.DefaultTrackSelector(context)
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setForceLowestBitrate(false)
            .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
            .setAllowVideoMixedMimeTypeAdaptiveness(true)
            .setAllowAudioMixedMimeTypeAdaptiveness(true)
            .build()

        // Create RenderersFactory - enable decoder fallback for compatibility
        val renderersFactory = DefaultRenderersFactory(context).apply {
            setEnableDecoderFallback(true)
            setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
        }

        // Create ExoPlayer
        player = ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            .setTrackSelector(trackSelector)
            .setRenderersFactory(renderersFactory)
            .build()
            .apply {
                setVideoSurface(surface)
                setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
                
                // Don't auto-play until open() is called
                playWhenReady = false

                addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(state: Int) {
                        val stateName = when (state) {
                            Player.STATE_IDLE -> "idle"
                            Player.STATE_BUFFERING -> "buffering"
                            Player.STATE_READY -> "ready"
                            Player.STATE_ENDED -> "ended"
                            else -> "unknown"
                        }
                        
                        sendEvent(mapOf(
                            "event" to "playbackState",
                            "state" to stateName
                        ))

                        // Send buffering state
                        sendEvent(mapOf(
                            "event" to "isBuffering",
                            "value" to (state == Player.STATE_BUFFERING)
                        ))

                        // Send completed state
                        if (state == Player.STATE_ENDED) {
                            sendEvent(mapOf("event" to "completed", "value" to true))
                        }
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        sendEvent(mapOf("event" to "isPlaying", "value" to isPlaying))
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        sendEvent(mapOf(
                            "event" to "error",
                            "message" to (error.message ?: "Unknown playback error"),
                            "code" to error.errorCode
                        ))
                    }

                    override fun onTracksChanged(tracks: Tracks) {
                        // Notify Flutter about available tracks
                        sendEvent(mapOf(
                            "event" to "tracksChanged",
                            "subtitles" to getSubtitleTracks(),
                            "audio" to getAudioTracks()
                        ))
                    }

                    override fun onCues(cues: MutableList<Cue>) {
                        val text = StringBuilder()
                        for (cue in cues) {
                            cue.text?.let {
                                if (text.isNotEmpty()) text.append("\n")
                                text.append(it)
                            }
                        }
                        sendEvent(mapOf(
                            "event" to "caption",
                            "value" to text.toString()
                        ))
                    }

                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        if (videoSize.width > 0 && videoSize.height > 0) {
                            try {
                                textureEntry?.surfaceTexture()?.setDefaultBufferSize(
                                    videoSize.width, videoSize.height
                                )
                                android.util.Log.d("ExoPlayerBridge",
                                    "SurfaceTexture buffer sized to ${videoSize.width}x${videoSize.height}")
                            } catch (e: Exception) {
                                android.util.Log.w("ExoPlayerBridge", "Failed to resize buffer: ${e.message}")
                            }
                        }
                        
                        sendEvent(mapOf(
                            "event" to "videoSize",
                            "width" to videoSize.width,
                            "height" to videoSize.height
                        ))
                    }

                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        // Duration is available after media item loaded
                        this@apply.let { p ->
                            if (p.duration > 0) {
                                sendEvent(mapOf(
                                    "event" to "duration",
                                    "value" to p.duration
                                ))
                            }
                        }
                    }
                })
            }

        // Start position polling (every 500ms to minimize Flutter event overhead)
        startPositionUpdates(500L)

        result.success(mapOf("textureId" to textureEntry!!.id()))
    }

    private fun open(source: String, subtitlePath: String?, result: MethodChannel.Result) {
        val p = player ?: run {
            result.error("NO_PLAYER", "Player not created", null)
            return
        }

        val uri = if (source.startsWith("http://") || source.startsWith("https://")) {
            Uri.parse(source)
        } else if (source.startsWith("content://")) {
            Uri.parse(source)
        } else {
            // Local file path
            Uri.parse("file://$source")
        }

        val builder = MediaItem.Builder().setUri(uri)

        // Add external subtitle if provided
        if (subtitlePath != null && subtitlePath.isNotEmpty()) {
            val subtitleUri = if (subtitlePath.startsWith("content://") || subtitlePath.startsWith("http")) {
                Uri.parse(subtitlePath)
            } else {
                Uri.parse("file://$subtitlePath")
            }

            // Detect subtitle MIME type from extension
            val mimeType = when {
                subtitlePath.endsWith(".srt", ignoreCase = true) -> MimeTypes.APPLICATION_SUBRIP
                subtitlePath.endsWith(".vtt", ignoreCase = true) -> MimeTypes.TEXT_VTT
                subtitlePath.endsWith(".ass", ignoreCase = true) || 
                    subtitlePath.endsWith(".ssa", ignoreCase = true) -> MimeTypes.TEXT_SSA
                subtitlePath.endsWith(".ttml", ignoreCase = true) -> MimeTypes.APPLICATION_TTML
                else -> MimeTypes.APPLICATION_SUBRIP
            }

            val subtitleConfig = MediaItem.SubtitleConfiguration.Builder(subtitleUri)
                .setMimeType(mimeType)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .build()

            builder.setSubtitleConfigurations(listOf(subtitleConfig))
        }

        p.setMediaItem(builder.build())
        p.prepare()
        p.playWhenReady = true

        result.success(null)
    }

    private fun getSubtitleTracks(): List<Map<String, Any?>> {
        val tracks = mutableListOf<Map<String, Any?>>()
        val currentTracks = player?.currentTracks ?: return tracks

        for (group in currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_TEXT) {
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    tracks.add(mapOf(
                        "index" to tracks.size,
                        "id" to (format.id ?: "sub_${tracks.size}"),
                        "label" to (format.label ?: "Subtitle ${tracks.size + 1}"),
                        "language" to (format.language ?: "und"),
                        "isSelected" to group.isTrackSelected(i)
                    ))
                }
            }
        }
        return tracks
    }

    private fun getAudioTracks(): List<Map<String, Any?>> {
        val tracks = mutableListOf<Map<String, Any?>>()
        val currentTracks = player?.currentTracks ?: return tracks

        for (group in currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_AUDIO) {
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    val label = format.label 
                        ?: format.language?.let { "Audio ($it)" }
                        ?: "Audio ${tracks.size + 1}"
                    tracks.add(mapOf(
                        "index" to tracks.size,
                        "id" to (format.id ?: "audio_${tracks.size}"),
                        "label" to label,
                        "language" to (format.language ?: "und"),
                        "channels" to format.channelCount,
                        "bitrate" to format.bitrate,
                        "isSelected" to group.isTrackSelected(i)
                    ))
                }
            }
        }
        return tracks
    }

    private fun selectSubtitleTrack(trackIndex: Int) {
        val p = player ?: return
        val currentTracks = p.currentTracks

        // First, re-enable text tracks if they were disabled
        var params = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)

        var idx = 0
        for (group in currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_TEXT) {
                for (trackInGroup in 0 until group.length) {
                    if (idx == trackIndex) {
                        params = params.setOverrideForType(
                            TrackSelectionOverride(group.mediaTrackGroup, listOf(trackInGroup))
                        )
                        p.trackSelectionParameters = params.build()
                        return
                    }
                    idx++
                }
            }
        }
    }

    private fun selectAudioTrack(trackIndex: Int) {
        val p = player ?: return
        val currentTracks = p.currentTracks

        var idx = 0
        for (group in currentTracks.groups) {
            if (group.type == C.TRACK_TYPE_AUDIO) {
                for (trackInGroup in 0 until group.length) {
                    if (idx == trackIndex) {
                        p.trackSelectionParameters = p.trackSelectionParameters
                            .buildUpon()
                            .setOverrideForType(
                                TrackSelectionOverride(group.mediaTrackGroup, listOf(trackInGroup))
                            )
                            .build()
                        return
                    }
                    idx++
                }
            }
        }
    }

    private fun disableSubtitles() {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
    }

    private fun enableSubtitles() {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .build()
    }

    private fun startPositionUpdates(intervalMs: Long = 250L) {
        positionUpdateRunnable = object : Runnable {
            override fun run() {
                player?.let { p ->
                    if (p.playbackState != Player.STATE_IDLE) {
                        sendEvent(mapOf(
                            "event" to "position",
                            "position" to p.currentPosition,
                            "duration" to p.duration.coerceAtLeast(0),
                            "buffered" to p.bufferedPosition
                        ))
                    }
                }
                mainHandler.postDelayed(this, intervalMs)
            }
        }
        mainHandler.post(positionUpdateRunnable!!)
    }

    private fun sendEvent(data: Map<String, Any?>) {
        mainHandler.post {
            try {
                eventSink?.success(data)
            } catch (_: Exception) {
                // EventSink may be closed
            }
        }
    }

    fun dispose() {
        positionUpdateRunnable?.let { mainHandler.removeCallbacks(it) }
        positionUpdateRunnable = null
        player?.release()
        player = null
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        eventSink = null
    }
}
