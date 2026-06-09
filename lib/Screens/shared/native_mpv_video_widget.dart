import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'native_mpv_player.dart';

/// Heights reserved for Flutter overlay. MPV native window is inset so it
/// never covers these strips — controls are always visible.
const double _kOverlayTopHeight = 80;
const double _kOverlayBottomHeight = 100;

/// Professional video player with native MPV child window
/// Provides Flutter UI overlay on top of native rendering
class NativeMpvVideoPlayer extends StatefulWidget {
  final String? mpvPath;
  final VoidCallback? onReady;

  const NativeMpvVideoPlayer({super.key, this.mpvPath, this.onReady});

  @override
  State<NativeMpvVideoPlayer> createState() => NativeMpvVideoPlayerState();
}

class NativeMpvVideoPlayerState extends State<NativeMpvVideoPlayer> {
  late NativeMpvPlayer _player;
  bool _isReady = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isBuffering = false;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _isHoveringControls = false;

  // Window dimensions (updated on layout)
  Rect _windowRect = Rect.zero;

  /// Video rect: full area minus top/bottom overlay strips so MPV doesn't cover controls.
  Rect get _videoRect {
    final w = _windowRect.width;
    final h = _windowRect.height;
    final videoHeight = (h - _kOverlayTopHeight - _kOverlayBottomHeight).clamp(
      1.0,
      double.infinity,
    );
    return Rect.fromLTWH(0, _kOverlayTopHeight, w, videoHeight);
  }

  @override
  void initState() {
    super.initState();
    _player = NativeMpvPlayer();
    _setupListeners();
  }

