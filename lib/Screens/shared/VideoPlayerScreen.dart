import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'platform_video_player_factory.dart';
import 'video_player_interface.dart';
import 'native_platform_mpv_player.dart';

/// Keyboard shortcut map for the video player (VLC-style)
/// Space/K: Play/Pause | Left/Right: Seek ±5s | Shift+Left/Right: Seek ±30s
/// Up/Down: Volume ±5% | M: Mute | F/F11: Fullscreen | Esc: Exit fullscreen
/// [/]: Speed -/+ 0.25x | S: Toggle subtitles | V: Cycle subtitles
/// B: Cycle audio tracks | 0-9: Seek to 0%-90%

/// A Netflix-style video player screen themed to ZapShare's dark/yellow brand.
/// Supports local files and network URLs, with subtitles, play/pause, seek,
/// double-tap ±10s, speed control, audio track switching, subtitle customization,
/// seek preview thumbnails, fullscreen toggle, and landscape mode.
class VideoPlayerScreen extends StatefulWidget {
  /// Either a local file path or a network URL.
  final String videoSource;

  /// Display title (filename by default).
  final String? title;

  /// Optional subtitle file path (supports .srt, .ass, .ssa, .vtt, etc.)
  final String? subtitlePath;

  /// If this is a cast session, the IP of the device that sent the cast URL.
  /// The player will send status updates back and accept remote control commands.
  final String? castControllerIp;

