import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'dart:ui' as ui;

/// Displays a live MJPEG stream from an Android device's screen mirror server.
/// Supports full mouse control (click, right-click, scroll, drag) and keyboard input.
class ScreenMirrorViewerScreen extends StatefulWidget {
  final String streamUrl;
  final String deviceName;

  /// IP of the Android device that is mirroring (for sending control commands)
  final String? senderIp;

  /// Whether this is running in a dedicated separate window
  final bool isSeparateWindow;
  final double? initialWidth;
  final double? initialHeight;

  const ScreenMirrorViewerScreen({
    super.key,
    required this.streamUrl,
    required this.deviceName,
    this.senderIp,
    this.isSeparateWindow = false,
    this.initialWidth,
    this.initialHeight,
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
  bool _remoteInputEnabled = true;
  final StringBuffer _typeBuffer = StringBuffer();
  Timer? _typeBufferTimer;
  String? _inputStatusText;
  Timer? _inputStatusTimer;

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

  double? _frameAspectRatio;
  double _targetWidth = 360;
  double _targetHeight = 740;

  Offset? _dragStart;
  Offset? _dragCurrent;
  bool _isDragging = false;

  // Image rendering key for getting render box size
  final GlobalKey _imageKey = GlobalKey();

  // Store original window size to restore on back
  static const Size _defaultWindowSize = Size(900, 650);

  static const _accentColor = Color(0xFFFFD600);

  @override
  void initState() {
    super.initState();
    // Pause network discovery broadcasts to save resources for video stream processing
    _discoveryService.pauseDiscovery();
    _connect();
    _connectAudio();
  }

  /// Derive the audio stream URL from the video stream URL
  String get _audioUrl {
    final uri = Uri.parse(widget.streamUrl);
    return '${uri.scheme}://${uri.host}:${uri.port}/audio';
  }

  Future<void> _connectAudio() async {
    try {
      _audioPlayer =
          Player(); // Let media_kit handle default configuration without artificial buffers

      // Ultra-low latency ffmpeg flags
      if (_audioPlayer?.platform is NativePlayer) {
        final np = _audioPlayer?.platform as NativePlayer;

        // 1. Force low latency profile and untimed playback (no A/V sync)
        await np.setProperty('profile', 'low-latency');
        await np.setProperty('untimed', '');

        // 2. Disable caching entirely
        await np.setProperty('cache', 'no');
        await np.setProperty('cache-pause', 'no');

        // 3. Drop internal audio playback queues to minimum (but not 0 to avoid audio stutter)
        await np.setProperty('audio-buffer', '0.05');

        // 4. Force WAV demuxer immediately
        await np.setProperty('demuxer-lavf-format', 'wav');

        // 5. Bare-metal demuxer flags: valid ffmpeg key=value syntax
        await np.setProperty(
          'demuxer-lavf-o',
          'fflags=nobuffer,probesize=32,analyzeduration=0',
        );

        // 6. Hard limit any internal buffers
        await np.setProperty('demuxer-max-bytes', '4096');
        await np.setProperty('demuxer-max-back-bytes', '0');

        // 7. Fast network drop and prevent sync trailing
        await np.setProperty('hr-seek-framedrop', 'yes');
        await np.setProperty('network-timeout', '100');
      }

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

      final bytesBuilder = BytesBuilder(copy: false);
      int previousLength = 0;

      await for (final chunk in response) {
        if (_isDisposed || !mounted) break;
        bytesBuilder.add(chunk);

        // --- ANTI-LAG: Frame dropping mechanism ---
        // If our incoming buffer grows beyond ~2MB,
        // we are processing too slowly and trailing behind real-time.
        // Dump the buffer to instantly catch up to the live edge.
        if (bytesBuilder.length > 2000 * 1024) {
          debugPrint(
            '⚠️ Lag detected! Dropping ${bytesBuilder.length} bytes to catch up to live edge.',
          );
          bytesBuilder.clear();
          previousLength = 0;
          continue;
        }

        Uint8List currentBuffer = bytesBuilder.takeBytes();
        int searchOffset = 0;
        Uint8List? latestFrame;

        while (true) {
          final jpegStart = _findMarker(
            currentBuffer,
            0xFF,
            0xD8,
            searchOffset,
          );
          if (jpegStart == -1) {
            bytesBuilder.add(currentBuffer.sublist(searchOffset));
            previousLength = currentBuffer.length - searchOffset;
            break;
          }

          int startSearchingForEnd = jpegStart + 2;
          // Optimize: skip bytes we already scanned in a previous chunk iteration
          if (previousLength > startSearchingForEnd) {
            startSearchingForEnd = previousLength - 1;
          }

          final jpegEnd = _findMarker(
            currentBuffer,
            0xFF,
            0xD9,
            startSearchingForEnd,
          );
          if (jpegEnd == -1) {
            bytesBuilder.add(currentBuffer.sublist(jpegStart));
            previousLength = currentBuffer.length - jpegStart;
            break;
          }

          final frameEnd = jpegEnd + 2;
          latestFrame = Uint8List.view(
            currentBuffer.buffer,
            currentBuffer.offsetInBytes + jpegStart,
            frameEnd - jpegStart,
          );

          _frameCount++;
          searchOffset = frameEnd;
          previousLength = 0;
        }

        if (latestFrame != null) {
          _lastFrameTime = DateTime.now();
          _resetIdleTimer();

          if (mounted) {
            setState(() => _currentFrame = latestFrame);

            if (Platform.isWindows) {
              final size = _getJpegSize(latestFrame);
              if (size != null) {
                final currentPhoneRatio = size.width / size.height;
                if (_frameAspectRatio == null ||
                    (_frameAspectRatio! - currentPhoneRatio).abs() > 0.1) {
                  _frameAspectRatio = currentPhoneRatio;
                  _resizeWindowToMatchRatio(currentPhoneRatio);
                }
              }
            }
          }
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
          _error =
              'Connection lost after $_reconnectAttempts attempts. Tap Retry to reconnect.';
        });
      }
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts.clamp(1, 5));
    debugPrint(
      '🔄 Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)',
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (mounted && !_isDisposed) {
        _connect();
      }
    });
  }

