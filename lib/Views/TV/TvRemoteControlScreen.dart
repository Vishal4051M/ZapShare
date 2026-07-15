import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/widgets/tv_widgets.dart';
import 'package:zap_share/services/device_discovery_service.dart';

/// TV-optimized cast remote control screen.
/// Displayed on the TV when connected as a cast RECEIVER,
/// providing D-Pad-navigable playback controls.
class TvRemoteControlScreen extends StatefulWidget {
  final String targetDeviceIp;
  final String targetDeviceName;
  final String fileName;

  const TvRemoteControlScreen({
    super.key,
    required this.targetDeviceIp,
    required this.targetDeviceName,
    required this.fileName,
  });

  @override
  State<TvRemoteControlScreen> createState() => _TvRemoteControlScreenState();
}

class _TvRemoteControlScreenState extends State<TvRemoteControlScreen> {
  final DeviceDiscoveryService _discoveryService = DeviceDiscoveryService();
  StreamSubscription<CastStatus>? _statusSub;
  Timer? _syncTimer;

  double _position = 0;
  double _duration = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;
  double _volume = 1.0;
  bool _connected = false;
  DateTime? _lastStatusUpdate;

  @override
  void initState() {
    super.initState();
    _initStatusStream();
  }

  void _initStatusStream() {
    _statusSub = _discoveryService.castStatusStream.listen((status) {
      if (!mounted) return;
      if (status.senderIp == widget.targetDeviceIp) {
        if (!status.active) {
          setState(() => _connected = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cast sender disconnected')),
          );
          Navigator.of(context).pop();
          return;
        }
        setState(() {
          final now = DateTime.now().millisecondsSinceEpoch;
          final sentAt = status.timestamp ?? now;
          final latency = (now - sentAt) / 1000.0;
          _position = status.position + (status.isPlaying ? latency : 0.0);
          _duration = status.duration;
          _isPlaying = status.isPlaying;
          _isBuffering = status.isBuffering;
          _volume = status.volume;
          _connected = true;
          _lastStatusUpdate = DateTime.now();
        });
      }
    });

    // Periodic ping + watchdog
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _sendControl('ping');
      if (_connected &&
          _lastStatusUpdate != null &&
          DateTime.now().difference(_lastStatusUpdate!).inSeconds > 45) {
        setState(() => _connected = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cast sender connection lost')),
          );
          Navigator.of(context).pop();
        }
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  void _sendControl(String action, {double? seekPosition, double? volume}) {
    _discoveryService.sendCastControl(
      widget.targetDeviceIp,
      action,
      seekPosition: seekPosition,
      volume: volume,
    );
  }

  String _formatDuration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite || seconds < 0) return '0:00';
    final ms = (seconds * 1000).clamp(0.0, 3600000000.0).toInt();
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFFD600);

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 60.0, vertical: 20.0),
            child: Column(
              children: [
                // ─── Top Bar ──────────────────────────────────────────
                Row(
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
                        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.fileName,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: _connected ? const Color(0xFF4CAF50) : Colors.orangeAccent,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (_connected ? const Color(0xFF4CAF50) : Colors.orangeAccent).withValues(alpha: 0.5),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _connected
                                    ? 'Connected to ${widget.targetDeviceName}'
                                    : 'Reconnecting...',
                                style: GoogleFonts.outfit(
                                  color: _connected ? const Color(0xFF4CAF50) : Colors.orangeAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Stop Cast
                    TVFocusableButton(
                      onPressed: () {
                        _sendControl('stop');
                        _discoveryService.stopCastSession();
                        Navigator.of(context).pop();
                      },
                      backgroundColor: Colors.red.withValues(alpha: 0.15),
                      focusColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      borderRadius: BorderRadius.circular(12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.stop_rounded, color: Colors.redAccent, size: 18),
                          const SizedBox(width: 6),
                          Text('Stop Cast', style: GoogleFonts.outfit(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),

                // ─── Seek Bar ────────────────────────────────────────
                if (_duration > 0) ...[
                  Row(
                    children: [
                      Text(
                        _formatDuration(_position),
                        style: GoogleFonts.robotoMono(color: Colors.white54, fontSize: 14),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4,
                            activeTrackColor: accent,
                            inactiveTrackColor: Colors.white12,
                            thumbColor: accent,
                            overlayColor: accent.withValues(alpha: 0.2),
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                          ),
                          child: Slider(
                            value: _duration > 0 ? (_position / _duration).clamp(0.0, 1.0) : 0.0,
                            onChanged: (val) {
                              setState(() => _position = val * _duration);
                            },
                            onChangeEnd: (val) {
                              _sendControl('seek', seekPosition: val * _duration);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _formatDuration(_duration),
                        style: GoogleFonts.robotoMono(color: Colors.white54, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ] else ...[
                  if (_isBuffering)
                    const LinearProgressIndicator(
                      backgroundColor: Colors.white12,
                      color: accent,
                    ),
                  const SizedBox(height: 32),
                ],

                // ─── Main Playback Controls ───────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Rewind 10s
                    _buildControlButton(
                      icon: Icons.replay_10_rounded,
                      label: '-10s',
                      onPressed: () => _sendControl('seek', seekPosition: (_position - 10).clamp(0, _duration)),
                      size: 52,
                    ),
                    const SizedBox(width: 20),
                    // Rewind 30s
                    _buildControlButton(
                      icon: Icons.replay_30_rounded,
                      label: '-30s',
                      onPressed: () => _sendControl('seek', seekPosition: (_position - 30).clamp(0, _duration)),
                      size: 52,
                    ),
                    const SizedBox(width: 32),
                    // Play/Pause (big)
                    TVFocusableButton(
                      autofocus: true,
                      onPressed: () => _sendControl(_isPlaying ? 'pause' : 'play'),
                      backgroundColor: accent,
                      focusColor: accent,
                      borderRadius: BorderRadius.circular(40),
                      padding: const EdgeInsets.all(22),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          _isBuffering
                              ? Icons.hourglass_empty_rounded
                              : _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                          key: ValueKey(_isPlaying),
                          color: Colors.black,
                          size: 42,
                        ),
                      ),
                    ),
                    const SizedBox(width: 32),
                    // Forward 30s
                    _buildControlButton(
                      icon: Icons.forward_30_rounded,
                      label: '+30s',
                      onPressed: () => _sendControl('seek', seekPosition: (_position + 30).clamp(0, _duration)),
                      size: 52,
                    ),
                    const SizedBox(width: 20),
                    // Forward 10s
                    _buildControlButton(
                      icon: Icons.forward_10_rounded,
                      label: '+10s',
                      onPressed: () => _sendControl('seek', seekPosition: (_position + 10).clamp(0, _duration)),
                      size: 52,
                    ),
                  ],
                ),
                const SizedBox(height: 40),

                // ─── Volume Row ───────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.volume_down_rounded, color: Colors.white38, size: 20),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 300,
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 4,
                          activeTrackColor: accent.withValues(alpha: 0.8),
                          inactiveTrackColor: Colors.white12,
                          thumbColor: accent,
                          overlayColor: accent.withValues(alpha: 0.2),
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Slider(
                          value: _volume.clamp(0.0, 1.0),
                          onChanged: (val) => setState(() => _volume = val),
                          onChangeEnd: (val) => _sendControl('volume', volume: val),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.volume_up_rounded, color: Colors.white38, size: 20),
                    const SizedBox(width: 16),
                    Text(
                      '${(_volume * 100).round()}%',
                      style: GoogleFonts.robotoMono(color: Colors.white38, fontSize: 13),
                    ),
                  ],
                ),
                const Spacer(),

                // ─── Status Row ───────────────────────────────────────
                if (_isBuffering)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Buffering…',
                          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    double size = 48,
  }) {
    return TVFocusableButton(
      onPressed: onPressed,
      backgroundColor: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: size * 0.55),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.outfit(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
