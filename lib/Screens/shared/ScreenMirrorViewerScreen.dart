import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zap_share/services/device_discovery_service.dart';

/// Displays a live MJPEG stream from an Android device's screen mirror server.
/// Supports full mouse control (click, right-click, scroll, drag) and keyboard input.
class ScreenMirrorViewerScreen extends StatefulWidget {
  final String streamUrl;
  final String deviceName;
  /// IP of the Android device that is mirroring (for sending control commands)
  final String? senderIp;

  const ScreenMirrorViewerScreen({
    super.key,
    required this.streamUrl,
    required this.deviceName,
    this.senderIp,
  });

  @override
  State<ScreenMirrorViewerScreen> createState() =>
      _ScreenMirrorViewerScreenState();
}

class _ScreenMirrorViewerScreenState extends State<ScreenMirrorViewerScreen> {
  Uint8List? _currentFrame;
  bool _isConnected = false;
  bool _isConnecting = true;
  String? _error;
  HttpClient? _httpClient;
  int _frameCount = 0;
  int _droppedFrames = 0;
  DateTime? _startTime;
  DateTime? _lastFrameTime;
  bool _isFullscreen = false;
  bool _showControls = false;
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  final FocusNode _keyboardFocusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();

  // Audio playback
  Player? _audioPlayer;
  bool _isMuted = false;
  bool _audioAvailable = false;

  // Auto-reconnect
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  Timer? _reconnectTimer;
  Timer? _idleTimer;
  bool _isDisposed = false;

  // Frame rate throttling
  DateTime? _lastFrameRender;
  static const _minFrameInterval = Duration(milliseconds: 16); // ~60fps cap

  // Drag tracking
  Offset? _dragStart;
  bool _isDragging = false;

  // Image rendering key for getting render box size
  final GlobalKey _imageKey = GlobalKey();

  static const _accentColor = Color(0xFFFFD600);

  @override
  void initState() {
    super.initState();
    _connect();
    _connectAudio();
  }

  /// Derive the audio stream URL from the video stream URL
  String get _audioUrl {
    final uri = Uri.parse(widget.streamUrl);
    return '${uri.scheme}://${uri.host}:${uri.port}/audio';
  }

  /// Start audio playback from the Android device's audio capture stream
  Future<void> _connectAudio() async {
    try {
      _audioPlayer = Player();
      await _audioPlayer!.open(Media(_audioUrl));
      await _audioPlayer!.setVolume(100);
      if (mounted && !_isDisposed) {
        setState(() => _audioAvailable = true);
      }
      debugPrint('🔊 Audio stream connected: $_audioUrl');
    } catch (e) {
      debugPrint('🔇 Audio stream not available: $e');
      // Audio is optional — don't fail if not available
      _audioPlayer?.dispose();
      _audioPlayer = null;
      if (mounted && !_isDisposed) {
        setState(() => _audioAvailable = false);
      }
    }
  }

  Future<void> _connect() async {
    if (_isDisposed) return;
    setState(() {
      _isConnecting = true;
      _error = null;
    });

    try {
      _httpClient?.close(force: true);
      _httpClient = HttpClient();
      _httpClient!.connectionTimeout = const Duration(seconds: 10);
      _httpClient!.idleTimeout = const Duration(seconds: 60);

      final request = await _httpClient!.getUrl(Uri.parse(widget.streamUrl));
      request.headers.set('Connection', 'keep-alive');
      final response = await request.close();

      if (_isDisposed || !mounted) return;

      if (response.statusCode != 200) {
        throw HttpException('Server returned ${response.statusCode}');
      }

      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _startTime = DateTime.now();
        _reconnectAttempts = 0;
      });

      _resetIdleTimer();

      List<int> buffer = [];

      await for (final chunk in response) {
        if (_isDisposed || !mounted) break;
        buffer.addAll(chunk);

        // Find JPEG frames by SOI (FF D8) and EOI (FF D9) markers
        while (true) {
          final jpegStart = _findMarker(buffer, 0xFF, 0xD8);
          if (jpegStart == -1) break;

          final jpegEnd = _findMarker(buffer, 0xFF, 0xD9, jpegStart + 2);
          if (jpegEnd == -1) break;

          final frameEnd = jpegEnd + 2;
          if (frameEnd <= buffer.length) {
            final frame = Uint8List.fromList(buffer.sublist(jpegStart, frameEnd));
            _frameCount++;
            _lastFrameTime = DateTime.now();
            _resetIdleTimer();

            // Frame rate throttle
            final now = DateTime.now();
            if (_lastFrameRender != null &&
                now.difference(_lastFrameRender!) < _minFrameInterval) {
              _droppedFrames++;
            } else {
              _lastFrameRender = now;
              if (mounted) {
                setState(() => _currentFrame = frame);
              }
            }
          }

          buffer = buffer.sublist(frameEnd);
        }

        // Prevent buffer from growing unbounded (4MB limit)
        if (buffer.length > 4 * 1024 * 1024) {
          buffer = [];
        }
      }