  const VideoPlayerScreen({
    super.key,
    required this.videoSource,
    this.title,
    this.subtitlePath,
    this.castControllerIp,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  late final PlatformVideoPlayer _player;

  // Native orientation control (Android only)
  static const _safChannel = MethodChannel('zapshare.saf');

  /// Set screen orientation via native Android API (FULL_SENSOR for true auto-rotate)
  Future<void> _setOrientation(String mode) async {
    if (!Platform.isAndroid) return;
    try {
      await _safChannel.invokeMethod('setScreenOrientation', {'mode': mode});
    } catch (e) {
      debugPrint('Failed to set orientation: $e');
      // Fallback to Flutter API
      if (mode == 'auto') {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      } else if (mode == 'landscape') {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else if (mode == 'portrait') {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
    }
  }

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
  bool _isInitializing = true;

  // Subtitle state
  bool _subtitlesEnabled = false;
  SubtitleTrackInfo? _activeSubtitleTrack;
  List<SubtitleTrackInfo> _subtitleTracks = [];

  // Audio track state
  AudioTrackInfo? _activeAudioTrack;
  List<AudioTrackInfo> _audioTracks = [];

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
  double _subtitleFontSize = 40.0;
  Color _subtitleColor = Colors.white;
  Color _subtitleBgColor = const Color(0x99000000);
  String _subtitleFontFamily = 'Default';
  double _subtitleBottomOffset = 12.0; // Customizable vertical position

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
  DateTime _lastSeekTime = DateTime.now();

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

  // Aspect Ratio
  int _currentAspectRatioIndex = 0;
  // Expanded definition to support both MPV properties and Flutter widgets
  static const _aspectRatios = [
    {'name': 'Default', 'value': '-1', 'fit': BoxFit.contain, 'ratio': null},
    {'name': '16:9', 'value': '16:9', 'fit': BoxFit.contain, 'ratio': 1.7777},
    {'name': '4:3', 'value': '4:3', 'fit': BoxFit.contain, 'ratio': 1.3333},
    {'name': 'Fill', 'value': 'fill', 'fit': BoxFit.cover, 'ratio': null},
    {'name': 'Fit', 'value': 'fit', 'fit': BoxFit.contain, 'ratio': null},
    {'name': 'Stretch', 'value': 'stretch', 'fit': BoxFit.fill, 'ratio': null},
  ];

  // Helper for subtitle widget style
  TextStyle get _currentSubtitleStyle {
    final shadows = [
      const Shadow(offset: Offset(0, 1), blurRadius: 2, color: Colors.black),
      const Shadow(offset: Offset(0, 0), blurRadius: 4, color: Colors.black),
    ];

    if (_subtitleFontFamily == 'Monospace') {
      return GoogleFonts.robotoMono(
        fontSize: _subtitleFontSize,
        color: _subtitleColor,
        shadows: shadows,
      );
    }
    if (_subtitleFontFamily == 'Serif') {
      return GoogleFonts.merriweather(
        fontSize: _subtitleFontSize,
        color: _subtitleColor,
        shadows: shadows,
      );
    }
    if (_subtitleFontFamily == 'Outfit') {
      return GoogleFonts.outfit(
        fontSize: _subtitleFontSize,
        color: _subtitleColor,
        shadows: shadows,
      );
    }

    // Default / Roboto
    return GoogleFonts.roboto(
      fontSize: _subtitleFontSize,
      color: _subtitleColor,
      shadows: shadows,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSubtitleSettings();
    _initNotification();

    // Create platform-specific player
    // Windows: MPV with native Win32 child window + Flutter overlay UI
    // Android: ExoPlayer via video_player package
    _player = PlatformVideoPlayerFactory.create();

    // Listen to streams
    _player.playingStream.listen((playing) {
      if (!mounted) return;
      _isPlaying = playing;
      _updateNotification();
      // Only rebuild if controls are visible (play/pause icon needs update)
      if (_controlsVisible) setState(() {});
    });
    _player.positionStream.listen((pos) {
      if (!mounted) return;
      if (_isInitializing && pos > Duration.zero) {
        setState(() => _isInitializing = false);
      }
      _position = pos;
      // ONLY rebuild when controls are visible (seek bar needs update).
      // When controls are hidden, the video texture renders independently
      // of the widget tree — calling setState just causes needless rebuilds
      // of the 2600+ line widget tree and competes with GPU rendering.
      if (!_controlsVisible) return;
      final now = DateTime.now();
      if (_isSeeking ||
          now.difference(_lastPositionUpdate).inMilliseconds > 500) {
        _lastPositionUpdate = now;
        setState(() {});
      }
    });
    _player.durationStream.listen((dur) {
      if (!mounted) return;
      _duration = dur;
      setState(() {});
    });
    _player.bufferStream.listen((buf) {
      if (!mounted) return;
      _buffered = buf;
    });
    _player.bufferingStream.listen((buffering) {
      if (!mounted) return;
      if (_isBuffering != buffering) {
        setState(() => _isBuffering = buffering);
      }
    });
    _player.completedStream.listen((completed) {
      if (mounted) {
        setState(() {
          _isCompleted = completed;
          if (completed) _controlsVisible = true;
        });
      }
    });
    _player.subtitleTracksStream.listen((tracks) {
      if (mounted) {
        setState(() {
          _subtitleTracks = tracks;
        });
      }
    });
    _player.audioTracksStream.listen((tracks) {
      if (mounted) {
        setState(() {
          _audioTracks = tracks;
        });
      }
    });
    _player.activeSubtitleTrackStream.listen((track) {
      if (mounted) {
        setState(() {
          _activeSubtitleTrack = track;
          _subtitlesEnabled = track != null && track.id != 'no';
        });
      }
    });
    _player.activeAudioTrackStream.listen((track) {
      if (mounted) {
        setState(() {
          _activeAudioTrack = track;
        });
      }
    });

    // Listen for player errors
    _player.errorStream.listen((error) {
      if (mounted && error.isNotEmpty) {
        debugPrint('Player error: $error');
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

    // Enable auto-rotate on Android via native FULL_SENSOR
    if (Platform.isAndroid) {
      _setOrientation('auto');
    }
    // Initialize screen brightness for VLC-like swipe gesture
    _initBrightness();

    // Keep screen on for Android
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // Note: VideoPlayer plugin usually handles KEEP_SCREEN_ON, but we force it via window flag if needed?
      // Flutter doesn't expose FLAG_KEEP_SCREEN_ON directly without a plugin like wakelock_plus.
      // However, we can use the 'flutter_foreground_task' which is already in the project,
      // or rely on video_player.
      // Given the user issue, we will rely on optimize buffering first.
    }

    // Pause device discovery during video playback to save resources & CPU
    DeviceDiscoveryService().pauseDiscovery();
  }

  // ─── Cast session (remote control) ─────────────────────────

  void _initCastSession() {
    final discoveryService = DeviceDiscoveryService();
    final controllerIp = widget.castControllerIp!;

    // Listen for remote control commands from the sender
    _castControlSub = discoveryService.castControlStream.listen((control) {
      if (!mounted) return;
      try {
        switch (control.action) {
          case 'play':
            _player.play();
            break;
          case 'pause':
            _player.pause();
            break;
          case 'seek':
            if (control.seekPosition != null) {
              _player.seek(
                Duration(milliseconds: (control.seekPosition! * 1000).toInt()),
              );
            }
            break;
          case 'volume':
            if (control.volume != null) {
              setState(() => _volume = control.volume!);
              _player.setVolume(
                control.volume! * 100,
              ); // media_kit volume is 0-100
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
      } catch (e) {
        debugPrint('Error handling cast control: $e');
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

  void _sendStatusNow(
    DeviceDiscoveryService discoveryService,
    String controllerIp,
  ) {
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

    try {
      // Platform-specific player handles all configuration internally:
      // - Windows: MPV with native Win32 child window rendering
      // - Android: ExoPlayer for smooth hardware-accelerated playback
      await _player.open(source, subtitlePath: widget.subtitlePath);
      _applySubtitleStyle();

      setState(() {
        _hasError = false;
        _errorMessage = null;
        _retryCount = 0;
        // Dismiss initializing overlay immediately after successful open command
        // This is crucial if IPC position updates are delayed or unavailable
        _isInitializing = false;
      });
    } catch (e) {
      debugPrint('Failed to open media: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Failed to open: ${e.toString()}';
          _isInitializing =
              false; // Also dismiss on error to show error message
        });
      }
    }

    // Note: Auto-detect subtitle feature removed for platform abstraction
    // Subtitles should be passed via widget.subtitlePath parameter
  }

  @override
  void dispose() {
    _saveSubtitleSettings();
    _hideTimer?.cancel();
    _doubleTapResetTimer?.cancel();
    _castControlSub?.cancel();
    _statusTimer?.cancel();
    _volumeIndicatorTimer?.cancel();
    _actionIndicatorTimer?.cancel();
    _swipeOverlayTimer?.cancel();
    _keyboardFocusNode.dispose();
    _player.dispose();
    // Reset brightness to system default on exit
    try {
      ScreenBrightness().resetScreenBrightness();
    } catch (_) {}

    // Restore orientation and system UI
    if (Platform.isAndroid) {
      // Restore full sensor rotation
      _setOrientation('auto');
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Restore window from fullscreen on Windows
    if (Platform.isWindows && _isFullscreen) {
      windowManager.setFullScreen(false);
    }

    // Resume device discovery when player is closed
    DeviceDiscoveryService().resumeDiscovery();

    super.dispose();
  }

  // ─── Controls visibility ─────────────────────────────────

  void _toggleControls() {
    // Ensure keyboard shortcuts work after any interaction
    _keyboardFocusNode.requestFocus();
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
    int maxMs = _duration.inMilliseconds;
    // If duration is unknown (0), don't clamp upper bound, just let it try to seek
    if (maxMs <= 0) maxMs = 2147483647;

    _player.seek(Duration(milliseconds: target.inMilliseconds.clamp(0, maxMs)));
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
        _isFullscreen
            ? Icons.fullscreen_rounded
            : Icons.fullscreen_exit_rounded,
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

    // C: Toggle Aspect Ratio
    if (key == LogicalKeyboardKey.keyC) {
      _toggleAspectRatio();
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

    // S: Cycle through subtitle tracks (Updated from Toggle)
    if (key == LogicalKeyboardKey.keyS) {
      _cycleSubtitleTrack();
      return KeyEventResult.handled;
    }

    // A: Cycle through audio tracks
    if (key == LogicalKeyboardKey.keyA) {
      _cycleAudioTrack();
      return KeyEventResult.handled;
    }

    // V: Cycle through subtitle tracks (Legacy/Alternative)
    if (key == LogicalKeyboardKey.keyV) {
      _cycleSubtitleTrack();
      return KeyEventResult.handled;
    }

    // B: Cycle through audio tracks (Legacy)
    if (key == LogicalKeyboardKey.keyB) {
      _cycleAudioTrack();
      return KeyEventResult.handled;
    }

    // [ : Decrease speed by 0.25x
    if (key == LogicalKeyboardKey.bracketLeft) {
      final newSpeed = (_playbackSpeed - 0.25).clamp(0.25, 4.0);
      _setSpeed(newSpeed);
      _showActionIndicator(
        Icons.slow_motion_video_rounded,
        'Speed ${newSpeed}x',
      );
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

  void _toggleSubtitles() {
    _showSubtitlePicker();
  }

  // ─── Cycle subtitle / audio tracks (V / B keys) ─────────

  void _cycleSubtitleTrack() {
    final tracks = _subtitleTracks.where((t) => t.id != 'auto').toList();
    if (tracks.isEmpty) {
      _showActionIndicator(Icons.subtitles_off_rounded, 'No subtitles found');
      return;
    }

    // specific logic for cycling...
    final noTrack = SubtitleTrackInfo.none;
    final allOptions = [noTrack, ...tracks.where((t) => t.id != 'no')];

    // ... logic continues normally

    // Find current index
    int currentIdx = 0;
    if (_activeSubtitleTrack != null) {
      currentIdx = allOptions.indexWhere(
        (t) => t.id == _activeSubtitleTrack!.id,
      );
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
    if (_audioTracks.length < 2) {
      if (_audioTracks.isNotEmpty) {
        final t = _activeAudioTrack ?? _audioTracks.first;
        final name = t.title ?? t.language ?? 'Track ${t.id}';
        _showActionIndicator(
          Icons.audiotrack_rounded,
          'Audio: $name',
          '(Single Track)',
        );
      } else {
        _showActionIndicator(Icons.audiotrack_rounded, 'No audio tracks');
      }
      return;
    }

    int currentIdx = 0;
    if (_activeAudioTrack != null) {
      currentIdx = _audioTracks.indexWhere(
        (t) => t.id == _activeAudioTrack!.id,
      );
      if (currentIdx < 0) currentIdx = 0;
    }

    final nextIdx = (currentIdx + 1) % _audioTracks.length;
    final next = _audioTracks[nextIdx];
    _player.setAudioTrack(next);

    // Show indicator
    final name = next.title ?? next.language ?? 'Track ${next.id}';
    _showActionIndicator(Icons.audiotrack_rounded, 'Audio', name);
  }

  // ─── Aspect Ratio ────────────────────────────────────────

  void _toggleAspectRatio() {
    setState(() {
      _currentAspectRatioIndex =
          (_currentAspectRatioIndex + 1) % _aspectRatios.length;
    });

    final current = _aspectRatios[_currentAspectRatioIndex];
    final val = current['value']! as String;
    final name = current['name']! as String;

    // Platform abstraction: we assume the underlying player can handle these or we use specific logic.
    // Since this is VideoPlayerScreen.dart (Windows/MPV primary), we use MPV properties via setProperty if possible,
    // or we assume the factory created a player that supports this.
    // The current PlatformVideoPlayer interface doesn't expose generic property setting.
    // However, we know this file is primarily for Windows MPV (since Android has its own screen).
    // Let's assume we can cast or extend the interface later.
    // For now, checks if it is NativePlatformMpvPlayer (which we know it is on Windows).

    if (_player is NativePlatformMpvPlayer) {
      final mpv = _player;
      if (val == 'fill') {
        // Pan & Scan to fill
        mpv.setProperty('video-aspect-override', '-1');
        mpv.setProperty('panscan', '1.0');
      } else if (val == 'fit') {
        // Fit (contain)
        mpv.setProperty('video-aspect-override', '-1');
        mpv.setProperty('panscan', '0.0');
      } else if (val == 'stretch') {
        // Stretch (BoxFit.fill) - MPV doesn't hold a simple "stretch" property easily without window size
        // Fallback to "fill" behavior or specific aspect ratio if we knew it.
        // For now, treat as fill for MPV.
        mpv.setProperty('video-aspect-override', '-1');
        mpv.setProperty('panscan', '1.0');
      } else {
        // Aspect override
        mpv.setProperty('video-aspect-override', val);
        mpv.setProperty('panscan', '0.0');
      }
    }

    _showActionIndicator(Icons.aspect_ratio_rounded, 'Aspect Ratio', name);
  }

  void _toggleFullscreen() async {
    if (Platform.isWindows) {
      setState(() {
        _isFullscreen = !_isFullscreen;
        // Force controls visible so the overlay rebuilds at the new window size.
        // Without this, exiting fullscreen with controls hidden leaves the
        // overlay sized for fullscreen when it next appears.
        _controlsVisible = true;
      });
      await windowManager.setFullScreen(_isFullscreen);

      // The window_manager plugin toggles fullscreen asynchronously:
      // it changes window style, calls ShowWindow, and SetWindowPos.
      // Flutter may not immediately receive the final correct metrics.
      // Multiple delayed re-syncs ensure the layout catches up.
      for (final delay in [150, 350, 600]) {
        Future.delayed(Duration(milliseconds: delay), () {
          if (mounted && _player is NativePlatformMpvPlayer) {
            (_player as NativePlatformMpvPlayer).notifyResize();
          }
          // Force Flutter to rebuild layout with fresh MediaQuery
          if (mounted) setState(() {});
        });
      }
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
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── Video (wrapped in RepaintBoundary to isolate from overlay repaints) ──
            // Platform-specific rendering:
            // - Windows: MPV native Win32 child window (zero-copy GPU path)
            // - Android: ExoPlayer surface view (hardware-accelerated)
            Center(
              child: RepaintBoundary(
                child: Builder(
                  builder: (context) {
                    final current = _aspectRatios[_currentAspectRatioIndex];
                    final ratio = current['ratio'] as double?;
                    final fit = current['fit'] as BoxFit?;

                    Widget playerWidget = _player.buildVideoWidget(
                      backgroundColor: Colors.transparent,
                      fit: fit,
                    );

                    // Apply aspect ratio wrapper if defined
                    if (ratio != null) {
                      return AspectRatio(
                        aspectRatio: ratio,
                        child: playerWidget,
                      );
                    }

                    // Otherwise rely on inner fit (passed to player)
                    return playerWidget;
                  },
                ),
              ),
            ),

            // ─── Subtitle Overlay ───
            // On Windows, MPV handles OSD rendering (prevents double subtitles).
            // On Android, we render manually via Flutter overlay.
            // Subtitles shift up when controls/seek bar are visible to avoid overlap.
            if (_subtitlesEnabled && !Platform.isWindows)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                bottom:
                    _controlsVisible
                        ? _subtitleBottomOffset + 88
                        : _subtitleBottomOffset,
                left: 24,
                right: 24,
                child: StreamBuilder<String>(
                  stream: _player.captionStream,
                  builder: (context, snapshot) {
                    final text = snapshot.data;
                    // If subtitles are enabled but no text, show nothing.
                    // If text is present, show it.
                    if (text == null || text.trim().isEmpty) {
                      return const SizedBox();
                    }
                    return Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _subtitleBgColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: _currentSubtitleStyle,
                        ),
                      ),
                    );
                  },
                ),
              ),

            // ── Initializing overlay ──
            if (_isInitializing)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: _accentColor,
                          strokeWidth: 3,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Initializing Player...',
                          style: GoogleFonts.outfit(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
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

            // ── VLC-like swipe volume overlay (left side) ──
            if (_showSwipeVolumeOverlay) _buildSwipeVolumeOverlay(),

            // ── VLC-like swipe brightness overlay (right side) ──
            if (_showSwipeBrightnessOverlay) _buildSwipeBrightnessOverlay(),

            // ── Controls overlay (only when not locked) ──
            if (_controlsVisible && !_locked) ...[
              _buildTopBar(),
              // Show center controls only when NOT buffering
              if (!_isBuffering) _buildCenterControls(),
              _buildBottomBar(),
            ],

            // ── Buffering indicator (above controls so it's visible) ──
            if (_isBuffering)
              const Center(
                child: CircularProgressIndicator(
                  color: _accentColor,
                  strokeWidth: 3,
                ),
              ),

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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
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
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                _accentColor,
                              ),
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
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Colors.redAccent,
                          size: 56,
                        ),
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
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _accentColor,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                              child: Text(
                                'Go Back',
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
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

            // ── Keyboard shortcuts hint (show briefly on first load) ──
            if (Platform.isWindows && _controlsVisible && !_locked)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 90,
                left: 16,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 0.6 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Space: Play/Pause  \u2190\u2192: Seek  \u2191\u2193: Volume  F: Fullscreen  M: Mute  S: Subs  A: Audio',
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

  // ─── Seek preview (Removed) ────────────────────────────
  // Widget _buildSeekPreview() { ... }

  String _seekDifference() {
    final diff = _seekPreviewPosition - _position;
    final sign = diff.isNegative ? '-' : '+';
    final absDiff = diff.abs();
    return '$sign${_formatDuration(absDiff)}';
  }

  Future<void> _loadSubtitleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _subtitleFontSize = prefs.getDouble('sub_font_size') ?? 40.0;
      _subtitleColor = Color(prefs.getInt('sub_color') ?? Colors.white.value);
      _subtitleBgColor = Color(
        prefs.getInt('sub_bg_color') ?? const Color(0x99000000).value,
      );
      _subtitleFontFamily = prefs.getString('sub_font_family') ?? 'Default';
      _subtitlesEnabled = prefs.getBool('sub_enabled') ?? false;
      _subtitleBottomOffset = prefs.getDouble('sub_bottom_offset') ?? 12.0;
    });
  }

  Future<void> _saveSubtitleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('sub_font_size', _subtitleFontSize);
    await prefs.setInt('sub_color', _subtitleColor.value);
    await prefs.setInt('sub_bg_color', _subtitleBgColor.value);
    await prefs.setString('sub_font_family', _subtitleFontFamily);
    await prefs.setBool('sub_enabled', _subtitlesEnabled);
    await prefs.setDouble('sub_bottom_offset', _subtitleBottomOffset);
    if (_activeSubtitleTrack != null) {
      await prefs.setString('last_sub_track_id', _activeSubtitleTrack!.id);
    }
  }

  Future<void> _initNotification() async {
    // Basic setup handled in main.dart
  }

  Future<void> _updateNotification() async {
    if (!Platform.isAndroid) return;
    // Simple placeholder for notification logic
    // Implementation requires coordination with main.dart's foreground task handler
  }

  // 0 = Auto, 1 = Landscape, 2 = Portrait
  int _rotationMode = 0;

  void _toggleRotation() {
    setState(() {
      _rotationMode = (_rotationMode + 1) % 3;
    });

    if (_rotationMode == 1) {
      // Force Landscape via native API
      _setOrientation('landscape');
      _showActionIndicator(
        Icons.screen_lock_landscape_rounded,
        'Landscape',
        'Locked',
      );
    } else if (_rotationMode == 2) {
      // Force Portrait via native API
      _setOrientation('portrait');
      _showActionIndicator(
        Icons.screen_lock_portrait_rounded,
        'Portrait',
        'Locked',
      );
    } else {
      // Auto - FULL_SENSOR for true sensor-based auto-rotate
      _setOrientation('auto');
      _showActionIndicator(
        Icons.screen_rotation_rounded,
        'Auto-Rotate',
        'Unlocked',
      );
    }
  }

  void _applySubtitleStyle() {
    _saveSubtitleSettings(); // Save whenever style is applied/changed

    if (!Platform.isWindows) return;

    String toHex(Color c) =>
        '#${c.value.toRadixString(16).padLeft(8, '0').toUpperCase()}';

    // Force overrides so our styles take precedence over SSA/ASS styles
    _player.setProperty('sub-ass-override', 'force');

    _player.setProperty('sub-font-size', '${_subtitleFontSize.toInt()}');
    _player.setProperty('sub-color', toHex(_subtitleColor));
    _player.setProperty('sub-back-color', toHex(_subtitleBgColor));

    // MPV border/shadow defaults for readability
    _player.setProperty('sub-border-color', '#000000');
    _player.setProperty('sub-border-size', '2.0');
    _player.setProperty('sub-shadow-offset', '1.0');
    _player.setProperty('sub-shadow-color', '#000000');

    if (_subtitleFontFamily != 'Default') {
      _player.setProperty('sub-font', _subtitleFontFamily);
    } else {
      _player.setProperty('sub-font', 'sans-serif');
    }
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
              // Audio track picker (Bottom bar only to avoid duplicates)
              // if (_audioTracks.isNotEmpty) ...

              // Subtitle toggle (Consolidated)
              _buildPillButton(
                icon:
                    _subtitlesEnabled
                        ? Icons.subtitles_rounded
                        : Icons.subtitles_off_rounded,
                onTap: _toggleSubtitles,
                active: _subtitlesEnabled,
              ),
              const SizedBox(width: 8),
              // Subtitle style customization
              _buildPillButton(
                icon: Icons.text_format_rounded,
                onTap: _showSubtitleStylePicker,
              ),
              const SizedBox(width: 8),
              // Rotation toggle (Android only)
              // Rotation toggle
              _buildPillButton(
                icon:
                    _rotationMode == 1
                        ? Icons.screen_lock_landscape_rounded
                        : _rotationMode == 2
                        ? Icons.screen_lock_portrait_rounded
                        : Icons.screen_rotation_rounded,
                onTap: _toggleRotation,
                active: _rotationMode != 0,
              ),
              const SizedBox(width: 8),

              // Aspect Ratio (All platforms)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildPillButton(
                  icon: Icons.aspect_ratio_rounded,
                  onTap: _toggleAspectRatio,
                ),
              ),

              // Fullscreen toggle (Windows only - Android is already fullscreen)
              if (!Platform.isAndroid) ...[
                const SizedBox(width: 8),
                _buildPillButton(
                  icon:
                      _isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                  onTap: _toggleFullscreen,
                  active: _isFullscreen,
                ),
              ],
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
                icon:
                    _isCompleted
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
                  // Audio track quick button (Show if any tracks exist)
                  if (_audioTracks.isNotEmpty)
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
                        color:
                            _playbackSpeed != 1.0
                                ? _accentColor.withOpacity(0.2)
                                : Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color:
                              _playbackSpeed != 1.0
                                  ? _accentColor.withOpacity(0.5)
                                  : Colors.white.withOpacity(0.15),
                        ),
                      ),
                      child: Text(
                        '${_playbackSpeed}x',
                        style: GoogleFonts.outfit(
                          color:
                              _playbackSpeed != 1.0
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
      height: 48,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 4.0,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
          activeTrackColor: _accentColor,
          inactiveTrackColor: Colors.white.withOpacity(0.15),
          thumbColor: _accentColor,
          overlayColor: _accentColor.withOpacity(0.2),
          secondaryActiveTrackColor: Colors.white.withOpacity(0.3),
        ),
        child: Slider(
          value:
              _isSeeking
                  ? _seekPreviewPosition.inMilliseconds.toDouble().clamp(
                    0.0,
                    max,
                  )
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

            // Live seek (Scrubbing) - Throttled
            final now = DateTime.now();
            if (now.difference(_lastSeekTime).inMilliseconds > 150) {
              _lastSeekTime = now;
              _player.seek(_seekPreviewPosition);
            }
          },
          onChangeEnd: (v) {
            final seekTarget = Duration(milliseconds: v.toInt());
            _player.seek(seekTarget);
            setState(() {
              _isSeeking = false;
              _position =
                  seekTarget; // Immediately update position to avoid jump-back
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
                      color:
                          isActive
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
                    const Icon(
                      Icons.audiotrack_rounded,
                      color: _accentColor,
                      size: 22,
                    ),
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
                    subtitle:
                        track.language != null
                            ? Text(
                              track.language!,
                              style: GoogleFonts.outfit(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            )
                            : null,
                    trailing:
                        isActive
                            ? const Icon(
                              Icons.check_circle_rounded,
                              color: _accentColor,
                              size: 20,
                            )
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
                      fontWeight:
                          !_subtitlesEnabled
                              ? FontWeight.w700
                              : FontWeight.w500,
                    ),
                  ),
                  trailing:
                      !_subtitlesEnabled
                          ? const Icon(
                            Icons.check_circle_rounded,
                            color: _accentColor,
                            size: 20,
                          )
                          : null,
                  onTap: () {
                    _player.setSubtitleTrack(SubtitleTrackInfo.none);
                    setState(() => _subtitlesEnabled = false);
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
                    subtitle:
                        track.language != null
                            ? Text(
                              track.language!,
                              style: GoogleFonts.outfit(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            )
                            : null,
                    trailing:
                        isActive
                            ? const Icon(
                              Icons.check_circle_rounded,
                              color: _accentColor,
                              size: 20,
                            )
                            : null,
                    onTap: () {
                      _player.setSubtitleTrack(track);
                      setState(() {
                        _activeSubtitleTrack = track;
                        _subtitlesEnabled = true;
                      });
                      _saveSubtitleSettings();
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
                        const Icon(
                          Icons.text_format_rounded,
                          color: _accentColor,
                          size: 22,
                        ),
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
                            horizontal: 8,
                            vertical: 4,
                          ),
                          color: _subtitleBgColor,
                          child: Text(
                            'Sample Subtitle Text',
                            style: TextStyle(
                              fontSize: _subtitleFontSize.clamp(14.0, 48.0),
                              color: _subtitleColor,
                              fontWeight: FontWeight.w600,
                              fontFamily:
                                  _subtitleFontFamily == 'Default'
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
                        Text(
                          'Font Size',
                          style: GoogleFonts.outfit(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_subtitleFontSize.toInt()}',
                          style: GoogleFonts.outfit(
                            color: _accentColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
                          _applySubtitleStyle();
                        },
                      ),
                    ),

                    // Subtitle Position
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Position',
                          style: GoogleFonts.outfit(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_subtitleBottomOffset.toInt()}',
                          style: GoogleFonts.outfit(
                            color: _accentColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
                        value: _subtitleBottomOffset,
                        min: 0,
                        max: 100,
                        divisions: 20,
                        onChanged: (v) {
                          setModalState(() {});
                          setState(() => _subtitleBottomOffset = v);
                          _applySubtitleStyle();
                        },
                      ),
                    ),

                    // Font Color
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Font Color',
                        style: GoogleFonts.outfit(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children:
                          _subtitleColorPresets.map((preset) {
                            final color = preset['color'] as Color;
                            final name = preset['name'] as String;
                            final isActive =
                                _subtitleColor.value == color.value;
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
                                        color:
                                            isActive
                                                ? _accentColor
                                                : Colors.white24,
                                        width: isActive ? 3 : 1,
                                      ),
                                    ),
                                    child:
                                        isActive
                                            ? const Icon(
                                              Icons.check,
                                              color: Colors.black,
                                              size: 18,
                                            )
                                            : null,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    name,
                                    style: GoogleFonts.outfit(
                                      color: Colors.white54,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                    ),

                    // Background
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Background',
                        style: GoogleFonts.outfit(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children:
                          _subtitleBgPresets.map((preset) {
                            final color = preset['color'] as Color;
                            final name = preset['name'] as String;
                            final isActive =
                                _subtitleBgColor.value == color.value;
                            return GestureDetector(
                              onTap: () {
                                setModalState(() {});
                                setState(() => _subtitleBgColor = color);
                                _applySubtitleStyle();
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
                                        color:
                                            isActive
                                                ? _accentColor
                                                : Colors.white24,
                                        width: isActive ? 3 : 1,
                                      ),
                                    ),
                                    child:
                                        isActive
                                            ? Icon(
                                              Icons.check,
                                              color:
                                                  color.opacity > 0.5
                                                      ? Colors.white
                                                      : _accentColor,
                                              size: 18,
                                            )
                                            : null,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    name,
                                    style: GoogleFonts.outfit(
                                      color: Colors.white54,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                    ),

                    // Font Family
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Font',
                        style: GoogleFonts.outfit(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children:
                            _fontFamilies.map((f) {
                              final isActive = _subtitleFontFamily == f;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: GestureDetector(
                                  onTap: () {
                                    setModalState(() {});
                                    setState(() => _subtitleFontFamily = f);
                                    _applySubtitleStyle();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          isActive
                                              ? _accentColor.withOpacity(0.2)
                                              : Colors.white.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color:
                                            isActive
                                                ? _accentColor
                                                : Colors.white12,
                                      ),
                                    ),
                                    child: Text(
                                      f,
                                      style: GoogleFonts.outfit(
                                        color:
                                            isActive
                                                ? _accentColor
                                                : Colors.white70,
                                        fontSize: 13,
                                        fontWeight:
                                            isActive
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
                          _subtitleFontSize = 40.0;
                          _subtitleColor = Colors.white;
                          _subtitleBgColor = const Color(0x99000000);
                          _subtitleFontFamily = 'Default';
                          _subtitleBottomOffset = 12.0;
                        });
                        _applySubtitleStyle();
                      },
                      icon: const Icon(
                        Icons.restore_rounded,
                        color: Colors.white54,
                        size: 18,
                      ),
                      label: Text(
                        'Reset to Default',
                        style: GoogleFonts.outfit(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
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
          border:
              filled
                  ? null
                  : Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1.5,
                  ),
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
          color:
              active
                  ? _accentColor.withOpacity(0.15)
                  : Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                active
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
