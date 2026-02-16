import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit/src/player/native/player/player.dart' as native_player;
import 'package:window_manager/window_manager.dart';
import 'package:zap_share/services/device_discovery_service.dart';

/// Keyboard shortcut map for the video player (VLC-style)
/// Space/K: Play/Pause | Left/Right: Seek ±5s | Shift+Left/Right: Seek ±30s
/// Up/Down: Volume ±5% | M: Mute | F/F11: Fullscreen | Esc: Exit fullscreen
/// [/]: Speed -/+ 0.25x | S: Toggle subtitles | V: Cycle subtitles
/// B: Cycle audio tracks | 0-9: Seek to 0%-90%

/// A Netflix-style video player screen themed to ZapShare's dark/yellow brand.
/// Supports local files and network URLs, with subtitles, play/pause, seek,
/// double-tap ±10s, speed control, audio track switching, subtitle customization,
/// seek preview thumbnails, fullscreen toggle, and landscape mode.
class VideoPlayerScreenAndroid extends StatefulWidget {
  /// Either a local file path or a network URL.
  final String videoSource;

  /// Display title (filename by default).
  final String? title;

  /// Optional subtitle file path (supports .srt, .ass, .ssa, .vtt, etc.)
  final String? subtitlePath;

  /// If this is a cast session, the IP of the device that sent the cast URL.
  /// The player will send status updates back and accept remote control commands.
  final String? castControllerIp;

  const VideoPlayerScreenAndroid({
    super.key,
    required this.videoSource,
    this.title,
    this.subtitlePath,
    this.castControllerIp,
  });

  @override
  State<VideoPlayerScreenAndroid> createState() => _VideoPlayerScreenAndroidState();
}