      if (mounted && !_isDisposed) {
        setState(() {
          _isConnected = false;
          _error = 'Stream ended';
        });
        _scheduleReconnect();
      }
    } on SocketException catch (e) {
      debugPrint('❌ MJPEG socket error: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _error = 'Connection failed: ${e.message}';
        });
        _scheduleReconnect();
      }
    } on HttpException catch (e) {
      debugPrint('❌ MJPEG HTTP error: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _error = 'Server error: ${e.message}';
        });
        _scheduleReconnect();
      }
    } catch (e) {
      debugPrint('❌ MJPEG stream error: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _error = e.toString();
        });
        _scheduleReconnect();
      }
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !_isDisposed && _isConnected) {
        debugPrint('⚠️ No frames for 8s, reconnecting...');
        setState(() {
          _isConnected = false;
          _error = 'Stream stalled — reconnecting...';
        });
        _httpClient?.close(force: true);
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_isDisposed || _reconnectAttempts >= _maxReconnectAttempts) {
      if (mounted) {
        setState(() {
          _error = 'Connection lost after $_reconnectAttempts attempts. Tap Retry to reconnect.';
        });
      }
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts.clamp(1, 5));
    debugPrint('🔄 Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (mounted && !_isDisposed) {
        _connect();
      }
    });
  }

  int _findMarker(List<int> data, int byte1, int byte2, [int start = 0]) {
    for (int i = start; i < data.length - 1; i++) {
      if (data[i] == byte1 && data[i + 1] == byte2) return i;
    }
    return -1;
  }

  void _disconnect() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    _httpClient?.close(force: true);
    _httpClient = null;
    _audioPlayer?.dispose();
    _audioPlayer = null;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _reconnect() {
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    _httpClient?.close(force: true);
    _httpClient = null;
    _frameCount = 0;
    _droppedFrames = 0;
    _currentFrame = null;
    _reconnectAttempts = 0;
    _connect();
  }

  String get _fps {
    if (_startTime == null || _frameCount == 0) return '0';
    final elapsed = DateTime.now().difference(_startTime!).inSeconds;
    if (elapsed == 0) return '0';
    return (_frameCount / elapsed).toStringAsFixed(1);
  }

  String get _statusText {
    if (!_isConnected && _reconnectAttempts > 0) {
      return 'Reconnecting ($_reconnectAttempts/$_maxReconnectAttempts)';
    }
    return '$_fps fps • $_frameCount frames';
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    _httpClient?.close(force: true);
    _keyboardFocusNode.dispose();
    _textController.dispose();
    _audioPlayer?.dispose();
    _audioPlayer = null;
    super.dispose();
  }

  // ─── Control Helpers ───────────────────────────────────────────

  void _sendControl(String action, {
    double? tapX,
    double? tapY,
    double? endX,
    double? endY,
    String? text,
    double? scrollDelta,
    int? duration,
  }) {
    if (widget.senderIp != null) {
      _discoveryService.sendScreenMirrorControl(
        widget.senderIp!,
        action,
        tapX: tapX,
        tapY: tapY,
        endX: endX,
        endY: endY,
        text: text,
        scrollDelta: scrollDelta,
        duration: duration,
      );
    }
  }

  /// Convert a local pixel position on the image widget to normalized (0-1) coordinates
  Offset? _toNormalized(Offset localPosition) {
    final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    final size = renderBox.size;
    final nx = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final ny = (localPosition.dy / size.height).clamp(0.0, 1.0);
    return Offset(nx, ny);
  }

  void _onTapOnStream(TapUpDetails details) {
    final norm = _toNormalized(details.localPosition);
    if (norm != null) {
      _sendControl('click', tapX: norm.dx, tapY: norm.dy);
    }
  }

  void _onLongPress(LongPressStartDetails details) {
    final norm = _toNormalized(details.localPosition);
    if (norm != null) {
      _sendControl('long_press', tapX: norm.dx, tapY: norm.dy);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && widget.senderIp != null) {
      final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;
      final localPos = renderBox.globalToLocal(event.position);
      final size = renderBox.size;
      final nx = (localPos.dx / size.width).clamp(0.0, 1.0);
      final ny = (localPos.dy / size.height).clamp(0.0, 1.0);
      // scrollDelta: positive = scroll up, negative = scroll down
      final delta = -event.scrollDelta.dy / 200.0;
      _sendControl('scroll', tapX: nx, tapY: ny, scrollDelta: delta);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (widget.senderIp == null) return;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _sendControl('key', text: 'enter');
    } else if (key == LogicalKeyboardKey.backspace) {
      _sendControl('key', text: 'backspace');
    } else if (key == LogicalKeyboardKey.delete) {
      _sendControl('key', text: 'delete');
    } else if (key == LogicalKeyboardKey.tab) {
      _sendControl('key', text: 'tab');
    } else if (key == LogicalKeyboardKey.escape) {
      _sendControl('key', text: 'escape');
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _sendControl('key', text: 'up');
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _sendControl('key', text: 'down');
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _sendControl('key', text: 'left');
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _sendControl('key', text: 'right');
    } else if (key == LogicalKeyboardKey.space) {
      _sendControl('key', text: 'space');
    } else {
      final char = event.character;
      if (char != null && char.isNotEmpty) {
        _sendControl('type', text: char);
      }
    }
  }

  void _showTextInputDialog() {
    _textController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _accentColor.withOpacity(0.3)),
        ),
        title: Row(
          children: [
            Icon(Icons.keyboard_rounded, color: _accentColor, size: 22),
            const SizedBox(width: 10),
            Text('Type Text', style: GoogleFonts.spaceGrotesk(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
        content: TextField(
          controller: _textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Type here and press Send...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _accentColor.withOpacity(0.5)),
            ),
          ),
          onSubmitted: (value) {
            if (value.isNotEmpty) {
              _sendControl('type', text: value);
              Navigator.of(ctx).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _accentColor,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              final text = _textController.text;
              if (text.isNotEmpty) {
                _sendControl('type', text: text);
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _isFullscreen
            ? null
            : AppBar(
                backgroundColor: const Color(0xFF0A0A0A),
                foregroundColor: Colors.white,
                elevation: 0,
                title: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isConnected ? Colors.green : Colors.red,
                        boxShadow: [
                          BoxShadow(
                            color: (_isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.deviceName,
                        style: GoogleFonts.spaceGrotesk(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (_isConnected || _reconnectAttempts > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _statusText,
                            style: TextStyle(
                              color: _isConnected ? Colors.white38 : Colors.orange,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.senderIp != null) ...[
                    IconButton(
                      icon: Icon(
                        Icons.keyboard_rounded,
                        color: Colors.white.withOpacity(0.7),
                        size: 20,
                      ),
                      onPressed: _showTextInputDialog,
                      tooltip: 'Type Text',
                    ),
                    IconButton(
                      icon: Icon(
                        _showControls ? Icons.gamepad_rounded : Icons.gamepad_outlined,
                        color: _showControls ? _accentColor : Colors.white.withOpacity(0.7),
                        size: 20,
                      ),
                      onPressed: () => setState(() => _showControls = !_showControls),
                      tooltip: 'Quick Controls',
                    ),
                  ],
                  // Audio mute/unmute toggle
                  if (_audioAvailable)
                    IconButton(
                      icon: Icon(
                        _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: _isMuted ? Colors.red.withOpacity(0.7) : _accentColor.withOpacity(0.9),
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() => _isMuted = !_isMuted);
                        _audioPlayer?.setVolume(_isMuted ? 0 : 100);
                      },
                      tooltip: _isMuted ? 'Unmute Audio' : 'Mute Audio',
                    ),
                  IconButton(
                    icon: Icon(Icons.fullscreen_rounded, size: 22, color: Colors.white.withOpacity(0.7)),
                    onPressed: () => setState(() => _isFullscreen = true),
                    tooltip: 'Fullscreen',
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 20, color: Colors.white.withOpacity(0.7)),
                    onPressed: _disconnect,
                    tooltip: 'Disconnect',
                  ),
                ],
              ),
        body: Stack(
          children: [
            GestureDetector(
              onTap: () {
                if (_isFullscreen) {
                  setState(() => _isFullscreen = false);
                }
                _keyboardFocusNode.requestFocus();
              },
              child: _buildBody(),
            ),
            if (_showControls && widget.senderIp != null)
              _buildControlPanel(),
            if (widget.senderIp != null && _isConnected && !_showControls)
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Click on screen to control  •  Scroll to scroll  •  Type with keyboard${_audioAvailable ? "  •  🔊 Audio" : ""}',
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.white.withOpacity(0.3),
                        fontSize: 10,
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

  Widget _buildBody() {
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Color(0xFFFFD600),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Connecting to ${widget.deviceName}...',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.streamUrl,
              style: const TextStyle(
                color: Colors.white30,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null && _currentFrame == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: Colors.red.withOpacity(0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Connection Failed',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 13),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Go Back'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white60,
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _reconnect,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD600),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_currentFrame != null) {
      return Center(
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            onTapUp: _onTapOnStream,
            onLongPressStart: _onLongPress,
            onPanStart: (details) {
              final norm = _toNormalized(details.localPosition);
              if (norm != null) {
                _dragStart = norm;
                _isDragging = true;
              }
            },
            onPanEnd: (details) {
              if (_dragStart != null) {
                final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                if (renderBox != null) {
                  final velocity = details.velocity.pixelsPerSecond;
                  final size = renderBox.size;
                  if (velocity.distance > 100) {
                    final endNx = (_dragStart!.dx + velocity.dx / size.width * 0.1).clamp(0.0, 1.0);
                    final endNy = (_dragStart!.dy + velocity.dy / size.height * 0.1).clamp(0.0, 1.0);
                    _sendControl('swipe',
                      tapX: _dragStart!.dx,
                      tapY: _dragStart!.dy,
                      endX: endNx,
                      endY: endNy,
                      duration: 300,
                    );
                  }
                }
              }
              _dragStart = null;
              _isDragging = false;
            },
            child: Image.memory(
              _currentFrame!,
              key: _imageKey,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      );
    }

    return const Center(
      child: Text(
        'Waiting for frames...',
        style: TextStyle(color: Colors.white38),
      ),
    );
  }

  Widget _buildControlPanel() {
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xF0101012),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _accentColor.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'QUICK CONTROLS',
                style: GoogleFonts.spaceGrotesk(
                  color: _accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 12),
              // Row 1: Navigation
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildControlBtn(
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => _sendControl('back'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.circle_outlined,
                    label: 'Home',
                    onTap: () => _sendControl('home'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.crop_square_rounded,
                    label: 'Recents',
                    onTap: () => _sendControl('recents'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.power_settings_new_rounded,
                    label: 'Power',
                    onTap: () => _sendControl('power'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Row 2: Volume & Scroll
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildControlBtn(
                    icon: Icons.volume_down_rounded,
                    label: 'Vol -',
                    onTap: () => _sendControl('volume_down'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.volume_up_rounded,
                    label: 'Vol +',
                    onTap: () => _sendControl('volume_up'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.keyboard_arrow_up_rounded,
                    label: 'Scroll ↑',
                    onTap: () => _sendControl('scroll_up'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.keyboard_arrow_down_rounded,
                    label: 'Scroll ↓',
                    onTap: () => _sendControl('scroll_down'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Row 3: Keyboard, Notifications, Brightness
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildControlBtn(
                    icon: Icons.keyboard_rounded,
                    label: 'Type',
                    onTap: _showTextInputDialog,
                    highlight: true,
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.notifications_none_rounded,
                    label: 'Notify',
                    onTap: () => _sendControl('notifications'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.brightness_low_rounded,
                    label: 'Bright -',
                    onTap: () => _sendControl('brightness_down'),
                  ),
                  const SizedBox(width: 10),
                  _buildControlBtn(
                    icon: Icons.brightness_high_rounded,
                    label: 'Bright +',
                    onTap: () => _sendControl('brightness_up'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: highlight
                  ? _accentColor.withOpacity(0.15)
                  : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: highlight
                    ? _accentColor.withOpacity(0.4)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Icon(
              icon,
              color: highlight ? _accentColor : Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.spaceGrotesk(
              color: highlight ? _accentColor.withOpacity(0.8) : Colors.white54,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
