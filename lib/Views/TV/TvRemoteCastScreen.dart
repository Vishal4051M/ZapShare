import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/modules/remote_p2p/controllers/RemoteP2PController.dart';
import 'package:zap_share/modules/remote_p2p/models/P2PSessionModel.dart';

/// TV Remote Cast by Code — joins a remote P2P session and renders the
/// received video/audio stream via RTCVideoRenderer.
class TvRemoteCastScreen extends StatefulWidget {
  const TvRemoteCastScreen({super.key});

  @override
  State<TvRemoteCastScreen> createState() => _TvRemoteCastScreenState();
}

class _TvRemoteCastScreenState extends State<TvRemoteCastScreen> {
  final RemoteP2PController _controller = RemoteP2PController();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final List<TextEditingController> _digitControllers =
      List.generate(8, (_) => TextEditingController());
  final List<FocusNode> _digitFocusNodes = List.generate(8, (_) => FocusNode());

  bool _joining = false;
  bool _isMuted = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _controller.initialize();
    _controller.stateStream.listen(_onSessionStateChanged);
  }

  void _onSessionStateChanged(P2PSessionModel? session) {
    if (!mounted) return;
    if (session != null &&
        session.connectionState == P2PConnectionState.connected) {
      // Attach remote stream to renderer when connected
      final stream = _controller.remoteStream;
      if (stream != null) {
        setState(() {
          _renderer.srcObject = stream;
        });
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _renderer.dispose();
    _controller.disconnect();
    for (final c in _digitControllers) {
      c.dispose();
    }
    for (final f in _digitFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String get _enteredCode =>
      _digitControllers.map((c) => c.text).join();

  Future<void> _joinSession() async {
    final code = _enteredCode;
    if (code.length != 8) {
      setState(() => _errorMessage = 'Enter all 8 digits');
      return;
    }
    setState(() {
      _joining = true;
      _errorMessage = null;
    });
    try {
      final success = await _controller.joinRoom(code);
      if (!success && mounted) {
        setState(() {
          _joining = false;
          _errorMessage = 'Room not found. Check the code and try again.';
        });
      } else {
        setState(() => _joining = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _joining = false;
          _errorMessage = 'Connection failed: $e';
        });
      }
    }
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    final stream = _controller.remoteStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
    }
  }

  void _disconnect() {
    _controller.disconnect();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E0E10), Color(0xFF08080A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: StreamBuilder<P2PSessionModel?>(
            stream: _controller.stateStream,
            initialData: _controller.activeSession,
            builder: (context, snapshot) {
              final session = snapshot.data;
              if (session == null) return _buildCodeEntryView();
              if (session.connectionState == P2PConnectionState.connecting) {
                return _buildConnectingView(session);
              }
              if (session.connectionState == P2PConnectionState.disconnected) {
                return _buildDisconnectedView();
              }
              return _buildStreamView(session);
            },
          ),
        ),
      ),
    );
  }

  // ── Code Entry View ──────────────────────────────────────────────────────

  Widget _buildCodeEntryView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const Spacer(),
          Center(
            child: Column(
              children: [
                Text(
                  'Enter 8-Digit Cast Code',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Ask the sender for their cast code',
                  style: GoogleFonts.outfit(
                    color: Colors.white54,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 40),
                // 8-digit D-pad-friendly input
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(8, (i) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 60,
                        height: 70,
                        child: Focus(
                          focusNode: _digitFocusNodes[i],
                          child: Builder(builder: (ctx) {
                            final hasFocus = Focus.of(ctx).hasFocus;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              decoration: BoxDecoration(
                                color: hasFocus
                                    ? const Color(0xFFFFD600).withValues(alpha: 0.15)
                                    : const Color(0xFF1C1C1E),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: hasFocus
                                      ? const Color(0xFFFFD600)
                                      : Colors.white.withValues(alpha: 0.1),
                                  width: 2,
                                ),
                              ),
                              child: TextField(
                                controller: _digitControllers[i],
                                focusNode: _digitFocusNodes[i],
                                maxLength: 1,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  counterText: '',
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onChanged: (val) {
                                  if (val.isNotEmpty && i < 7) {
                                    _digitFocusNodes[i + 1].requestFocus();
                                  } else if (val.isEmpty && i > 0) {
                                    _digitFocusNodes[i - 1].requestFocus();
                                  }
                                  setState(() {});
                                },
                              ),
                            );
                          }),
                        ),
                      ),
                    );
                  }),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: GoogleFonts.outfit(
                      color: const Color(0xFFFF6B6B),
                      fontSize: 14,
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                TVFocusableButton(
                  autofocus: _enteredCode.length == 8,
                  onPressed: _joining ? null : _joinSession,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 16,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  backgroundColor: const Color(0xFFFFD600),
                  child: _joining
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : Text(
                          'Join Cast',
                          style: GoogleFonts.outfit(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  // ── Connecting View ──────────────────────────────────────────────────────

  Widget _buildConnectingView(P2PSessionModel session) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Color(0xFFFFD600),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Connecting to cast session…',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Room: ${session.roomId}',
            style: GoogleFonts.outfit(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }

  // ── Stream View ──────────────────────────────────────────────────────────

  Widget _buildStreamView(P2PSessionModel session) {
    final hasVideo = _renderer.srcObject != null &&
        _renderer.srcObject!.getVideoTracks().isNotEmpty;

    return Stack(
      children: [
        // Video or waiting placeholder
        hasVideo
            ? RTCVideoView(
                _renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
            : Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.cast_connected_rounded,
                      color: Color(0xFFAA80FF),
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Connected — waiting for stream',
                      style: GoogleFonts.outfit(
                        color: Colors.white70,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Sender must start screen or audio share',
                      style: GoogleFonts.outfit(
                        color: Colors.white38,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

        // Controls overlay
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TVFocusableButton(
                onPressed: _toggleMute,
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                borderRadius: BorderRadius.circular(16),
                backgroundColor: _isMuted
                    ? const Color(0xFFFF6B6B).withValues(alpha: 0.2)
                    : const Color(0xFF1C1C1E),
                child: Row(
                  children: [
                    Icon(
                      _isMuted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: _isMuted
                          ? const Color(0xFFFF6B6B)
                          : Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isMuted ? 'Unmute' : 'Mute',
                      style: GoogleFonts.outfit(
                        color: _isMuted
                            ? const Color(0xFFFF6B6B)
                            : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              TVFocusableButton(
                onPressed: _disconnect,
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                borderRadius: BorderRadius.circular(16),
                backgroundColor: const Color(0xFF3A1A1A),
                child: Row(
                  children: [
                    const Icon(
                      Icons.call_end_rounded,
                      color: Color(0xFFFF6B6B),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Disconnect',
                      style: GoogleFonts.outfit(
                        color: const Color(0xFFFF6B6B),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Peer info badge
        Positioned(
          top: 24,
          left: 32,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cast_connected_rounded,
                  color: Color(0xFFAA80FF),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Receiving from ${session.peerName.isNotEmpty ? session.peerName : "Sender"}',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Disconnected View ────────────────────────────────────────────────────

  Widget _buildDisconnectedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.signal_wifi_connected_no_internet_4_rounded,
            color: Color(0xFFFF6B6B),
            size: 64,
          ),
          const SizedBox(height: 20),
          Text(
            'Connection Lost',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The cast session was disconnected.',
            style: GoogleFonts.outfit(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(height: 32),
          TVFocusableButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
            borderRadius: BorderRadius.circular(18),
            backgroundColor: const Color(0xFF1C1C1E),
            child: Text(
              'Go Back',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: TVFocusableButton(
            borderRadius: BorderRadius.circular(24),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 16),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Remote ',
                style: GoogleFonts.outfit(
                  color: const Color(0xFFAA80FF),
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              TextSpan(
                text: 'Cast',
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