class _VideoPlayerScreenAndroidState extends State<VideoPlayerScreenAndroid>
    with SingleTickerProviderStateMixin {
  late final Player _player;
  late final VideoController _videoController;

  // UI state
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _isBuffering = false;
  bool _isCompleted = false;
  double _playbackSpeed = 1.0;
  bool _showSpeedMenu = false;

  // Subtitle state
  bool _subtitlesEnabled = false;
  SubtitleTrack? _activeSubtitleTrack;
  List<SubtitleTrack> _subtitleTracks = [];

  // Audio track state
  AudioTrack? _activeAudioTrack;
  List<AudioTrack> _audioTracks = [];

  // Double-tap seek animation
  int? _doubleTapSide; // 0 = left (rewind), 1 = right (forward)
  Timer? _doubleTapResetTimer;

  // Locked?
  bool _locked = false;

  // Fullscreen
  bool _isFullscreen = false;
  bool _wasFullscreenOnWindows = false;

  // Seek preview
  bool _isSeeking = false;
  Duration _seekPreviewPosition = Duration.zero;

  // Subtitle customization
  double _subtitleFontSize = 32.0;
  Color _subtitleColor = Colors.white;
  Color _subtitleBgColor = const Color(0x99000000);
  String _subtitleFontFamily = 'Default';

  // Cast session (remote control)
  StreamSubscription<CastControl>? _castControlSub;
  Timer? _statusTimer;
  double _volume = 1.0;
  bool _isMuted = false;
  double _volumeBeforeMute = 1.0;

  // Error state
  bool _hasError = false;
  String? _errorMessage;
  int _retryCount = 0;
  static const _maxRetries = 3;

  // Keyboard focus
  final FocusNode _keyboardFocusNode = FocusNode();

  // VLC-like swipe gesture state (volume on left, brightness on right)
  bool _isVerticalDragging = false;
  int _swipeSide = -1; // 0 = left (volume), 1 = right (brightness)
  double _swipeStartY = 0;
  double _swipeStartValue = 0;
  bool _showSwipeVolumeOverlay = false;
  bool _showSwipeBrightnessOverlay = false;
  Timer? _swipeOverlayTimer;
  double _brightness = 0.5;

  // Position update throttle (reduces rebuilds → less frame jank)
  DateTime _lastPositionUpdate = DateTime.now();

  // Smoothed position for UI (avoids jitter from stream irregularity)
  Duration _displayPosition = Duration.zero;

  // ── Debug stats overlay (toggle with I key or stats button) ──
  bool _showStats = false;
  Timer? _statsTimer;
  Map<String, String> _stats = {};

  // ── Real-time log console (toggle with L key or log button) ──
  bool _showLogs = false;
  final List<_LogEntry> _logEntries = [];
  static const _maxLogEntries = 200;
  final ScrollController _logScrollController = ScrollController();

  static const _seekDuration = Duration(seconds: 10);
  static const _seekDurationSmall = Duration(seconds: 5);
  static const _seekDurationLarge = Duration(seconds: 30);
  static const _accentColor = Color(0xFFFFD600);
  static const _bgColor = Color(0xFF0C0C0E);

  // Subtitle color presets
  static final _subtitleColorPresets = <Map<String, dynamic>>[
    {'name': 'White', 'color': Colors.white},
    {'name': 'Yellow', 'color': const Color(0xFFFFD600)},
    {'name': 'Cyan', 'color': Colors.cyanAccent},
    {'name': 'Green', 'color': Colors.greenAccent},
    {'name': 'Pink', 'color': Colors.pinkAccent},
  ];

  static final _subtitleBgPresets = <Map<String, dynamic>>[
    {'name': 'Semi-Black', 'color': const Color(0x99000000)},
    {'name': 'Transparent', 'color': const Color(0x00000000)},
    {'name': 'Dark', 'color': const Color(0xCC000000)},
    {'name': 'Outline Only', 'color': const Color(0x33000000)},
  ];

  static const _fontFamilies = [
    'Default',
    'Roboto',
    'Outfit',
    'Monospace',
    'Serif',
  ];

  @override
  void initState() {
    super.initState();

    // Configure player with platform-appropriate buffering
    final _isAndroid = Platform.isAndroid;
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: _isAndroid
            ? 128 * 1024 * 1024  // 128 MB on Android (prevents rebuffer stalls)
            : 256 * 1024 * 1024, // 256 MB on Windows (handles large HDR/4K files)
        logLevel: MPVLogLevel.warn, // Only warnings/errors — info generates I/O every frame & steals CPU
      ),
    );
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // Listen to streams
    _player.stream.playing.listen((playing) {
      if (!mounted || _isPlaying == playing) return; // skip no-op
      _isPlaying = playing;
      setState(() {});
      _addLog('STATE', playing ? 'Playing' : 'Paused', playing ? _LogLevel.info : _LogLevel.warn);
    });
    _player.stream.position.listen((pos) {
      if (!mounted) return;
      _position = pos;
      // ── CRITICAL THROTTLE ──
      // Video frames render on a native texture completely independent of
      // Flutter. setState here only updates the seek-bar/time label.
      // Rebuilding less often = less GPU contention = smoother video.
      final now = DateTime.now();
      final elapsed = now.difference(_lastPositionUpdate).inMilliseconds;
      if (_isSeeking) {
        // During active seek, update immediately for responsiveness
        _displayPosition = pos;
        _lastPositionUpdate = now;
        setState(() {});
      } else if (_controlsVisible && elapsed > 500) {
        // Controls visible: update ~2× per second (slider looks smooth)
        _displayPosition = pos;
        _lastPositionUpdate = now;
        setState(() {});
      }
      // Controls hidden: NO setState at all — nothing visible needs updating.
      // This is the single biggest perf win: zero rebuilds during normal playback.
    });
    _player.stream.duration.listen((dur) {
      if (!mounted || _duration == dur) return;
      setState(() => _duration = dur);
    });
    _player.stream.buffer.listen((buf) {
      if (!mounted) return;
      final oldBuf = _buffered;
      _buffered = buf;
      // Only rebuild if controls visible AND buffer changed significantly (>1s)
      if (_controlsVisible && (buf - oldBuf).abs() > const Duration(seconds: 1)) {
        setState(() {});
      }
    });
    _player.stream.buffering.listen((buffering) {
      if (!mounted || _isBuffering == buffering) return;
      _isBuffering = buffering;
      setState(() {});
      _addLog('BUFFER', buffering ? 'Buffering started...' : 'Buffering ended',
          buffering ? _LogLevel.warn : _LogLevel.info);
    });
    _player.stream.completed.listen((completed) {
      if (mounted) {
        setState(() {
          _isCompleted = completed;
          if (completed) _controlsVisible = true;
        });
      }
    });
    _player.stream.tracks.listen((tracks) {
      if (mounted) {
        setState(() {
          _subtitleTracks = tracks.subtitle;
          _audioTracks = tracks.audio;
        });
        _addLog('TRACKS', 'Video: ${tracks.video.length}, Audio: ${tracks.audio.length}, Sub: ${tracks.subtitle.length}', _LogLevel.info);
      }
    });
    _player.stream.track.listen((track) {
      if (mounted) {
        setState(() {
          _activeSubtitleTrack = track.subtitle;
          _subtitlesEnabled =
              track.subtitle != SubtitleTrack.no() &&
              track.subtitle.id != 'no';
          _activeAudioTrack = track.audio;
        });
      }
    });

    // Listen for player errors
    _player.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        debugPrint('Player error: $error');
        _addLog('ERROR', error, _LogLevel.error);
        setState(() {
          _hasError = true;
          _errorMessage = error;
        });
        // Auto-retry for transient errors
        if (_retryCount < _maxRetries) {
          _retryCount++;
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _hasError) _retryPlayback();
          });
        }
      }
    });

    _openMedia();
    _startHideTimer();

    // Cast session: listen for remote control commands & send status
    if (widget.castControllerIp != null) {
      _initCastSession();
    }

    // Force landscape for better video experience on Android
    if (Platform.isAndroid) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Initialize screen brightness for VLC-like swipe gesture
    _initBrightness();
  }

  // ─── Cast session (remote control) ─────────────────────────

  void _initCastSession() {
    final discoveryService = DeviceDiscoveryService();
    final controllerIp = widget.castControllerIp!;

    // Listen for remote control commands from the sender
    _castControlSub = discoveryService.castControlStream.listen((control) {
      if (!mounted) return;
      switch (control.action) {
        case 'play':
          _player.play();
          break;
        case 'pause':
          _player.pause();
          break;
        case 'seek':
          if (control.seekPosition != null) {
            _player.seek(Duration(milliseconds: (control.seekPosition! * 1000).toInt()));
          }
          break;
        case 'volume':
          if (control.volume != null) {
            setState(() => _volume = control.volume!);
            _player.setVolume(control.volume! * 100); // media_kit volume is 0-100
          }
          break;
        case 'stop':
          Navigator.of(context).pop();
          break;
        case 'ping':
          // Respond immediately with current status
          _sendStatusNow(discoveryService, controllerIp);
          break;
      }
    });

    // Send status updates every second
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _sendStatusNow(discoveryService, controllerIp);
    });

    // Send an immediate status update so the sender's remote control connects fast
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _sendStatusNow(discoveryService, controllerIp);
    });
  }

  void _sendStatusNow(DeviceDiscoveryService discoveryService, String controllerIp) {
    discoveryService.sendCastStatus(
      controllerIp,
      position: _position.inMilliseconds / 1000.0,
      duration: _duration.inMilliseconds / 1000.0,
      buffered: _buffered.inMilliseconds / 1000.0,
      isPlaying: _isPlaying,
      isBuffering: _isBuffering,
      volume: _volume,
      fileName: widget.title,
    );
  }

  Future<void> _openMedia() async {
    final source = widget.videoSource;

    // ── Platform-optimized mpv configuration ──
    if (_player.platform is native_player.NativePlayer) {
      final np = _player.platform as native_player.NativePlayer;

      if (Platform.isAndroid) {
        // ═══ ANDROID: Maximum performance config ═══

        // Hardware decoding — mediacodec for zero-copy HW decode
        // (media_kit manages vo/gpu-context internally for Flutter texture)
        await np.setProperty('hwdec', 'mediacodec');
        await np.setProperty('hwdec-codecs', 'all');

        // Software fallback: if HW decoder fails, drop to SW gracefully
        await np.setProperty('vd-lavc-software-fallback', '60');

        // Minimal scaling — no GPU shaders on mobile
        await np.setProperty('scale', 'bilinear');
        await np.setProperty('dscale', 'bilinear');
        await np.setProperty('cscale', 'bilinear');

        // Audio-sync — the only mode that avoids all frame timing issues
        await np.setProperty('video-sync', 'audio');

        // Only VO-level frame drop (decoder drops cause visible stutter)
        await np.setProperty('framedrop', 'vo');

        // ── KEY: Large demuxer buffers + async cache for stutter-free playback ──
        await np.setProperty('demuxer-max-bytes', '150MiB');
        await np.setProperty('demuxer-max-back-bytes', '32MiB');
        await np.setProperty('demuxer-readahead-secs', '300');

        // Async cache layer — decouples I/O from decoder completely
        await np.setProperty('cache', 'yes');
        await np.setProperty('cache-secs', '120');
        await np.setProperty('cache-pause-initial', 'yes'); // Wait for initial cache fill to avoid stutter
        await np.setProperty('cache-pause-wait', '1');

        // Fast seeking
        await np.setProperty('hr-seek', 'yes');
        await np.setProperty('hr-seek-framedrop', 'yes');

        // Deinterlace auto
        await np.setProperty('deinterlace', 'auto');

        // Audio
        await np.setProperty('audio-pitch-correction', 'yes');
        await np.setProperty('audio-channels', 'auto-safe');

        // Performance — max decoder threads + direct rendering
        await np.setProperty('vd-lavc-threads', '0');
        await np.setProperty('vd-lavc-dr', 'yes');
        // NOTE: vd-lavc-fast removed — it skips spec-compliant decode steps
        // causing artifacts & frame timing issues. VLC never uses this.

        // NOTE: video-latency-hacks removed — it's for live streams only.
        // For VOD/file playback it breaks frame pacing.
        await np.setProperty('untimed', 'no');

      } else {
        // ═══ WINDOWS: Ultimate Performance Config ═══
        // Optimized for H.264/H.265 smoothness.
        // We use 'auto' instead of 'auto-copy' to let media_kit handle the texture binding
        // efficiently without forcing a round-trip to system memory if possible.

        // Hardware decoding - 'auto' is generally fastest.
        // If you see green artifacts, try 'd3d11va' or 'dxva2'.
        await np.setProperty('hwdec', 'auto'); 
        
        // Allow hardware decoding for all codecs
        await np.setProperty('hwdec-codecs', 'all');

        // VIDEO SYNC: 'display-resample' is the smoothest mode for mpv.
        // It resamples audio to match video framerate, eliminating 3:2 pulldown jank.
        await np.setProperty('video-sync', 'display-resample');
        await np.setProperty('interpolation', 'yes');
        await np.setProperty('tscale', 'oversample'); // High quality interpolation

        // SCALING: 'bilinear' is fastest, 'spline36' is good balance.
        // Using bilinear for maximum performance.
        await np.setProperty('scale', 'bilinear');
        await np.setProperty('dscale', 'bilinear');
        await np.setProperty('cscale', 'bilinear');

        // CACHE: Reduced cache sizes to prevent GC pauses. 
        // Large caches in Dart memory can cause "stop-the-world" stutters.
        await np.setProperty('cache', 'yes');
        await np.setProperty('demuxer-max-bytes', '64MiB'); 
        await np.setProperty('demuxer-readahead-secs', '20');

        // THREADING: Allow multi-threaded decoding
        await np.setProperty('vd-lavc-threads', '0'); 
        
        // LATENCY: Turn off latency hacks for files (improves pacing)
        await np.setProperty('untimed', 'no');

        // RENDERER: Direct rendering if possible
        await np.setProperty('vd-lavc-dr', 'yes');
      }

      // === Network-specific settings for cast/stream (both platforms) ===
      if (source.startsWith('http')) {
        await np.setProperty('network-timeout', '30');
        await np.setProperty('stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,timeout=30000000');
        // Network streams: larger cache + user-agent for compatibility
        await np.setProperty('cache-secs', Platform.isAndroid ? '90' : '180');
        await np.setProperty('demuxer-readahead-secs', '600');
        await np.setProperty('cache-pause-wait', '3');
      }
    }

    try {
      Media media = Media(source);
      _addLog('OPEN', 'Opening: $source', _LogLevel.info);
      _addLog('CONFIG', 'Platform: ${Platform.isAndroid ? "Android" : "Windows"}', _LogLevel.info);
      _addLog('CONFIG', 'HW Accel: ${Platform.isAndroid ? "mediacodec" : "auto-copy"}', _LogLevel.info);
      await _player.open(media);
      _addLog('OPEN', 'Media opened successfully', _LogLevel.info);
      setState(() {
        _hasError = false;
        _errorMessage = null;
        _retryCount = 0;
      });
    } catch (e) {
      debugPrint('Failed to open media: $e');
      _addLog('ERROR', 'Failed to open: $e', _LogLevel.error);
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Failed to open: ${e.toString()}';
        });
      }
    }

    // Load external subtitle if provided
    if (widget.subtitlePath != null && widget.subtitlePath!.isNotEmpty) {
      try {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(widget.subtitlePath!),
        );
      } catch (e) {
        debugPrint('Failed to load subtitle: $e');
      }
    }

    // Auto-detect embedded srt/ass/vtt next to the file
    if (widget.subtitlePath == null && !source.startsWith('http')) {
      _autoDetectSubtitle(source);
    }
  }

  Future<void> _autoDetectSubtitle(String videoPath) async {
    try {
      final dir = File(videoPath).parent;
      final videoName =
          videoPath.split(Platform.pathSeparator).last.split('.').first;
      final subExts = ['srt', 'ass', 'ssa', 'vtt', 'sub'];
      for (final ext in subExts) {
        final subFile =
            File('${dir.path}${Platform.pathSeparator}$videoName.$ext');
        if (await subFile.exists()) {
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(subFile.path),
          );
          return;
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _doubleTapResetTimer?.cancel();
    _castControlSub?.cancel();
    _statusTimer?.cancel();
    _statsTimer?.cancel();
    _logScrollController.dispose();
    _volumeIndicatorTimer?.cancel();
    _actionIndicatorTimer?.cancel();
    _swipeOverlayTimer?.cancel();
    _keyboardFocusNode.dispose();
    _player.dispose();
    // Reset brightness to system default on exit
    try { ScreenBrightness().resetScreenBrightness(); } catch (_) {}

    // Restore orientation and system UI
    if (Platform.isAndroid) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Restore window from fullscreen on Windows
    if (Platform.isWindows && _isFullscreen) {
      windowManager.setFullScreen(false);
    }

    super.dispose();
  }

  // ─── Controls visibility ─────────────────────────────────

  void _toggleControls() {
    if (_locked) {
      // When locked, tapping toggles the unlock button visibility
      setState(() => _controlsVisible = !_controlsVisible);
      if (_controlsVisible) _startHideTimer();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _startHideTimer();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && !_showSpeedMenu) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  // ─── Playback controls ───────────────────────────────────

  void _togglePlayPause() {
    if (_isCompleted) {
      _player.seek(Duration.zero);
      _player.play();
      setState(() => _isCompleted = false);
    } else {
      _player.playOrPause();
    }
    _startHideTimer();
  }

  void _seekRelative(Duration delta) {
    final target = _position + delta;
    _player.seek(
      Duration(
        milliseconds: target.inMilliseconds.clamp(0, _duration.inMilliseconds),
      ),
    );
    _startHideTimer();
  }

  void _setSpeed(double speed) {
    _player.setRate(speed);
    setState(() {
      _playbackSpeed = speed;
      _showSpeedMenu = false;
    });
    _startHideTimer();
  }

  void _adjustVolume(double delta) {
    final newVol = (_volume + delta).clamp(0.0, 1.0);
    setState(() {
      _volume = newVol;
      _isMuted = newVol == 0.0;
    });
    _player.setVolume(newVol * 100);
  }

  void _toggleMute() {
    if (_isMuted) {
      setState(() {
        _volume = _volumeBeforeMute;
        _isMuted = false;
      });
      _player.setVolume(_volumeBeforeMute * 100);
    } else {
      setState(() {
        _volumeBeforeMute = _volume;
        _volume = 0.0;
        _isMuted = true;
      });
      _player.setVolume(0);
    }
  }

  void _retryPlayback() {
    setState(() {
      _hasError = false;
      _errorMessage = null;
    });
    _openMedia();
  }

  void _seekToPercent(int percent) {
    if (_duration.inMilliseconds <= 0) return;
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * percent / 100).round(),
    );
    _player.seek(target);
    _startHideTimer();
  }

  // ─── Keyboard handler (VLC-style shortcuts) ──────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;

    // Space or K: Play/Pause
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
      _showActionIndicator(
        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        _isPlaying ? 'Paused' : 'Playing',
      );
      return KeyEventResult.handled;
    }

    // Left arrow: Seek back 5s (Shift: 30s)
    if (key == LogicalKeyboardKey.arrowLeft) {
      final dur = isShift ? _seekDurationLarge : _seekDurationSmall;
      _seekRelative(-dur);
      _showActionIndicator(Icons.fast_rewind_rounded, '-${dur.inSeconds}s');
      return KeyEventResult.handled;
    }

    // Right arrow: Seek forward 5s (Shift: 30s)
    if (key == LogicalKeyboardKey.arrowRight) {
      final dur = isShift ? _seekDurationLarge : _seekDurationSmall;
      _seekRelative(dur);
      _showActionIndicator(Icons.fast_forward_rounded, '+${dur.inSeconds}s');
      return KeyEventResult.handled;
    }

    // Up arrow: Volume up 5%
    if (key == LogicalKeyboardKey.arrowUp) {
      _adjustVolume(0.05);
      _showVolumeIndicator();
      return KeyEventResult.handled;
    }

    // Down arrow: Volume down 5%
    if (key == LogicalKeyboardKey.arrowDown) {
      _adjustVolume(-0.05);
      _showVolumeIndicator();
      return KeyEventResult.handled;
    }

    // F or F11: Toggle fullscreen
    if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      _showActionIndicator(
        _isFullscreen ? Icons.fullscreen_rounded : Icons.fullscreen_exit_rounded,
        _isFullscreen ? 'Fullscreen' : 'Exit Fullscreen',
      );
      return KeyEventResult.handled;
    }

    // Escape: Exit fullscreen, or go back
    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }

    // M: Toggle mute
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      _showVolumeIndicator();
      _showActionIndicator(
        _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        _isMuted ? 'Muted' : 'Unmuted',
      );
      return KeyEventResult.handled;
    }

    // S: Toggle subtitles
    if (key == LogicalKeyboardKey.keyS) {
      _toggleSubtitles();
      _showActionIndicator(
        _subtitlesEnabled ? Icons.subtitles_off_rounded : Icons.subtitles_rounded,
        _subtitlesEnabled ? 'Subtitles Off' : 'Subtitles On',
      );
      return KeyEventResult.handled;
    }

    // V: Cycle through subtitle tracks
    if (key == LogicalKeyboardKey.keyV) {
      _cycleSubtitleTrack();
      return KeyEventResult.handled;
    }

    // B: Cycle through audio tracks
    if (key == LogicalKeyboardKey.keyB) {
      _cycleAudioTrack();
      return KeyEventResult.handled;
    }

    // [ : Decrease speed by 0.25x
    if (key == LogicalKeyboardKey.bracketLeft) {
      final newSpeed = (_playbackSpeed - 0.25).clamp(0.25, 4.0);
      _setSpeed(newSpeed);
      _showActionIndicator(Icons.slow_motion_video_rounded, 'Speed ${newSpeed}x');
      return KeyEventResult.handled;
    }

    // ] : Increase speed by 0.25x
    if (key == LogicalKeyboardKey.bracketRight) {
      final newSpeed = (_playbackSpeed + 0.25).clamp(0.25, 4.0);
      _setSpeed(newSpeed);
      _showActionIndicator(Icons.speed_rounded, 'Speed ${newSpeed}x');
      return KeyEventResult.handled;
    }

    // Backspace: Reset speed to 1x
    if (key == LogicalKeyboardKey.backspace) {
      _setSpeed(1.0);
      _showActionIndicator(Icons.speed_rounded, 'Speed 1.0x', 'Reset');
      return KeyEventResult.handled;
    }

    // I: Toggle debug stats overlay (like mpv's Shift+I)
    if (key == LogicalKeyboardKey.keyI) {
      _toggleStats();
      return KeyEventResult.handled;
    }

    // L: Toggle real-time log console
    if (key == LogicalKeyboardKey.keyL) {
      _toggleLogs();
      return KeyEventResult.handled;
    }

    // 0-9: Seek to 0%-90%
    final numKeys = {
      LogicalKeyboardKey.digit0: 0,
      LogicalKeyboardKey.digit1: 10,
      LogicalKeyboardKey.digit2: 20,
      LogicalKeyboardKey.digit3: 30,
      LogicalKeyboardKey.digit4: 40,
      LogicalKeyboardKey.digit5: 50,
      LogicalKeyboardKey.digit6: 60,
      LogicalKeyboardKey.digit7: 70,
      LogicalKeyboardKey.digit8: 80,
      LogicalKeyboardKey.digit9: 90,
    };
    if (numKeys.containsKey(key) && !isCtrl && !isShift) {
      _seekToPercent(numKeys[key]!);
      _showActionIndicator(Icons.skip_next_rounded, 'Seek to ${numKeys[key]}%');
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // Volume indicator overlay
  Timer? _volumeIndicatorTimer;
  bool _showVolumeOverlay = false;

  // Action indicator (YouTube/VLC-style toast for keyboard shortcuts)
  Timer? _actionIndicatorTimer;
  bool _showActionOverlay = false;
  IconData _actionIcon = Icons.info_rounded;
  String _actionText = '';
  String _actionSubText = '';

  void _showVolumeIndicator() {
    setState(() => _showVolumeOverlay = true);
    _volumeIndicatorTimer?.cancel();
    _volumeIndicatorTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  /// Show a brief YouTube/VLC-style indicator in the center of the screen
  void _showActionIndicator(IconData icon, String text, [String subText = '']) {
    setState(() {
      _actionIcon = icon;
      _actionText = text;
      _actionSubText = subText;
      _showActionOverlay = true;
    });
    _actionIndicatorTimer?.cancel();
    _actionIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showActionOverlay = false);
    });
  }

  Widget _buildActionIndicator() {
    return Positioned(
      top: 50,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _showActionOverlay ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xDD101012),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _accentColor.withOpacity(0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_actionIcon, color: _accentColor, size: 22),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _actionText,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_actionSubText.isNotEmpty)
                      Text(
                        _actionSubText,
                        style: GoogleFonts.outfit(
                          color: Colors.white60,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Debug Stats Overlay (mpv-style) ─────────────────────

  void _toggleStats() {
    setState(() => _showStats = !_showStats);
    if (_showStats) {
      _pollStats(); // Immediate first poll
      _statsTimer?.cancel();
      // Poll every 2s instead of 1s — stats don’t change fast
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted && _showStats) _pollStats();
      });
    } else {
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  Future<void> _pollStats() async {
    if (_player.platform is! native_player.NativePlayer) return;
    final np = _player.platform as native_player.NativePlayer;

    // Read mpv properties in parallel for speed
    final futures = <String, Future<String>>{};
    final props = [
      'video-codec',
      'audio-codec-name',
      'width',
      'height',
      'container-fps',
      'estimated-vf-fps',
      'video-bitrate',
      'audio-bitrate',
      'hwdec-current',
      'frame-drop-count',
      'decoder-frame-drop-count',
      'vo-delayed-frame-count',
      'avsync',
      'video-sync-max-video-change',
      'demuxer-cache-duration',
      'demuxer-cache-state',
      'cache-speed',
      'video-params/pixelformat',
      'video-params/hw-pixelformat',
      'video-params/colormatrix',
      'video-params/primaries',
      'video-params/gamma',
      'video-out-params/w',
      'video-out-params/h',
      'display-fps',
      'video-frame-info/interlaced',
      'packet-video-bitrate',
      'packet-audio-bitrate',
    ];

    for (final p in props) {
      futures[p] = np.getProperty(p).catchError((_) => '');
    }
    final results = <String, String>{};
    for (final entry in futures.entries) {
      results[entry.key] = await entry.value;
    }

    if (!mounted || !_showStats) return;

    // Format human-readable stats
    final vcodec = results['video-codec'] ?? '?';
    final acodec = results['audio-codec-name'] ?? '?';
    final w = results['width'] ?? '?';
    final h = results['height'] ?? '?';
    final outW = results['video-out-params/w'] ?? w;
    final outH = results['video-out-params/h'] ?? h;
    final containerFps = _fmtNum(results['container-fps']);
    final estFps = _fmtNum(results['estimated-vf-fps']);
    final displayFps = _fmtNum(results['display-fps']);
    final hwdec = results['hwdec-current'];
    final hwdecLabel = (hwdec != null && hwdec.isNotEmpty && hwdec != 'no')
        ? '$hwdec (HW)' : 'Software';
    final droppedVo = results['frame-drop-count'] ?? '0';
    final droppedDec = results['decoder-frame-drop-count'] ?? '0';
    final delayedVo = results['vo-delayed-frame-count'] ?? '0';
    final avsync = _fmtNum(results['avsync'], decimals: 3);
    final cacheDur = _fmtNum(results['demuxer-cache-duration']);
    final pixFmt = results['video-params/pixelformat'] ?? '?';
    final hwPixFmt = results['video-params/hw-pixelformat'] ?? '';
    final colormatrix = results['video-params/colormatrix'] ?? '';
    final primaries = results['video-params/primaries'] ?? '';
    final gamma = results['video-params/gamma'] ?? '';
    final vBitrate = _fmtBitrate(results['packet-video-bitrate']);
    final aBitrate = _fmtBitrate(results['packet-audio-bitrate']);

    setState(() {
      _stats = {
        'Video Codec': vcodec,
        'Decoder': hwdecLabel,
        'Resolution': '${w}x$h → ${outW}x$outH',
        'Pixel Format': hwPixFmt.isNotEmpty ? '$pixFmt ($hwPixFmt)' : pixFmt,
        'Container FPS': containerFps,
        'Estimated FPS': estFps,
        'Display FPS': displayFps,
        'Video Bitrate': vBitrate,
        'A/V Sync': '${avsync}s',
        'Dropped (VO)': droppedVo,
        'Dropped (Dec)': droppedDec,
        'Delayed (VO)': delayedVo,
        'Audio Codec': acodec,
        'Audio Bitrate': aBitrate,
        'Cache Ahead': '${cacheDur}s',
        'Color': [colormatrix, primaries, gamma].where((s) => s.isNotEmpty).join(' / '),
      };
    });
  }

  String _fmtNum(String? val, {int decimals = 1}) {
    if (val == null || val.isEmpty) return '?';
    final d = double.tryParse(val);
    if (d == null) return val;
    return d.toStringAsFixed(decimals);
  }

  String _fmtBitrate(String? val) {
    if (val == null || val.isEmpty) return '?';
    final d = double.tryParse(val);
    if (d == null) return val;
    if (d > 1000) return '${(d / 1000).toStringAsFixed(1)} Mbps';
    return '${d.toStringAsFixed(0)} kbps';
  }

  Widget _buildStatsOverlay() {
    // Color-code dropped frames: green = 0, yellow = 1-5, red = >5
    Color _dropColor(String val) {
      final n = int.tryParse(val) ?? 0;
      if (n == 0) return const Color(0xFF4CAF50);
      if (n <= 5) return const Color(0xFFFFD600);
      return const Color(0xFFFF5252);
    }

    return Positioned(
      top: MediaQuery.of(context).padding.top + 50,
      left: 12,
      child: Container(
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: const Color(0xE6080808),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accentColor.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.analytics_rounded, color: _accentColor, size: 16),
                const SizedBox(width: 6),
                Text(
                  'PLAYBACK STATS',
                  style: GoogleFonts.robotoMono(
                    color: _accentColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _toggleStats,
                  child: const Icon(Icons.close_rounded, color: Colors.white38, size: 16),
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 12),
            // Stats rows
            ..._stats.entries.map((e) {
              final isDropped = e.key.startsWith('Dropped') || e.key.startsWith('Delayed');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        e.key,
                        style: GoogleFonts.robotoMono(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        e.value,
                        style: GoogleFonts.robotoMono(
                          color: isDropped ? _dropColor(e.value) : Colors.white.withOpacity(0.85),
                          fontSize: 10,
                          fontWeight: isDropped ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 4),
            Text(
              Platform.isWindows ? 'Press I to close' : 'Tap × to close',
              style: GoogleFonts.robotoMono(
                color: Colors.white24,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Real-time Log Console ───────────────────────────────

  void _addLog(String tag, String message, _LogLevel level) {
    final entry = _LogEntry(
      time: DateTime.now(),
      tag: tag,
      message: message.trim(),
      level: level,
    );
    _logEntries.add(entry);
    // Cap the buffer
    if (_logEntries.length > _maxLogEntries) {
      _logEntries.removeRange(0, _logEntries.length - _maxLogEntries);
    }
    // Only update UI + auto-scroll when log overlay is actually visible.
    // During normal playback the log panel is hidden, so avoid any setState.
    if (_showLogs && mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients) {
          _logScrollController.jumpTo(
            _logScrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  void _toggleLogs() {
    setState(() => _showLogs = !_showLogs);
    if (_showLogs) {
      _addLog('SYSTEM', 'Log console opened', _LogLevel.info);
    }
  }

  Widget _buildLogOverlay() {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 100,
      left: 12,
      right: 12,
      child: Container(
        height: 260,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xF0050505),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accentColor.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.terminal_rounded, color: _accentColor, size: 14),
                const SizedBox(width: 6),
                Text(
                  'LIVE LOG',
                  style: GoogleFonts.robotoMono(
                    color: _accentColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_logEntries.length} entries',
                  style: GoogleFonts.robotoMono(
                    color: Colors.white24,
                    fontSize: 9,
                  ),
                ),
                const Spacer(),
                // Filter chips
                _buildLogFilterChip('E', _LogLevel.error),
                const SizedBox(width: 4),
                _buildLogFilterChip('W', _LogLevel.warn),
                const SizedBox(width: 4),
                _buildLogFilterChip('I', _LogLevel.info),
                const SizedBox(width: 8),
                // Clear button
                GestureDetector(
                  onTap: () => setState(() => _logEntries.clear()),
                  child: const Icon(Icons.delete_sweep_rounded, color: Colors.white38, size: 16),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleLogs,
                  child: const Icon(Icons.close_rounded, color: Colors.white38, size: 16),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 8),
            // Log entries
            Expanded(
              child: _logEntries.isEmpty
                  ? Center(
                      child: Text(
                        'Waiting for log events...',
                        style: GoogleFonts.robotoMono(color: Colors.white24, fontSize: 10),
                      ),
                    )
                  : ListView.builder(
                      controller: _logScrollController,
                      itemCount: _logEntries.length,
                      itemBuilder: (_, i) {
                        final entry = _logEntries[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 0.5),
                          child: RichText(
                            text: TextSpan(
                              style: GoogleFonts.robotoMono(fontSize: 9, height: 1.4),
                              children: [
                                TextSpan(
                                  text: '${entry.timeStr} ',
                                  style: const TextStyle(color: Colors.white24),
                                ),
                                TextSpan(
                                  text: '${entry.levelIcon} ',
                                  style: TextStyle(color: entry.color),
                                ),
                                TextSpan(
                                  text: '[${entry.tag}] ',
                                  style: TextStyle(
                                    color: entry.color.withOpacity(0.7),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text: entry.message,
                                  style: TextStyle(
                                    color: entry.level == _LogLevel.error
                                        ? Colors.redAccent
                                        : Colors.white.withOpacity(0.75),
                                  ),
                                ),
                              ],
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
            // Footer hint
            Text(
              Platform.isWindows ? 'Press L to close | Scroll to browse' : 'Tap \u00d7 to close',
              style: GoogleFonts.robotoMono(color: Colors.white24, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogFilterChip(String label, _LogLevel level) {
    final count = _logEntries.where((e) => e.level == level).length;
    final color = _logLevelColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        '$label:$count',
        style: GoogleFonts.robotoMono(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Color _logLevelColor(_LogLevel level) {
    switch (level) {
      case _LogLevel.error:
        return Colors.redAccent;
      case _LogLevel.warn:
        return const Color(0xFFFFD600);
      case _LogLevel.info:
        return const Color(0xFF4CAF50);
      case _LogLevel.debug:
        return Colors.white38;
    }
  }

  void _toggleSubtitles() {
    if (_subtitlesEnabled) {
      _player.setSubtitleTrack(SubtitleTrack.no());
    } else {
      if (_subtitleTracks.isNotEmpty) {
        final first = _subtitleTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => _subtitleTracks.first,
        );
        _player.setSubtitleTrack(first);
      }
    }
  }

  // ─── Cycle subtitle / audio tracks (V / B keys) ─────────

  void _cycleSubtitleTrack() {
    final tracks = _subtitleTracks.where((t) => t.id != 'auto').toList();
    if (tracks.isEmpty) return;

    // Build list: "no" + all real tracks
    final noTrack = SubtitleTrack.no();
    final allOptions = [noTrack, ...tracks.where((t) => t.id != 'no')];

    // Find current index
    int currentIdx = 0;
    if (_activeSubtitleTrack != null) {
      currentIdx = allOptions.indexWhere((t) => t.id == _activeSubtitleTrack!.id);
      if (currentIdx < 0) currentIdx = 0;
    }

    // Move to next
    final nextIdx = (currentIdx + 1) % allOptions.length;
    final next = allOptions[nextIdx];
    _player.setSubtitleTrack(next);

    // Show indicator
    if (next.id == 'no') {
      _showActionIndicator(Icons.subtitles_off_rounded, 'Subtitles Off');
    } else {
      final name = next.title ?? next.language ?? 'Track ${next.id}';
      _showActionIndicator(Icons.subtitles_rounded, 'Subtitle', name);
    }
  }

  void _cycleAudioTrack() {
    if (_audioTracks.length < 2) return;

    int currentIdx = 0;
    if (_activeAudioTrack != null) {
      currentIdx = _audioTracks.indexWhere((t) => t.id == _activeAudioTrack!.id);
      if (currentIdx < 0) currentIdx = 0;
    }

    final nextIdx = (currentIdx + 1) % _audioTracks.length;
    final next = _audioTracks[nextIdx];
    _player.setAudioTrack(next);

    // Show indicator
    final name = next.title ?? next.language ?? 'Track ${next.id}';
    _showActionIndicator(Icons.audiotrack_rounded, 'Audio', name);
  }

  // ─── Fullscreen ──────────────────────────────────────────

  void _toggleFullscreen() {
    if (Platform.isWindows) {
      setState(() => _isFullscreen = !_isFullscreen);
      windowManager.setFullScreen(_isFullscreen);
    } else if (Platform.isAndroid) {
      if (_isFullscreen) {
        // Exit fullscreen - allow portrait
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        // Enter fullscreen - force landscape
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
      setState(() => _isFullscreen = !_isFullscreen);
    }
    _startHideTimer();
  }

  // ─── Double-tap seek ─────────────────────────────────────

  void _handleDoubleTap(TapDownDetails details, double screenWidth) {
    final x = details.localPosition.dx;
    if (x < screenWidth * 0.4) {
      _seekRelative(-_seekDuration);
      setState(() => _doubleTapSide = 0);
    } else if (x > screenWidth * 0.6) {
      _seekRelative(_seekDuration);
      setState(() => _doubleTapSide = 1);
    }
    _doubleTapResetTimer?.cancel();
    _doubleTapResetTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _doubleTapSide = null);
    });
  }

  // ─── Helpers ─────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String get _title {
    if (widget.title != null) return widget.title!;
    final source = widget.videoSource;
    if (source.contains('/')) return source.split('/').last;
    if (source.contains('\\')) return source.split('\\').last;
    return source;
  }

  TextStyle get _currentSubtitleStyle {
    return TextStyle(
      fontSize: _subtitleFontSize,
      color: _subtitleColor,
      backgroundColor: _subtitleBgColor,
      fontWeight: FontWeight.w600,
      fontFamily: _subtitleFontFamily == 'Default' ? null : _subtitleFontFamily,
    );
  }

  // ─── VLC-like swipe gestures (volume / brightness) ─────

  Future<void> _initBrightness() async {
    try {
      final current = await ScreenBrightness().current;
      if (current > 0) {
        _brightness = current;
      }
    } catch (_) {
      _brightness = 0.5;
    }
    if (mounted) setState(() {});
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_locked) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final x = details.localPosition.dx;

    if (x < screenWidth * 0.45) {
      _swipeSide = 0; // Left side = Volume
      _swipeStartValue = _volume;
    } else if (x > screenWidth * 0.55) {
      _swipeSide = 1; // Right side = Brightness
      _swipeStartValue = _brightness;
    } else {
      _swipeSide = -1; // Center dead zone
      return;
    }

    _swipeStartY = details.localPosition.dy;
    _isVerticalDragging = true;
    _swipeOverlayTimer?.cancel();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isVerticalDragging || _swipeSide == -1 || _locked) return;

    final screenHeight = MediaQuery.of(context).size.height;
    final deltaY = _swipeStartY - details.localPosition.dy; // positive = up
    final sensitivity = screenHeight * 0.65; // 65% of screen = full range
    final deltaPercent = deltaY / sensitivity;

    if (_swipeSide == 0) {
      // Volume (left side swipe)
      final newVol = (_swipeStartValue + deltaPercent).clamp(0.0, 1.0);
      setState(() {
        _volume = newVol;
        _isMuted = newVol == 0.0;
        _showSwipeVolumeOverlay = true;
        _showSwipeBrightnessOverlay = false;
      });
      _player.setVolume(newVol * 100);
    } else if (_swipeSide == 1) {
      // Brightness (right side swipe)
      final newBrightness = (_swipeStartValue + deltaPercent).clamp(0.01, 1.0);
      setState(() {
        _brightness = newBrightness;
        _showSwipeBrightnessOverlay = true;
        _showSwipeVolumeOverlay = false;
      });
      try {
        ScreenBrightness().setScreenBrightness(newBrightness);
      } catch (_) {}
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_isVerticalDragging) return;
    _isVerticalDragging = false;
    _swipeSide = -1;

    // Fade out overlays after a short delay
    _swipeOverlayTimer?.cancel();
    _swipeOverlayTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _showSwipeVolumeOverlay = false;
          _showSwipeBrightnessOverlay = false;
        });
      }
    });
  }

  Widget _buildSwipeVolumeOverlay() {
    return Positioned(
      left: 24,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _showSwipeVolumeOverlay ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 46,
            height: 180,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xDD101012),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: _accentColor.withOpacity(0.25)),
            ),
            child: Column(
              children: [
                Icon(
                  _isMuted
                      ? Icons.volume_off_rounded
                      : _volume > 0.5
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                  color: _accentColor,
                  size: 20,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Container(
                            width: 4,
                            height: constraints.maxHeight * _volume,
                            decoration: BoxDecoration(
                              color: _accentColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_volume * 100).round()}',
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeBrightnessOverlay() {
    return Positioned(
      right: 24,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _showSwipeBrightnessOverlay ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 46,
            height: 180,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xDD101012),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: _accentColor.withOpacity(0.25)),
            ),
            child: Column(
              children: [
                Icon(
                  _brightness > 0.6
                      ? Icons.brightness_high_rounded
                      : _brightness > 0.3
                          ? Icons.brightness_medium_rounded
                          : Icons.brightness_low_rounded,
                  color: _accentColor,
                  size: 20,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Container(
                            width: 4,
                            height: constraints.maxHeight * _brightness,
                            decoration: BoxDecoration(
                              color: _accentColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_brightness * 100).round()}',
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Video (wrapped in RepaintBoundary to isolate from overlay repaints) ──
          Center(
            child: RepaintBoundary(
              child: Video(
                controller: _videoController,
                fill: Colors.black,
                subtitleViewConfiguration: SubtitleViewConfiguration(
                  style: _currentSubtitleStyle,
                  padding: const EdgeInsets.only(bottom: 60),
                ),
                controls: NoVideoControls,
              ),
            ),
          ),

          // ── Tap area (show/hide controls, double-tap, VLC swipe gestures) ──
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTapDown: (d) => _handleDoubleTap(d, screenWidth),
              onDoubleTap: () {},
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              child: const SizedBox.expand(),
            ),
          ),

          // ── Double-tap seek overlay ──
          if (_doubleTapSide != null)
            Positioned(
              left: _doubleTapSide == 0 ? 0 : null,
              right: _doubleTapSide == 1 ? 0 : null,
              top: 0,
              bottom: 0,
              width: screenWidth * 0.4,
              child: Center(
                child: AnimatedOpacity(
                  opacity: 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(40),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _doubleTapSide == 0
                              ? Icons.fast_rewind_rounded
                              : Icons.fast_forward_rounded,
                          color: _accentColor,
                          size: 28,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '10s',
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Buffering indicator ──
          if (_isBuffering)
            Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const CircularProgressIndicator(
                  color: _accentColor,
                  strokeWidth: 3,
                ),
              ),
            ),

          // ── VLC-like swipe volume overlay (left side) ──
          if (_showSwipeVolumeOverlay) _buildSwipeVolumeOverlay(),

          // ── VLC-like swipe brightness overlay (right side) ──
          if (_showSwipeBrightnessOverlay) _buildSwipeBrightnessOverlay(),

          // ── Seek preview tooltip ──
          if (_isSeeking) _buildSeekPreview(),

          // ── Controls overlay (only when not locked) ──
          // Wrapped in RepaintBoundary so overlay repaints never
          // cause the Video texture widget to re-composite.
          if (_controlsVisible && !_locked) ...[
            RepaintBoundary(child: _buildTopBar()),
            RepaintBoundary(child: _buildCenterControls()),
            RepaintBoundary(child: _buildBottomBar()),
          ],

          // ── Lock/Unlock button ──
          // Always show when locked (so user can unlock), and when controls visible
          if (_controlsVisible || _locked)
            Positioned(
              right: 16,
              top: MediaQuery.of(context).size.height / 2 - 20,
              child: AnimatedOpacity(
                opacity: (_controlsVisible || _locked) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: _buildPillButton(
                  icon:
                      _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  onTap: () {
                    setState(() {
                      _locked = !_locked;
                      if (!_locked) {
                        // When unlocking, show controls
                        _controlsVisible = true;
                      }
                    });
                    _startHideTimer();
                  },
                  active: _locked,
                ),
              ),
            ),

          // Speed menu
          if (_showSpeedMenu) _buildSpeedMenu(),

          // ── Action indicator overlay (YouTube/VLC-style toast) ──
          if (_showActionOverlay) _buildActionIndicator(),

          // ── Volume indicator overlay (keyboard volume changes) ──
          if (_showVolumeOverlay)
            Positioned(
              top: 40,
              right: 20,
              child: AnimatedOpacity(
                opacity: _showVolumeOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xE6141416),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _accentColor.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isMuted
                            ? Icons.volume_off_rounded
                            : _volume > 0.5
                                ? Icons.volume_up_rounded
                                : Icons.volume_down_rounded,
                        color: _accentColor,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 80,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _volume,
                            backgroundColor: Colors.white.withOpacity(0.15),
                            valueColor: const AlwaysStoppedAnimation<Color>(_accentColor),
                            minHeight: 6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(_volume * 100).round()}%',
                        style: GoogleFonts.outfit(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Error overlay ──
          if (_hasError)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 56),
                      const SizedBox(height: 16),
                      Text(
                        'Playback Error',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          _errorMessage ?? 'Unknown error occurred',
                          style: GoogleFonts.outfit(
                            color: Colors.white60,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _retryPlayback,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: Text(
                              'Retry${_retryCount > 0 ? ' ($_retryCount/$_maxRetries)' : ''}',
                              style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentColor,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            child: Text('Go Back',
                              style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      if (_retryCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Auto-retrying...',
                            style: GoogleFonts.outfit(
                              color: _accentColor.withOpacity(0.7),
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Debug stats overlay ──
          if (_showStats) RepaintBoundary(child: _buildStatsOverlay()),

          // ── Real-time log console ──
          if (_showLogs) RepaintBoundary(child: _buildLogOverlay()),

          // ── Keyboard shortcuts hint (show briefly on first load) ──
          if (Platform.isWindows && _controlsVisible && !_locked)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 90,
              left: 16,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 0.6 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Space: Play/Pause  \u2190\u2192: Seek  \u2191\u2193: Volume  F: Fullscreen  M: Mute  V: Subs  B: Audio',
                    style: GoogleFonts.outfit(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  // ─── Seek preview ────────────────────────────────────────

  Widget _buildSeekPreview() {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.2,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xE6141416),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _accentColor.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Seek position indicator (icon-based — no duplicate Video widget
              // which would cause frame contention with the main player surface)
              Container(
                width: 180,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _accentColor.withOpacity(0.4)),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Seek direction icon
                    Icon(
                      _seekPreviewPosition > _position
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: _accentColor,
                      size: 44,
                    ),
                    // Progress bar inside preview
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(7),
                          bottomRight: Radius.circular(7),
                        ),
                        child: LinearProgressIndicator(
                          value: _duration.inMilliseconds > 0
                              ? _seekPreviewPosition.inMilliseconds /
                                  _duration.inMilliseconds
                              : 0,
                          backgroundColor: Colors.black54,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              _accentColor),
                          minHeight: 3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // Time display
              Text(
                _formatDuration(_seekPreviewPosition),
                style: GoogleFonts.outfit(
                  color: _accentColor,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_duration.inMilliseconds > 0) ...[
                const SizedBox(height: 2),
                Text(
                  _seekDifference(),
                  style: GoogleFonts.outfit(
                    color: Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _seekDifference() {
    final diff = _seekPreviewPosition - _position;
    final sign = diff.isNegative ? '-' : '+';
    final absDiff = diff.abs();
    return '$sign${_formatDuration(absDiff)}';
  }

  // ─── Top bar ─────────────────────────────────────────────

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            8,
            MediaQuery.of(context).padding.top + 8,
            8,
            12,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              // Back button
              IconButton(
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 4),
              // Title
              Expanded(
                child: Text(
                  _title,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Audio track picker
              if (_audioTracks.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildPillButton(
                    icon: Icons.audiotrack_rounded,
                    onTap: _showAudioTrackPicker,
                  ),
                ),
              // Subtitles toggle
              _buildPillButton(
                icon: _subtitlesEnabled
                    ? Icons.subtitles_rounded
                    : Icons.subtitles_off_rounded,
                onTap: _toggleSubtitles,
                active: _subtitlesEnabled,
              ),
              const SizedBox(width: 8),
              // Subtitle track picker
              if (_subtitleTracks.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildPillButton(
                    icon: Icons.closed_caption_rounded,
                    onTap: _showSubtitlePicker,
                  ),
                ),
              // Subtitle style customization
              _buildPillButton(
                icon: Icons.text_format_rounded,
                onTap: _showSubtitleStylePicker,
              ),
              const SizedBox(width: 8),
              // Debug stats toggle
              _buildPillButton(
                icon: Icons.analytics_rounded,
                onTap: _toggleStats,
                active: _showStats,
              ),
              const SizedBox(width: 8),
              // Log console toggle
              _buildPillButton(
                icon: Icons.terminal_rounded,
                onTap: _toggleLogs,
                active: _showLogs,
              ),
              const SizedBox(width: 8),
              // Fullscreen toggle
              _buildPillButton(
                icon: _isFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                onTap: _toggleFullscreen,
                active: _isFullscreen,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Center controls ─────────────────────────────────────

  Widget _buildCenterControls() {
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Rewind 10s
              _buildCircleButton(
                icon: Icons.replay_10_rounded,
                size: 48,
                iconSize: 30,
                onTap: () => _seekRelative(-_seekDuration),
              ),
              const SizedBox(width: 36),
              // Play / Pause
              _buildCircleButton(
                icon: _isCompleted
                    ? Icons.replay_rounded
                    : (_isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                size: 72,
                iconSize: 44,
                filled: true,
                onTap: _togglePlayPause,
              ),
              const SizedBox(width: 36),
              // Forward 10s
              _buildCircleButton(
                icon: Icons.forward_10_rounded,
                size: 48,
                iconSize: 30,
                onTap: () => _seekRelative(_seekDuration),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Bottom bar ──────────────────────────────────────────

  Widget _buildBottomBar() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Seek bar with preview
              _buildSeekBar(),
              const SizedBox(height: 8),
              // Time + speed + audio
              Row(
                children: [
                  Text(
                    '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                    style: GoogleFonts.outfit(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  // Audio track quick button (if multiple)
                  if (_audioTracks.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: _showAudioTrackPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.audiotrack_rounded,
                                color: Colors.white70,
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _getAudioTrackLabel(),
                                style: GoogleFonts.outfit(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // Speed button
                  GestureDetector(
                    onTap: () {
                      setState(() => _showSpeedMenu = !_showSpeedMenu);
                      _startHideTimer();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _playbackSpeed != 1.0
                            ? _accentColor.withOpacity(0.2)
                            : Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _playbackSpeed != 1.0
                              ? _accentColor.withOpacity(0.5)
                              : Colors.white.withOpacity(0.15),
                        ),
                      ),
                      child: Text(
                        '${_playbackSpeed}x',
                        style: GoogleFonts.outfit(
                          color: _playbackSpeed != 1.0
                              ? _accentColor
                              : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getAudioTrackLabel() {
    if (_activeAudioTrack == null) return 'Audio';
    final t = _activeAudioTrack!;
    if (t.title != null && t.title!.isNotEmpty) return t.title!;
    if (t.language != null && t.language!.isNotEmpty) return t.language!;
    return 'Track ${t.id}';
  }

  // ─── Seek bar with preview ───────────────────────────────

  Widget _buildSeekBar() {
    final max = _duration.inMilliseconds.toDouble();
    final pos = _position.inMilliseconds.toDouble().clamp(0.0, max);
    final buf = _buffered.inMilliseconds.toDouble().clamp(0.0, max);

    return SizedBox(
      height: 20,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3.5,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: _accentColor,
          inactiveTrackColor: Colors.white.withOpacity(0.15),
          thumbColor: _accentColor,
          overlayColor: _accentColor.withOpacity(0.2),
          secondaryActiveTrackColor: Colors.white.withOpacity(0.3),
        ),
        child: Slider(
          value: _isSeeking
              ? _seekPreviewPosition.inMilliseconds
                  .toDouble()
                  .clamp(0.0, max)
              : pos,
          secondaryTrackValue: buf,
          min: 0,
          max: max > 0 ? max : 1,
          onChangeStart: (v) {
            setState(() {
              _isSeeking = true;
              _seekPreviewPosition = Duration(milliseconds: v.toInt());
            });
          },
          onChanged: (v) {
            setState(() {
              _seekPreviewPosition = Duration(milliseconds: v.toInt());
            });
            _startHideTimer();
          },
          onChangeEnd: (v) {
            final seekTarget = Duration(milliseconds: v.toInt());
            _player.seek(seekTarget);
            setState(() {
              _isSeeking = false;
              _position = seekTarget; // Immediately update position to avoid jump-back
              _displayPosition = seekTarget;
            });
            _startHideTimer();
          },
        ),
      ),
    );
  }

  // ─── Speed menu ──────────────────────────────────────────

  Widget _buildSpeedMenu() {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    return Positioned(
      bottom: 80,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: const Color(0xE6141416),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'SPEED',
                  style: GoogleFonts.outfit(
                    color: Colors.grey[500],
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              ...speeds.map((s) {
                final isActive = (_playbackSpeed - s).abs() < 0.01;
                return GestureDetector(
                  onTap: () => _setSpeed(s),
                  child: Container(
                    width: 70,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    margin: const EdgeInsets.symmetric(
                      vertical: 1,
                      horizontal: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? _accentColor.withOpacity(0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '${s}x',
                        style: GoogleFonts.outfit(
                          color: isActive ? _accentColor : Colors.white70,
                          fontSize: 14,
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Audio track picker ──────────────────────────────────

  void _showAudioTrackPicker() {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141416),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.audiotrack_rounded,
                        color: _accentColor, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'Audio Tracks',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ..._audioTracks.map((track) {
                  final isActive = _activeAudioTrack?.id == track.id;
                  final label =
                      track.title ?? track.language ?? 'Track ${track.id}';
                  return ListTile(
                    leading: Icon(
                      isActive
                          ? Icons.volume_up_rounded
                          : Icons.volume_mute_rounded,
                      color: isActive ? _accentColor : Colors.white54,
                    ),
                    title: Text(
                      label,
                      style: GoogleFonts.outfit(
                        color: isActive ? _accentColor : Colors.white,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: track.language != null
                        ? Text(
                            track.language!,
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                          )
                        : null,
                    trailing: isActive
                        ? const Icon(Icons.check_circle_rounded,
                            color: _accentColor, size: 20)
                        : null,
                    onTap: () {
                      _player.setAudioTrack(track);
                      Navigator.pop(ctx);
                    },
                  );
                }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    ).then((_) => _startHideTimer());
  }

  // ─── Subtitle picker bottom sheet ────────────────────────

  void _showSubtitlePicker() {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141416),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Subtitles',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: Icon(
                    Icons.subtitles_off_rounded,
                    color: !_subtitlesEnabled ? _accentColor : Colors.white54,
                  ),
                  title: Text(
                    'Off',
                    style: GoogleFonts.outfit(
                      color: !_subtitlesEnabled ? _accentColor : Colors.white,
                      fontWeight: !_subtitlesEnabled
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  trailing: !_subtitlesEnabled
                      ? const Icon(Icons.check_circle_rounded,
                          color: _accentColor, size: 20)
                      : null,
                  onTap: () {
                    _player.setSubtitleTrack(SubtitleTrack.no());
                    Navigator.pop(ctx);
                  },
                ),
                ..._subtitleTracks.where((t) => t.id != 'no').map((track) {
                  final isActive = _activeSubtitleTrack?.id == track.id;
                  return ListTile(
                    leading: Icon(
                      Icons.closed_caption_rounded,
                      color: isActive ? _accentColor : Colors.white54,
                    ),
                    title: Text(
                      track.title ?? track.language ?? 'Track ${track.id}',
                      style: GoogleFonts.outfit(
                        color: isActive ? _accentColor : Colors.white,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: track.language != null
                        ? Text(
                            track.language!,
                            style: GoogleFonts.outfit(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                          )
                        : null,
                    trailing: isActive
                        ? const Icon(Icons.check_circle_rounded,
                            color: _accentColor, size: 20)
                        : null,
                    onTap: () {
                      _player.setSubtitleTrack(track);
                      Navigator.pop(ctx);
                    },
                  );
                }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    ).then((_) => _startHideTimer());
  }

  // ─── Subtitle style customization ───────────────────────

  void _showSubtitleStylePicker() {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141416),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.text_format_rounded,
                            color: _accentColor, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          'Subtitle Style',
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Preview
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          color: _subtitleBgColor,
                          child: Text(
                            'Sample Subtitle Text',
                            style: TextStyle(
                              fontSize: _subtitleFontSize.clamp(14.0, 48.0),
                              color: _subtitleColor,
                              fontWeight: FontWeight.w600,
                              fontFamily: _subtitleFontFamily == 'Default'
                                  ? null
                                  : _subtitleFontFamily,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Font Size
                    Row(
                      children: [
                        Text('Font Size',
                            style: GoogleFonts.outfit(
                                color: Colors.white70, fontSize: 14)),
                        const Spacer(),
                        Text('${_subtitleFontSize.toInt()}',
                            style: GoogleFonts.outfit(
                                color: _accentColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: _accentColor,
                        inactiveTrackColor: Colors.white.withOpacity(0.15),
                        thumbColor: _accentColor,
                        overlayColor: _accentColor.withOpacity(0.2),
                      ),
                      child: Slider(
                        value: _subtitleFontSize,
                        min: 14,
                        max: 56,
                        divisions: 21,
                        onChanged: (v) {
                          setModalState(() {});
                          setState(() => _subtitleFontSize = v);
                        },
                      ),
                    ),

                    // Font Color
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Font Color',
                          style: GoogleFonts.outfit(
                              color: Colors.white70, fontSize: 14)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: _subtitleColorPresets.map((preset) {
                        final color = preset['color'] as Color;
                        final name = preset['name'] as String;
                        final isActive = _subtitleColor.value == color.value;
                        return GestureDetector(
                          onTap: () {
                            setModalState(() {});
                            setState(() => _subtitleColor = color);
                          },
                          child: Column(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isActive
                                        ? _accentColor
                                        : Colors.white24,
                                    width: isActive ? 3 : 1,
                                  ),
                                ),
                                child: isActive
                                    ? const Icon(Icons.check,
                                        color: Colors.black, size: 18)
                                    : null,
                              ),
                              const SizedBox(height: 4),
                              Text(name,
                                  style: GoogleFonts.outfit(
                                      color: Colors.white54, fontSize: 10)),
                            ],
                          ),
                        );
                      }).toList(),
                    ),

                    // Background
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Background',
                          style: GoogleFonts.outfit(
                              color: Colors.white70, fontSize: 14)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: _subtitleBgPresets.map((preset) {
                        final color = preset['color'] as Color;
                        final name = preset['name'] as String;
                        final isActive = _subtitleBgColor.value == color.value;
                        return GestureDetector(
                          onTap: () {
                            setModalState(() {});
                            setState(() => _subtitleBgColor = color);
                          },
                          child: Column(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isActive
                                        ? _accentColor
                                        : Colors.white24,
                                    width: isActive ? 3 : 1,
                                  ),
                                ),
                                child: isActive
                                    ? Icon(Icons.check,
                                        color: color.opacity > 0.5
                                            ? Colors.white
                                            : _accentColor,
                                        size: 18)
                                    : null,
                              ),
                              const SizedBox(height: 4),
                              Text(name,
                                  style: GoogleFonts.outfit(
                                      color: Colors.white54, fontSize: 10)),
                            ],
                          ),
                        );
                      }).toList(),
                    ),

                    // Font Family
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Font',
                          style: GoogleFonts.outfit(
                              color: Colors.white70, fontSize: 14)),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: _fontFamilies.map((f) {
                          final isActive = _subtitleFontFamily == f;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () {
                                setModalState(() {});
                                setState(() => _subtitleFontFamily = f);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? _accentColor.withOpacity(0.2)
                                      : Colors.white.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isActive
                                        ? _accentColor
                                        : Colors.white12,
                                  ),
                                ),
                                child: Text(
                                  f,
                                  style: GoogleFonts.outfit(
                                    color: isActive
                                        ? _accentColor
                                        : Colors.white70,
                                    fontSize: 13,
                                    fontWeight: isActive
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                      const SizedBox(height: 20),
                    // Reset button
                    TextButton.icon(
                      onPressed: () {
                        setModalState(() {});
                        setState(() {
                          _subtitleFontSize = 32.0;
                          _subtitleColor = Colors.white;
                          _subtitleBgColor = const Color(0x99000000);
                          _subtitleFontFamily = 'Default';
                        });
                      },
                      icon: const Icon(Icons.restore_rounded,
                          color: Colors.white54, size: 18),
                      label: Text('Reset to Default',
                          style: GoogleFonts.outfit(
                              color: Colors.white54, fontSize: 13)),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) => _startHideTimer());
  }

  // ─── Reusable widgets ────────────────────────────────────

  Widget _buildCircleButton({
    required IconData icon,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? _accentColor : Colors.black.withOpacity(0.35),
          border: filled
              ? null
              : Border.all(color: Colors.white.withOpacity(0.2), width: 1.5),
        ),
        child: Icon(
          icon,
          color: filled ? Colors.black : Colors.white,
          size: iconSize,
        ),
      ),
    );
  }

  Widget _buildPillButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active
              ? _accentColor.withOpacity(0.15)
              : Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? _accentColor.withOpacity(0.4)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Icon(
          icon,
          color: active ? _accentColor : Colors.white70,
          size: 20,
        ),
      ),
    );
  }
}

/// Use [NoVideoControls] to disable built-in controls from media_kit_video.
Widget NoVideoControls(VideoState state) {
  return const SizedBox.shrink();
}

// ─── Log entry model ───────────────────────────────────────

enum _LogLevel { error, warn, info, debug }

class _LogEntry {
  final DateTime time;
  final String tag;
  final String message;
  final _LogLevel level;

  _LogEntry({
    required this.time,
    required this.tag,
    required this.message,
    required this.level,
  });

  String get timeStr {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get levelIcon {
    switch (level) {
      case _LogLevel.error:
        return '\u2718'; // ✘
      case _LogLevel.warn:
        return '\u26A0'; // ⚠
      case _LogLevel.info:
        return '\u2714'; // ✔
      case _LogLevel.debug:
        return '\u2022'; // •
    }
  }

  Color get color {
    switch (level) {
      case _LogLevel.error:
        return Colors.redAccent;
      case _LogLevel.warn:
        return const Color(0xFFFFD600);
      case _LogLevel.info:
        return const Color(0xFF4CAF50);
      case _LogLevel.debug:
        return Colors.white38;
    }
  }
}
