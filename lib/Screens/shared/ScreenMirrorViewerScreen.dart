import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zap_share/controllers/ScreenMirrorController.dart';
import 'package:zap_share/controllers/ScreenMirrorKeyboardHandler.dart';
import 'package:zap_share/views/ScreenMirrorStreamView.dart';
import 'package:zap_share/views/ScreenMirrorControlBar.dart';
import 'package:zap_share/views/ScreenMirrorStatusViews.dart';
import 'dart:ui' as ui;

class ScreenMirrorViewerScreen extends StatefulWidget {
  final String streamUrl;
  final String deviceName;
  final String? senderIp;
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
  State<ScreenMirrorViewerScreen> createState() => _ScreenMirrorViewerScreenState();
}

class _ScreenMirrorViewerScreenState extends State<ScreenMirrorViewerScreen> {
  late final ScreenMirrorController _controller;
  late final ScreenMirrorKeyboardHandler _keyboardHandler;
  final FocusNode _keyboardFocusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();
  
  bool _isFullscreen = false;
  bool _showControls = false;
  String? _inputStatusText;
  Timer? _inputStatusTimer;

  double? _frameAspectRatio;
  double _targetWidth = 360;
  double _targetHeight = 740;
  
  Offset? _dragStart;
  Offset? _dragCurrent;

  final GlobalKey _imageKey = GlobalKey();
  static const Size _defaultWindowSize = Size(900, 650);
  static const _accentColor = Color(0xFFFFD600);

  @override
  void initState() {
    super.initState();
    _controller = ScreenMirrorController(
      streamUrl: widget.streamUrl,
      senderIp: widget.senderIp,
      onFrameUpdated: () { if (mounted) setState(() {}); },
      onError: (err) { if (mounted) setState(() {}); },
      onRatioDetected: (ratio) {
        if (_frameAspectRatio == null || (_frameAspectRatio! - ratio).abs() > 0.1) {
          _frameAspectRatio = ratio;
          _resizeWindowToMatchRatio(ratio);
        }
      },
    );
    _keyboardHandler = ScreenMirrorKeyboardHandler(
      sendControl: (action, {text}) => _controller.sendControl(action, text: text),
    );
  }