  Size? _getJpegSize(Uint8List bytes) {
    int offset = 2; // Skip FFD8
    while (offset < bytes.length - 8) {
      if (bytes[offset] == 0xFF) {
        int marker = bytes[offset + 1];
        if (marker == 0xC0 || marker == 0xC2) {
          // SOF0 or SOF2
          int height = (bytes[offset + 5] << 8) | bytes[offset + 6];
          int width = (bytes[offset + 7] << 8) | bytes[offset + 8];
          return Size(width.toDouble(), height.toDouble());
        } else if (marker == 0xD8 ||
            marker == 0xD9 ||
            marker == 0x00 ||
            (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
        } else {
          int length = (bytes[offset + 2] << 8) | bytes[offset + 3];
          offset += 2 + length;
        }
      } else {
        offset++;
      }
    }
    return null;
  }

  Future<void> _resizeWindowToMatchRatio(double phoneRatio) async {
    try {
      if (Platform.isWindows) {
        await windowManager.setMinimumSize(Size.zero);
        await windowManager.setResizable(true);

        const double hPadding = 16.0; // 8px each side
        const double vPadding = 16.0; // 8px top/bottom

        // Use primary display size as bounds via dart:ui
        final displays = ui.PlatformDispatcher.instance.displays;
        final Size displaySize;
        if (displays.isNotEmpty) {
          final display = displays.first;
          displaySize = Size(
            display.size.width / display.devicePixelRatio,
            display.size.height / display.devicePixelRatio,
          );
        } else {
          // Fallback if displays are not immediately accessible
          displaySize = const Size(1920, 1080);
        }

        final double maxHeight = displaySize.height * 0.85;
        final double maxWidth = displaySize.width * 0.85;

        double windowWidth;
        double windowHeight;

        if (phoneRatio > 1.0) {
          // Landscape
          windowWidth = maxWidth;
          double targetInnerWidth = windowWidth - hPadding;
          double targetInnerHeight = targetInnerWidth / phoneRatio;
          windowHeight = targetInnerHeight + vPadding;

          if (windowHeight > maxHeight) {
            windowHeight = maxHeight;
            targetInnerHeight = windowHeight - vPadding;
            targetInnerWidth = targetInnerHeight * phoneRatio;
            windowWidth = targetInnerWidth + hPadding;
          }
        } else {
          // Portrait
          windowHeight = maxHeight;
          double targetInnerHeight = windowHeight - vPadding;
          double targetInnerWidth = targetInnerHeight * phoneRatio;
          windowWidth = targetInnerWidth + hPadding;

          if (windowWidth > maxWidth) {
            windowWidth = maxWidth;
            targetInnerWidth = windowWidth - hPadding;
            targetInnerHeight = targetInnerWidth / phoneRatio;
            windowHeight = targetInnerHeight + vPadding;
          }
        }

        if (mounted) {
          setState(() {
            _targetWidth = windowWidth - hPadding;
            _targetHeight = windowHeight - vPadding;
          });
        }

        await windowManager.setAspectRatio(windowWidth / windowHeight);
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await windowManager.setSize(Size(windowWidth, windowHeight));
        await windowManager.setResizable(false);
        await windowManager.center();
      }
    } catch (e) {
      debugPrint('Error resizing window: $e');
    }
  }

  int _findMarker(Uint8List data, int byte1, int byte2, [int start = 0]) {
    final len = data.length - 1;
    for (int i = start; i < len; i++) {
      if (data[i] == byte1 && data[i + 1] == byte2) return i;
    }
    return -1;
  }

  void _disconnect() async {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    _httpClient?.close(force: true);
    _httpClient = null;
    _audioPlayer?.dispose();
    _audioPlayer = null;

    // Resume discovery broadcasts when closing mirror viewer
    _discoveryService.resumeDiscovery();

    if (Platform.isWindows) {
      if (widget.isSeparateWindow) {
        exit(0); // Close the process for the separate mirror window
      } else {
        // Restore normal window size before leaving
        await windowManager.setResizable(true);
        await windowManager.setAspectRatio(-1); // Reset aspect ratio
        await windowManager.setSize(_defaultWindowSize);
        await windowManager.center();
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
        ); // Restore title bar
      }
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  bool _isMirrorMode() {
    return Platform
        .isWindows; // Always use phone UI on Windows when this screen is active
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

  double get _fps {
    if (_startTime == null || _frameCount == 0) return 0.0;
    final elapsed = DateTime.now().difference(_startTime!).inSeconds;
    if (elapsed == 0) return 0.0;
    return _frameCount / elapsed;
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
    _typeBufferTimer?.cancel();
    _inputStatusTimer?.cancel();
    _audioPlayer?.dispose();
    _audioPlayer = null;

    // Safety check: ensure discovery resumes if unmounted unexpectedly
    _discoveryService.resumeDiscovery();

    super.dispose();
  }

  // ─── Control Helpers ───────────────────────────────────────────

  void _sendControl(
    String action, {
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
    final renderBox =
        _imageKey.currentContext?.findRenderObject() as RenderBox?;
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
      _keyboardFocusNode.requestFocus();
    }
  }

  void _onLongPress(LongPressStartDetails details) {
    final norm = _toNormalized(details.localPosition);
    if (norm != null) {
      _sendControl('long_press', tapX: norm.dx, tapY: norm.dy);
      _keyboardFocusNode.requestFocus();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && widget.senderIp != null) {
      final renderBox =
          _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;
      final localPos = renderBox.globalToLocal(event.position);
      final size = renderBox.size;
      final nx = (localPos.dx / size.width).clamp(0.0, 1.0);
      final ny = (localPos.dy / size.height).clamp(0.0, 1.0);
      // REVERSED scroll: positive is now down, matching Windows scroll feel
      final delta = event.scrollDelta.dy / 40.0;
      _sendControl('scroll', tapX: nx, tapY: ny, scrollDelta: delta);
      _keyboardFocusNode.requestFocus();
    }
  }

  void _queueTypedText(String text) {
    if (text.isEmpty) return;
    _typeBuffer.write(text);
    _typeBufferTimer?.cancel();
    _typeBufferTimer = Timer(const Duration(milliseconds: 60), () {
      _flushTypeBuffer();
    });
  }

  void _flushTypeBuffer() {
    if (_typeBuffer.isEmpty) return;
    final text = _typeBuffer.toString();
    _typeBuffer.clear();
    _sendControl('type', text: text);
    _showInputStatus('Typed: ${_summarizeText(text)}');
  }

  String _summarizeText(String text) {
    final compact = text.replaceAll('\n', ' ').trim();
    if (compact.length <= 18) return compact;
    return '${compact.substring(0, 18)}...';
  }

  void _showInputStatus(
    String text, {
    Duration duration = const Duration(milliseconds: 1200),
  }) {
    if (!mounted) return;
    _inputStatusTimer?.cancel();
    setState(() => _inputStatusText = text);
    _inputStatusTimer = Timer(duration, () {
      if (mounted) setState(() => _inputStatusText = null);
    });
  }

  void _toggleRemoteInput() {
    if (_remoteInputEnabled) {
      _flushTypeBuffer();
    }
    setState(() => _remoteInputEnabled = !_remoteInputEnabled);
    _showInputStatus(
      _remoteInputEnabled ? 'Remote input on' : 'Remote input paused',
    );
    if (_remoteInputEnabled) {
      _keyboardFocusNode.requestFocus();
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (widget.senderIp == null) return;
    if (!_remoteInputEnabled) return;

    // Ignore global keyboard presses if a dialog is open (e.g. typing text dialog)
    if (ModalRoute.of(context)?.isCurrent != true) return;

    final key = event.logicalKey;
    final char = event.character;
    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    debugPrint('⌨️ [Mirror] Key Event: ${key.debugName} | Char: $char');

    if (isCtrl && key == LogicalKeyboardKey.keyV) {
      _flushTypeBuffer();
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        final text = data?.text ?? '';
        if (text.isEmpty) return;
        _sendControl('type', text: text);
        _showInputStatus('Pasted: ${_summarizeText(text)}');
      });
      return;
    }

    // Control keys mapping
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _flushTypeBuffer();
      _sendControl('key', text: 'enter');
      _showInputStatus('Sent: Enter');
    } else if (key == LogicalKeyboardKey.backspace) {
      _flushTypeBuffer();
      _sendControl('key', text: 'backspace');
      _showInputStatus('Sent: Backspace');
    } else if (key == LogicalKeyboardKey.space) {
      _queueTypedText(' ');
    } else if (key == LogicalKeyboardKey.tab) {
      _flushTypeBuffer();
      _sendControl('key', text: 'tab');
      _showInputStatus('Sent: Tab');
    } else if (key == LogicalKeyboardKey.delete) {
      _flushTypeBuffer();
      _sendControl('key', text: 'delete');
      _showInputStatus('Sent: Delete');
    } else if (key == LogicalKeyboardKey.escape) {
      _flushTypeBuffer();
      _sendControl('key', text: 'escape');
      _showInputStatus('Sent: Escape');
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _flushTypeBuffer();
      _sendControl('key', text: 'up');
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _flushTypeBuffer();
      _sendControl('key', text: 'down');
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _flushTypeBuffer();
      _sendControl('key', text: 'left');
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _flushTypeBuffer();
      _sendControl('key', text: 'right');
    } else if (char != null && char.isNotEmpty && !isCtrl && !isAlt) {
      _queueTypedText(char);
    }
  }

  void _showTextInputDialog() {
    _flushTypeBuffer();
    _textController.clear();
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: _accentColor.withOpacity(0.3)),
            ),
            title: Row(
              children: [
                Icon(Icons.keyboard_rounded, color: _accentColor, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Type Text',
                  style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
                  _showInputStatus('Sent: ${_summarizeText(value)}');
                  Navigator.of(ctx).pop();
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  final text = _textController.text;
                  if (text.isNotEmpty) {
                    _sendControl('type', text: text);
                    _showInputStatus('Sent: ${_summarizeText(text)}');
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
        backgroundColor: Colors.transparent,
        body: Focus(
          autofocus: true,
          onFocusChange: (focused) {
            if (!focused) _keyboardFocusNode.requestFocus();
          },
          child: Stack(
            children: [
              // 1. Phone Frame (Fills whole window now)
              if (_isMirrorMode())
                Positioned.fill(
                  child: GestureDetector(
                    onPanStart: (details) => windowManager.startDragging(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF101010),
                        borderRadius: BorderRadius.circular(40),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.12),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),

              // 2. The Mirror Content (Now fills almost entire window)
              Padding(
                padding: EdgeInsets.all(_isMirrorMode() ? 8 : 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_isMirrorMode() ? 32 : 0),
                  child: Container(color: Colors.black, child: _buildBody()),
                ),
              ),

              // 3. Floating Overlay Controls
              if (!_isFullscreen)
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Only show Close button when controls are toggled on
                      if (_showControls)
                        _buildGlassBtn(
                          icon: Icons.close_rounded,
                          onTap: _disconnect,
                          tooltip: 'Close',
                        )
                      else
                        const SizedBox.shrink(),

                      // Primary toggle button
                      _buildGlassBtn(
                        icon:
                            _showControls
                                ? Icons.grid_view_rounded
                                : Icons.grid_view_outlined,
                        onTap: () {
                          setState(() => _showControls = !_showControls);
                          _keyboardFocusNode.requestFocus();
                        },
                        highlight: _showControls,
                        tooltip: 'Controls',
                      ),
                    ],
                  ),
                ),

              if (_showControls && widget.senderIp != null && !_isFullscreen)
                _buildBottomNavigationBar(),
              if (_inputStatusText != null)
                Positioned(
                  top: _showControls ? 64 : 16,
                  right: 16,
                  child: _buildInputStatusPill(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return Positioned(
      bottom: 24,
      left: 12, // give it a little breathing room from the edges
      right: 12,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _buildNavBtn(
                        Icons.arrow_back_ios_new_rounded,
                        () => _sendControl('back'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.circle_outlined,
                        () => _sendControl('home'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.crop_square_rounded,
                        () => _sendControl('recents'),
                      ),
                    ),
                    Expanded(
                      child: _buildNavBtn(
                        Icons.keyboard_rounded,
                        _showTextInputDialog,
                        onLongPress: _toggleRemoteInput,
                        highlight: _remoteInputEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavBtn(
    IconData icon,
    VoidCallback onTap, {
    VoidCallback? onLongPress,
    bool highlight = false,
  }) {
    final iconColor = highlight ? _accentColor : Colors.white.withOpacity(0.85);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: Colors.transparent, // to increase tap target
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: iconColor, size: 24),
      ),
    );
  }

  Widget _buildInputStatusPill() {
    final text = _inputStatusText;
    if (text == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.keyboard_rounded, color: _accentColor, size: 16),
              const SizedBox(width: 6),
              Text(
                text,
                style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlassBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool highlight = false,
    String? tooltip,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:
                  highlight
                      ? _accentColor.withOpacity(0.2)
                      : Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color:
                    highlight
                        ? _accentColor.withOpacity(0.4)
                        : Colors.white.withOpacity(0.2),
              ),
            ),
            child: Icon(
              icon,
              color: highlight ? _accentColor : Colors.white,
              size: 20,
            ),
          ),
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
      return SizedBox.expand(
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            onTapUp: _onTapOnStream,
            onSecondaryTapUp: (details) {
              _sendControl('back');
            },
            onLongPressStart: _onLongPress,
            onPanStart: (details) {
              final norm = _toNormalized(details.localPosition);
              if (norm != null) {
                _dragStart = norm;
                _dragCurrent = norm;
                _isDragging = true;
              }
            },
            onPanUpdate: (details) {
              final norm = _toNormalized(details.localPosition);
              if (norm != null) {
                _dragCurrent = norm;
              }
            },
            onPanEnd: (details) {
              if (_dragStart != null && _dragCurrent != null) {
                final dx = _dragCurrent!.dx - _dragStart!.dx;
                final dy = _dragCurrent!.dy - _dragStart!.dy;
                final dist = sqrt(dx * dx + dy * dy);

                // If moved meaningfully, perform a swipe/drag
                if (dist > 0.05) {
                  _sendControl(
                    'swipe',
                    tapX: _dragStart!.dx,
                    tapY: _dragStart!.dy,
                    endX: _dragCurrent!.dx,
                    endY: _dragCurrent!.dy,
                    duration: 400,
                  );
                }
              }
              _dragStart = null;
              _dragCurrent = null;
              _isDragging = false;
            },
            child: Image.memory(
              _currentFrame!,
              key: _imageKey,
              gaplessPlayback: true,
              fit: BoxFit.fill, // Exact fill now that ratios are synced
              filterQuality: FilterQuality.high,
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
}
