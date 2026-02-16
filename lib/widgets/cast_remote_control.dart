import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zap_share/services/device_discovery_service.dart';

/// A Chromecast-style remote control widget shown on the sender device
/// after casting a video to another device. Shows playback status and
/// lets the user control play/pause/seek/volume/stop remotely.
class CastRemoteControlWidget extends StatefulWidget {
  /// IP address of the device playing the video
  final String targetDeviceIp;

  /// Name of the device playing the video
  final String targetDeviceName;

  /// File name being played
  final String fileName;

  /// Called when the user stops the cast session
  final VoidCallback? onDisconnect;

  const CastRemoteControlWidget({
    super.key,
    required this.targetDeviceIp,
    required this.targetDeviceName,
    required this.fileName,
    this.onDisconnect,
  });

  @override
  State<CastRemoteControlWidget> createState() =>
      _CastRemoteControlWidgetState();
}

class _CastRemoteControlWidgetState extends State<CastRemoteControlWidget>
    with SingleTickerProviderStateMixin {
  final _discoveryService = DeviceDiscoveryService();
  StreamSubscription<CastStatus>? _statusSub;

  // Remote playback state
  double _position = 0;
  double _duration = 0;
  double _buffered = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;
  double _volume = 1.0;
  bool _connected = false;
  bool _isSeeking = false;
  double _seekValue = 0;
  DateTime? _lastStatusTime;

  // Connection check timer
  Timer? _connectionTimer;

  static const _accentColor = Color(0xFFFFD600);

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _statusSub = _discoveryService.castStatusStream.listen((status) {
      if (!mounted) return;
      // Accept status from the target device.
      // Use flexible matching: exact IP match OR accept any status if we haven't
      // connected yet (first status establishes the connection).
      final ipMatch = status.senderIp == widget.targetDeviceIp;
      final acceptAnyWhileConnecting = !_connected && _lastStatusTime == null;
      if (ipMatch || acceptAnyWhileConnecting) {
        setState(() {
          _position = status.position;
          _duration = status.duration;
          _buffered = status.buffered;
          _isPlaying = status.isPlaying;
          _isBuffering = status.isBuffering;
          _volume = status.volume;
          _connected = true;
          _lastStatusTime = DateTime.now();
        });
      }
    });

    // Check connection every 3 seconds (reduced from 5 for faster feedback)
    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_lastStatusTime != null &&
          DateTime.now().difference(_lastStatusTime!) >
              const Duration(seconds: 6)) {
        if (mounted) setState(() => _connected = false);
      }
    });

    // Send an initial ping to the receiver to prompt status updates
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _sendControl('ping');
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _connectionTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _sendControl(String action,
      {double? seekPosition, double? volume}) {
    _discoveryService.sendCastControl(
      widget.targetDeviceIp,
      action,
      seekPosition: seekPosition,
      volume: volume,
    );
  }

  String _formatDuration(double seconds) {
    final d = Duration(milliseconds: (seconds * 1000).toInt());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _connected
              ? _accentColor.withOpacity(0.3)
              : Colors.red.withOpacity(0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: (_connected ? _accentColor : Colors.red).withOpacity(0.1),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: casting info
          _buildHeader(),
          // Seek slider
          _buildSeekSlider(),
          // Time labels
          _buildTimeLabels(),
          // Playback controls
          _buildControls(),
          // Volume slider
          _buildVolumeSlider(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
      child: Row(
        children: [
          // Casting icon with pulse
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, child) => Icon(
              Icons.cast_connected_rounded,
              color: _connected
                  ? Color.lerp(
                      _accentColor.withOpacity(0.6),
                      _accentColor,
                      _pulseController.value,
                    )
                  : Colors.red.withOpacity(0.5),
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.fileName,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _connected
                      ? 'Casting to ${widget.targetDeviceName}'
                      : 'Connecting...',
                  style: GoogleFonts.outfit(
                    color: _connected
                        ? Colors.white54
                        : Colors.red.shade300,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          // Disconnect button
          IconButton(
            onPressed: () {
              _sendControl('stop');
              widget.onDisconnect?.call();
            },
            icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
            tooltip: 'Disconnect',
          ),
        ],
      ),
    );
  }

  Widget _buildSeekSlider() {
    final maxVal = _duration > 0 ? _duration : 1.0;
    final currentVal = _isSeeking ? _seekValue : _position.clamp(0.0, maxVal);
    final bufferedVal = _buffered.clamp(0.0, maxVal);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: _accentColor,
          inactiveTrackColor: Colors.white12,
          thumbColor: _accentColor,
          overlayColor: _accentColor.withOpacity(0.15),
          secondaryActiveTrackColor: Colors.white24,
        ),
        child: Slider(
          value: currentVal,
          secondaryTrackValue: bufferedVal,
          min: 0,
          max: maxVal,
          onChangeStart: (v) {
            setState(() {
              _isSeeking = true;
              _seekValue = v;
            });
          },
          onChanged: (v) {
            setState(() => _seekValue = v);
          },
          onChangeEnd: (v) {
            _sendControl('seek', seekPosition: v);
            setState(() {
              _position = v;
              _isSeeking = false;
            });
          },
        ),
      ),
    );
  }

  Widget _buildTimeLabels() {
    final maxVal = _duration > 0 ? _duration : 0.0;
    final posVal = _isSeeking ? _seekValue : _position.clamp(0.0, maxVal);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatDuration(posVal),
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 11,
            ),
          ),
          if (_isBuffering)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: _accentColor,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'Buffering',
                  style: GoogleFonts.outfit(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          Text(
            _formatDuration(maxVal),
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Rewind 10s
          IconButton(
            onPressed: () {
              final newPos = (_position - 10).clamp(0.0, _duration);
              _sendControl('seek', seekPosition: newPos);
            },
            icon: const Icon(Icons.replay_10_rounded),
            color: Colors.white,
            iconSize: 30,
          ),
          const SizedBox(width: 12),
          // Play/Pause
          Container(
            decoration: const BoxDecoration(
              color: _accentColor,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: () {
                _sendControl(_isPlaying ? 'pause' : 'play');
              },
              icon: Icon(
                _isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.black,
              ),
              iconSize: 34,
              padding: const EdgeInsets.all(8),
            ),
          ),
          const SizedBox(width: 12),
          // Forward 10s
          IconButton(
            onPressed: () {
              final newPos = (_position + 10).clamp(0.0, _duration);
              _sendControl('seek', seekPosition: newPos);
            },
            icon: const Icon(Icons.forward_10_rounded),
            color: Colors.white,
            iconSize: 30,
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeSlider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            _volume == 0
                ? Icons.volume_off_rounded
                : _volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
            color: Colors.white54,
            size: 18,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
                overlayColor: Colors.white10,
              ),
              child: Slider(
                value: _volume.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: (v) {
                  setState(() => _volume = v);
                  _sendControl('volume', volume: v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