  Future<void> _resizeWindowToMatchRatio(double phoneRatio) async {
    try {
      if (Platform.isWindows) {
        await windowManager.setMinimumSize(Size.zero);
        await windowManager.setResizable(true);
        const double hPadding = 16.0;
        const double vPadding = 16.0;

        final displays = ui.PlatformDispatcher.instance.displays;
        final Size displaySize = displays.isNotEmpty
            ? Size(displays.first.size.width / displays.first.devicePixelRatio,
                displays.first.size.height / displays.first.devicePixelRatio)
            : const Size(1920, 1080);

        final double maxHeight = displaySize.height * 0.85;
        final double maxWidth = displaySize.width * 0.85;
        double windowWidth = maxWidth;
        double windowHeight = (windowWidth - hPadding) / phoneRatio + vPadding;

        if (phoneRatio <= 1.0) {
          windowHeight = maxHeight;
          windowWidth = (windowHeight - vPadding) * phoneRatio + hPadding;
        }
        if (windowHeight > maxHeight) {
          windowHeight = maxHeight;
          windowWidth = (windowHeight - vPadding) * phoneRatio + hPadding;
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

  void _disconnect() async {
    _controller.dispose();
    _keyboardHandler.dispose();
    if (Platform.isWindows) {
      if (widget.isSeparateWindow) {
        exit(0);
      } else {
        await windowManager.setResizable(true);
        await windowManager.setAspectRatio(-1);
        await windowManager.setSize(_defaultWindowSize);
        await windowManager.center();
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  bool _isMirrorMode() => Platform.isWindows;

  void _showInputStatus(String text) {
    if (!mounted) return;
    _inputStatusTimer?.cancel();
    setState(() => _inputStatusText = text);
    _inputStatusTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _inputStatusText = null);
    });
  }

  Offset? _toNormalized(Offset localPosition) {
    final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    final size = renderBox.size;
    return Offset(
      (localPosition.dx / size.width).clamp(0.0, 1.0),
      (localPosition.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _showTextInputDialog() {
    _keyboardHandler.flushTypeBuffer();
    _textController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: _accentColor.withOpacity(0.3))),
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
            hintText: 'Type here...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          ),
          onSubmitted: (value) {
            if (value.isNotEmpty) {
              _controller.sendControl('type', text: value);
              _showInputStatus('Sent: ${_keyboardHandler.summarizeText(value)}');
              Navigator.of(ctx).pop();
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.5)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _accentColor, foregroundColor: Colors.black),
            onPressed: () {
              if (_textController.text.isNotEmpty) {
                _controller.sendControl('type', text: _textController.text);
                _showInputStatus('Sent: ${_keyboardHandler.summarizeText(_textController.text)}');
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _keyboardHandler.handleKeyEvent(event, context, _showInputStatus),
        child: Stack(
          children: [
            if (_isMirrorMode())
              Positioned.fill(
                child: GestureDetector(
                  onPanStart: (details) => windowManager.startDragging(),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF101010),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.5),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.all(_isMirrorMode() ? 8 : 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_isMirrorMode() ? 32 : 0),
                child: Container(
                  color: Colors.black,
                  child: _controller.isConnecting
                      ? ScreenMirrorConnectingView(deviceName: widget.deviceName, streamUrl: widget.streamUrl, accentColor: _accentColor)
                      : _controller.error != null && _controller.currentFrame == null
                          ? ScreenMirrorErrorView(error: _controller.error ?? '', onDisconnect: _disconnect, onRetry: () => _controller.connect(), accentColor: _accentColor)
                          : ScreenMirrorStreamView(
                              currentFrame: _controller.currentFrame,
                              imageKey: _imageKey,
                              onPointerSignal: (event) {
                                if (event is PointerScrollEvent && widget.senderIp != null) {
                                  final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                                  if (renderBox != null) {
                                    final localPos = renderBox.globalToLocal(event.position);
                                    final norm = _toNormalized(localPos);
                                    if (norm != null) {
                                      _controller.sendControl('scroll', tapX: norm.dx, tapY: norm.dy, scrollDelta: event.scrollDelta.dy / 40.0);
                                    }
                                  }
                                }
                              },
                              onTapUp: (details) {
                                final norm = _toNormalized(details.localPosition);
                                if (norm != null) _controller.sendControl('click', tapX: norm.dx, tapY: norm.dy);
                              },
                              onLongPressStart: (details) {
                                final norm = _toNormalized(details.localPosition);
                                if (norm != null) _controller.sendControl('long_press', tapX: norm.dx, tapY: norm.dy);
                              },
                              onPanStart: (details) {
                                final norm = _toNormalized(details.localPosition);
                                if (norm != null) {
                                  _dragStart = norm;
                                  _dragCurrent = norm;
                                }
                              },
                              onPanUpdate: (details) {
                                final norm = _toNormalized(details.localPosition);
                                if (norm != null) _dragCurrent = norm;
                              },
                              onPanEnd: (details) {
                                if (_dragStart != null && _dragCurrent != null) {
                                  final dx = _dragCurrent!.dx - _dragStart!.dx;
                                  final dy = _dragCurrent!.dy - _dragStart!.dy;
                                  if (sqrt(dx * dx + dy * dy) > 0.05) {
                                    _controller.sendControl('swipe', tapX: _dragStart!.dx, tapY: _dragStart!.dy, endX: _dragCurrent!.dx, endY: _dragCurrent!.dy, duration: 400);
                                  }
                                }
                                _dragStart = null;
                                _dragCurrent = null;
                              },
                            ),
                ),
              ),
            ),
            ScreenMirrorControlBar(
              showControls: _showControls,
              isFullscreen: _isFullscreen,
              remoteInputEnabled: _keyboardHandler.remoteInputEnabled,
              inputStatusText: _inputStatusText,
              senderIp: widget.senderIp,
              onDisconnect: _disconnect,
              onToggleControls: () {
                setState(() => _showControls = !_showControls);
                _keyboardFocusNode.requestFocus();
              },
              onTextInputDialog: _showTextInputDialog,
              onToggleRemoteInput: () {
                if (_keyboardHandler.remoteInputEnabled) _keyboardHandler.flushTypeBuffer();
                setState(() => _keyboardHandler.remoteInputEnabled = !_keyboardHandler.remoteInputEnabled);
                _showInputStatus(_keyboardHandler.remoteInputEnabled ? 'Remote input on' : 'Remote input paused');
                if (_keyboardHandler.remoteInputEnabled) _keyboardFocusNode.requestFocus();
              },
              onSendControl: (action) => _controller.sendControl(action),
              accentColor: _accentColor,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    _textController.dispose();
    _inputStatusTimer?.cancel();
    _controller.dispose();
    _keyboardHandler.dispose();
    super.dispose();
  }
}