  void _setupListeners() {
    _player.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          if (playing) {
            _isBuffering = false;
            _startHideTimer();
          } else {
            _showControls = true;
            _hideControlsTimer?.cancel();
          }
        });
      }
    });

    _player.position.listen((pos) {
      if (mounted) {
        setState(() => _position = pos);
      }
    });

    _player.duration.listen((dur) {
      if (mounted) {
        setState(() => _duration = dur);
      }
    });

    _player.buffering.listen((buffering) {
      if (mounted) {
        setState(() => _isBuffering = buffering);
      }
    });
  }

  /// Initialize player with window dimensions
  Future<void> initialize() async {
    if (_isReady) return;

    // Get MPV path (default: system path or bundled)
    final mpvPath = widget.mpvPath ?? await _findMpvExecutable();

    // Wait for first layout to get window dimensions
    await Future.delayed(const Duration(milliseconds: 100));

    if (_windowRect == Rect.zero) {
      throw Exception('Window dimensions not available. Call after build.');
    }

    final r = _videoRect;
    await _player.initialize(
      mpvPath: mpvPath,
      x: r.left.toInt(),
      y: r.top.toInt(),
      width: r.width.toInt(),
      height: r.height.toInt(),
    );

    setState(() => _isReady = true);
    setState(() => _isReady = true);

    // Apply custom subtitle styles
    await _player.setProperty('sub-font-size', '40');
    await _player.setProperty('sub-color', '#FFFFFF');
    await _player.setProperty('sub-border-color', '#000000');
    await _player.setProperty('sub-border-size', '2.0');
    await _player.setProperty('sub-shadow-offset', '1.0');
    await _player.setProperty('sub-shadow-color', '#000000');
    await _player.setProperty(
      'sub-back-color',
      '#00000080',
    ); // Semi-transparent black background
    await _player.setProperty('sub-margin-y', '50'); // Position from bottom

    widget.onReady?.call();
  }

  /// Find MPV executable
  Future<String> _findMpvExecutable() async {
    // Check for bundled MPV first (Windows builds)
    if (Platform.isWindows) {
      try {
        // Get executable directory
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;

        // Check bundled location
        final bundledMpv = '$exeDir\\mpv\\mpv.exe';
        if (await File(bundledMpv).exists()) {
          debugPrint('✓ Found bundled MPV: $bundledMpv');
          return bundledMpv;
        }

        debugPrint('ℹ Bundled MPV not found at: $bundledMpv');
      } catch (e) {
        debugPrint('Error checking bundled MPV: $e');
      }
    }

    // Check common locations
    final locations =
        [
          'mpv', // System PATH
          'C:\\Program Files\\mpv\\mpv.exe',
          'C:\\Program Files (x86)\\mpv\\mpv.exe',
          Platform.environment['LOCALAPPDATA'] != null
              ? '${Platform.environment['LOCALAPPDATA']}\\mpv\\mpv.exe'
              : null,
        ].whereType<String>();

    for (final path in locations) {
      try {
        final file = File(path);
        if (await file.exists()) {
          debugPrint('✓ Found system MPV: $path');
          return file.path;
        }
      } catch (_) {}
    }

    debugPrint('⚠ MPV not found. Falling back to system PATH.');
    // Default to system PATH
    return 'mpv';
  }

  /// Open video file
  Future<void> open(String path) async {
    setState(() => _isBuffering = true);
    if (!_isReady) {
      await initialize();
    }
    await _player.open(path);
  }

  /// Play
  Future<void> play() async {
    await _player.play();
  }

  /// Pause
  Future<void> pause() async {
    await _player.pause();
  }

  /// Seek
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  /// Toggle play/pause
  Future<void> togglePlayPause() async {
    await _player.togglePlayPause();
  }

  /// Set volume
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume);
  }

  /// Load subtitle
  Future<void> loadSubtitle(String path) async {
    await _player.loadSubtitle(path);
  }

  void _handleMouseMove() {
    // If controls are hidden, show them
    if (!_showControls) {
      setState(() => _showControls = true);
    }

    _startHideTimer();
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    if (_isPlaying) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_isHoveringControls) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  void _onControlsHover(bool isHovering) {
    _isHoveringControls = isHovering;
    if (isHovering) {
      _hideControlsTimer?.cancel();
    } else {
      _startHideTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Update window rect
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final newRect = Rect.fromLTWH(
            0,
            0,
            constraints.maxWidth,
            constraints.maxHeight,
          );

          if (_windowRect != newRect) {
            _windowRect = newRect;

            // Resize native window if already initialized (use video rect so overlay stays visible)
            if (_isReady) {
              final r = _videoRect;
              _player.resize(
                x: r.left.toInt(),
                y: r.top.toInt(),
                width: r.width.toInt(),
                height: r.height.toInt(),
              );
            }
          }
        });

        return MouseRegion(
          onHover: (_) => _handleMouseMove(),
          child: GestureDetector(
            onTap: _handleMouseMove,
            child: Stack(
              children: [
                // Black background (MPV renders on top via child HWND)
                // Only paint black if NOT ready, otherwise paint transparent
                // to prevent Flutter from over-painting the native window
                if (!_isReady)
                  Container(color: Colors.black)
                else
                  Container(color: Colors.transparent),

                // Overlay UI - Always in tree for animation
                _buildOverlayUI(),

                // Loading indicator
                if (_isBuffering || !_isReady)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverlayUI() {
    return IgnorePointer(
      ignoring: !_showControls && _isPlaying,
      child: RepaintBoundary(
        // Optimization: Isolate overlay composition
        child: AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: Stack(
            children: [
              // Top bar — solid, height = _kOverlayTopHeight so MPV window (inset) never covers it
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _kOverlayTopHeight,
                child: Container(
                  color: const Color(0xEE000000),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
              // Bottom bar — solid, height = _kOverlayBottomHeight so MPV window never covers it
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: _kOverlayBottomHeight,
                child: Container(
                  color: const Color(0xEE000000),
                  child: MouseRegion(
                    onEnter: (_) => _onControlsHover(true),
                    onExit: (_) => _onControlsHover(false),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  _formatDuration(_position),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderThemeData(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                            overlayRadius: 12,
                                          ),
                                    ),
                                    child: Slider(
                                      value:
                                          _duration.inSeconds > 0
                                              ? _position.inSeconds /
                                                  _duration.inSeconds
                                              : 0.0,
                                      onChanged:
                                          (v) => seek(
                                            Duration(
                                              seconds:
                                                  (v * _duration.inSeconds)
                                                      .toInt(),
                                            ),
                                          ),
                                      activeColor: Colors.red,
                                      inactiveColor: Colors.white24,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _formatDuration(_duration),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.replay_10,
                                    color: Colors.white,
                                  ),
                                  onPressed:
                                      () => seek(
                                        Duration(
                                          seconds: _position.inSeconds - 10,
                                        ),
                                      ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    _isPlaying ? Icons.pause : Icons.play_arrow,
                                    color: Colors.white,
                                  ),
                                  onPressed: togglePlayPause,
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.forward_10,
                                    color: Colors.white,
                                  ),
                                  onPressed:
                                      () => seek(
                                        Duration(
                                          seconds: _position.inSeconds + 10,
                                        ),
                                      ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(
                                    Icons.subtitles,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {},
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.settings,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {},
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.fullscreen,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {},
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    iconSize: 64,
                    icon: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: togglePlayPause,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}
