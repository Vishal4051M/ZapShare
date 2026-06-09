import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zap_share/services/device_discovery_service.dart';

class CastRemoteControlScreen extends StatefulWidget {
  final String targetDeviceIp;
  final String targetDeviceName;
  final String fileName;
  final String? videoUrl;
  final String? localFileUri;

  const CastRemoteControlScreen({
    super.key,
    required this.targetDeviceIp,
    required this.targetDeviceName,
    required this.fileName,
    this.videoUrl,
    this.localFileUri,
  });

  @override
  State<CastRemoteControlScreen> createState() =>
      _CastRemoteControlScreenState();
}

class _CastRemoteControlScreenState extends State<CastRemoteControlScreen> {
  final _discoveryService = DeviceDiscoveryService();
  StreamSubscription<CastStatus>? _statusSub;

  // Remote playback state
  double _position = 0;
  double _duration = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;
  double _volume = 1.0;
  List<String> _audioTracks = [];
  List<String> _subtitleTracks = [];
  int? _activeAudioTrack;
  int? _activeSubtitleTrack;
  bool _connected = false;

  // Phone UI state
  double _subSize = 1.0;
  double _subPos = 100;
  String _subColor = '#FFFFFF';
  String _aspect = 'no';
  String _audioDevice = 'auto';

  // Local audio playback for "This Phone" mode
  Player? _localAudioPlayer;
  bool _isLocalAudioActive = false;
  bool _localAudioReady = false;
  Timer? _syncTimer;
  DateTime? _lastStatusUpdate;

  String _cleanTrackLabel(String label) {
    if (label.length > 12) return '${label.substring(0, 10)}...';
    return label;
  }

  @override
  void initState() {
    super.initState();
    _initStatusStream();
    _startCastNotification();
  }

  /// Start the foreground service with media controls in the notification
  Future<void> _startCastNotification() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('zapshare.saf').invokeMethod('startForegroundService', {
        'title': 'Casting: ${widget.fileName}',
        'content': 'Playing on ${widget.targetDeviceName}',
      });
    } catch (e) {
      debugPrint('⚠️ Foreground service start warning: $e');
    }
  }

  void _initStatusStream() {
    _statusSub = _discoveryService.castStatusStream.listen((status) {
      if (!mounted) return;
      if (status.senderIp == widget.targetDeviceIp) {
        setState(() {
          // Latency Compensation: account for time taken by packet to travel over network
          final now = DateTime.now().millisecondsSinceEpoch;
          final sentAt = status.timestamp ?? now; // Fallback to now if missing
          final latency = (now - sentAt) / 1000.0;
          
          // Apply latency-adjusted position
          _position = status.position + (status.isPlaying ? latency : 0.0);
          
          _duration = status.duration;
          _isPlaying = status.isPlaying;
          _isBuffering = status.isBuffering;
          _volume = status.volume;
          _audioTracks = status.audioTracks ?? [];
          _subtitleTracks = status.subtitleTracks ?? [];
          _activeAudioTrack = status.activeAudioTrack;
          _activeSubtitleTrack = status.activeSubtitleTrack;
          _connected = true;
          _lastStatusUpdate = DateTime.now();
        });

        // Handle Audio Routing (Local Phone Sync)
        if (status.audioOutput == 'remote') {
          if (!_isLocalAudioActive) _startLocalAudio(status.position);
        } else if (_isLocalAudioActive) {
          _stopLocalAudio();
        }
      }
    });

    // Periodic ping and connection watchdog
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _sendControl('ping');

      // Watchdog: If no status for 45s, mark as disconnected (Increased from 15s for 18GB+ robustness)
      if (_connected &&
          _lastStatusUpdate != null &&
          DateTime.now().difference(_lastStatusUpdate!).inSeconds > 45) {
        setState(() => _connected = false);
      }

      // Ping: If no status for 12s, send a ping to TV to wake up the network link
      if (_connected &&
          _lastStatusUpdate != null &&
          DateTime.now().difference(_lastStatusUpdate!).inSeconds > 12) {
        _sendControl('ping');
      }
    });

    // Handle Remote Commands from Notification
    MethodChannel('zapshare.saf').setMethodCallHandler((call) async {
      if (call.method == 'remoteCommand') {
        final action = call.arguments['action'];
        _handleRemoteAction(action);
      }
      return null;
    });
  }

  void _handleRemoteAction(String? action) {
    if (action == null) return;
    switch (action) {
      case 'zapshare.ACTION_PLAY':
        _sendControl('play');
        break;
      case 'zapshare.ACTION_PAUSE':
        _sendControl('pause');
        break;
      case 'zapshare.ACTION_FORWARD':
        _sendControl('seek', seekPosition: _position + 30);
        break;
      case 'zapshare.ACTION_REWIND':
        _sendControl('seek', seekPosition: _position - 30);
        break;
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _syncTimer?.cancel();
    _stopLocalAudio();
    // Clear the MethodChannel handler to prevent stale callbacks
    MethodChannel('zapshare.saf').setMethodCallHandler(null);
    super.dispose();
  }

  // ─── Local Audio Playback (Same Link Sync) ─────────────────

  Future<void> _startLocalAudio(double position) async {
    if (_isLocalAudioActive ||
        widget.videoUrl == null && widget.localFileUri == null)
      return;

    _isLocalAudioActive = true;
    _localAudioPlayer = Player();
    final player = _localAudioPlayer!;

    // Configure for audio-only
    if (player.platform is NativePlayer) {
      final np = player.platform as NativePlayer;
      await np.setProperty('vid', 'no');
      await np.setProperty('ao', Platform.isAndroid ? 'audiotrack' : 'auto');
      await np.setProperty(
        'audio-delay',
        '-0.350',
      ); // Compensation for network/BT lag
    }

    try {
      final source = widget.videoUrl ?? 'file://${widget.localFileUri}';
      await player.open(Media(source), play: false);

      // Handle player errors (reconnect if link fails during 20GB streaming)
      player.stream.error.listen((e) {
        debugPrint('🎧 [LocalAudio] error: $e. Reconnecting...');
        _localAudioReady = false;
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _isLocalAudioActive) _startLocalAudio(_position);
        });
      });

      await player.seek(Duration(milliseconds: (position * 1000).toInt()));

      if (_isPlaying) await player.play();
      _localAudioReady = true;

      // Local audio specific sync loop (independent of connection watchdog)
      Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (!mounted || !_isLocalAudioActive) {
          t.cancel();
          return;
        }
        _syncLocalPlayback();
      });
    } catch (e) {
      debugPrint('Failed to start local audio: $e');
      _stopLocalAudio();
    }
  }

  void _syncLocalPlayback() {
    final player = _localAudioPlayer;
    if (player == null || !_localAudioReady) return;

    // Extrapolate TV position
    final drift =
        _lastStatusUpdate != null
            ? DateTime.now().difference(_lastStatusUpdate!).inMilliseconds /
                1000.0
            : 0.0;
    final expectedPos = _isPlaying ? (_position + drift) : _position;
    final currentPos = player.state.position.inMilliseconds / 1000.0;

    final diff = currentPos - expectedPos; // local - remote
    final absDiff = diff.abs();

    // Play/Pause sync (with sanity check)
    if (_isPlaying && !player.state.playing && !player.state.buffering) {
      player.play();
    } else if (!_isPlaying && player.state.playing) {
      player.pause();
    }

    // Robust Jitter-free Drift correction
    if (absDiff > 3.0) {
      // Large gap (>3s): Immediate hard seek to recover
      player.seek(Duration(milliseconds: (expectedPos * 1000).toInt()));
      player.setRate(1.0);
    } else if (absDiff > 0.8) {
      // Progressive catch-up (>800ms): 10% rate adjustment
      player.setRate(diff > 0 ? 0.90 : 1.10);
    } else if (absDiff > 0.2) {
      // Standard drift correction (>200ms): 3% rate adjustment
      player.setRate(diff > 0 ? 0.97 : 1.03);
    } else if (absDiff > 0.05) {
      // Subtle drift correction (>50ms): 0.5% rate adjustment
      player.setRate(diff > 0 ? 0.995 : 1.005);
    } else {
      // In-Sync (<50ms): Reset to normal speed
      if (player.state.rate != 1.0) player.setRate(1.0);
    }
  }

  void _stopLocalAudio() {
    _syncTimer?.cancel();
    _localAudioPlayer?.dispose();
    _localAudioPlayer = null;
    _isLocalAudioActive = false;
    _localAudioReady = false;
  }

  void _sendControl(
    String action, {
    double? seekPosition,
    double? volume,
    int? trackIndex,
    String? propertyKey,
    dynamic propertyValue,
  }) {
    // Immediate local feedback for better UX
    if (_isLocalAudioActive && _localAudioPlayer != null) {
      if (action == 'seek' && seekPosition != null) {
        _localAudioPlayer?.seek(
          Duration(milliseconds: (seekPosition * 1000).toInt()),
        );
        // Suppress drift correction for 1.5s to avoid "tug-of-war" while seeking
        _lastStatusUpdate = DateTime.now().add(
          const Duration(milliseconds: 500),
        );
      } else if (action == 'play') {
        _localAudioPlayer?.play();
      } else if (action == 'pause') {
        _localAudioPlayer?.pause();
      }
    }

    _discoveryService.sendCastControl(
      widget.targetDeviceIp,
      action,
      seekPosition: seekPosition,
      volume: volume,
      trackIndex: trackIndex,
      propertyKey: propertyKey,
      propertyValue: propertyValue,
    );
  }

  void _updateSubtitleStyle() {
    _sendControl(
      'setProperty',
      propertyKey: 'sub-scale',
      propertyValue: _subSize,
    );
    _sendControl('setProperty', propertyKey: 'sub-pos', propertyValue: _subPos);
    _sendControl(
      'setProperty',
      propertyKey: 'sub-color',
      propertyValue: _subColor,
    );
    _sendControl(
      'setProperty',
      propertyKey: 'sub-ass-override',
      propertyValue: 'force',
    );
  }

  String _formatDuration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite || seconds < 0) return '0:00';
    final ms = (seconds * 1000).clamp(0.0, 3600000000.0).toInt();
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0)
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Color(0xFFFFD600);
    const primaryBg = Color(0xFF0D0F1A);
    const secondaryColor = Color(0xFF1F2232);

    return Scaffold(
      backgroundColor: primaryBg,
      body: Stack(
        children: [
          // Subtle background glow
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accentColor.withValues(alpha: 0.05),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildModernAppBar(accentColor),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 12),
                        _buildMediaCard(accentColor, secondaryColor),
                        const SizedBox(height: 32),
                        _buildSeekSection(accentColor),
                        const SizedBox(height: 48),
                        _buildMainControls(accentColor),
                        const SizedBox(height: 48),
                        _buildVolumeSection(accentColor),
                        const SizedBox(height: 32),
                        _buildTrackSelection(accentColor),
                        const SizedBox(height: 32),
                        _buildBottomActions(secondaryColor),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernAppBar(Color accentColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 24, 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white70,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Media Remote',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                Row(
                  children: [
                    _buildStatusIndicator(),
                    const SizedBox(width: 6),
                    Text(
                      _connected ? 'TV CONNECTED' : 'RECONNECTING...',
                      style: GoogleFonts.outfit(
                        fontSize: 10,
                        color:
                            _connected
                                ? const Color(0xFF4CAF50)
                                : Colors.orangeAccent,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _buildPowerButton(),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator() {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: _connected ? const Color(0xFF4CAF50) : Colors.orangeAccent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (_connected ? const Color(0xFF4CAF50) : Colors.orangeAccent)
                .withValues(alpha: 0.4),
            blurRadius: 4,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildPowerButton() {
    return GestureDetector(
      onTap: () {
        _sendControl('stop');
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.power_settings_new_rounded,
          color: Colors.redAccent,
          size: 20,
        ),
      ),
    );
  }

  Widget _buildMediaCard(Color accentColor, Color secondaryColor) {
    return Container(
      width: double.infinity,
      height: 180,
      decoration: BoxDecoration(
        color: secondaryColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.4,
                child: Image.network(
                  'https://images.unsplash.com/photo-1478720568477-152d9b164e26?q=80&w=600&auto=format&fit=crop',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.8),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'CASTING',
                      style: GoogleFonts.outfit(
                        color: accentColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.fileName,
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeekSection(Color accentColor) {
    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 2,
            activeTrackColor: accentColor,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: _position.clamp(0.0, _duration > 0 ? _duration : 1.0),
            max: _duration > 0 ? _duration : 1.0,
            onChanged: (v) {
              setState(() => _position = v);
              _sendControl('seek', seekPosition: v);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: GoogleFonts.outfit(color: Colors.white54, fontSize: 11),
              ),
              Text(
                _formatDuration(_duration),
                style: GoogleFonts.outfit(color: Colors.white24, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMainControls(Color accentColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildSeekBtn(
          Icons.replay_10_rounded,
          () => _sendControl(
            'seek',
            seekPosition: (_position - 10).clamp(0.0, _duration),
          ),
        ),
        const SizedBox(width: 48),
        _buildPlayPauseBtn(accentColor),
        const SizedBox(width: 48),
        _buildSeekBtn(
          Icons.forward_10_rounded,
          () => _sendControl(
            'seek',
            seekPosition: (_position + 10).clamp(0.0, _duration),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayPauseBtn(Color accentColor) {
    return GestureDetector(
      onTap: () => _sendControl(_isPlaying ? 'pause' : 'play'),
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: accentColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: accentColor.withValues(alpha: 0.4),
              blurRadius: 32,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(
          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 40,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _buildSeekBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Icon(icon, color: Colors.white70, size: 24),
      ),
    );
  }

  Widget _buildVolumeSection(Color accentColor) {
    return Row(
      children: [
        Icon(Icons.volume_down_rounded, color: Colors.white30, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: Colors.white70,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.05),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: _volume,
              onChanged: (v) {
                setState(() => _volume = v);
                _sendControl('volume', volume: v);
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${(_volume * 100).toInt()}%',
          style: GoogleFonts.outfit(color: Colors.white24, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildTrackSelection(Color accentColor) {
    return Row(
      children: [
        Expanded(
          child: _buildTrackTile(
            Icons.audiotrack_rounded,
            'Audio',
            (_activeAudioTrack != null &&
                    _activeAudioTrack! < _audioTracks.length)
                ? _audioTracks[_activeAudioTrack!]
                : 'Default',
            accentColor,
            () => _showTrackPicker(
              'Audio',
              _audioTracks,
              _activeAudioTrack,
              (i) => _sendControl('setAudioTrack', trackIndex: i),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildTrackTile(
            Icons.subtitles_rounded,
            'Subtitles',
            (_activeSubtitleTrack != null &&
                    _activeSubtitleTrack! < _subtitleTracks.length)
                ? _subtitleTracks[_activeSubtitleTrack!]
                : 'Off',
            accentColor,
            () => _showTrackPicker(
              'Subtitles',
              ['Off', ..._subtitleTracks],
              (_activeSubtitleTrack ?? -1) + 1,
              (i) => _sendControl('setSubtitleTrack', trackIndex: i - 1),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrackTile(
    IconData icon,
    String label,
    String value,
    Color accentColor,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white30, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.outfit(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    value,
                    style: GoogleFonts.outfit(
                      color: accentColor,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white12,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActions(Color secondaryColor) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 2.5,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        _buildActionBtn(
          Icons.aspect_ratio_rounded,
          'Aspect',
          () => _showAspectPicker(context),
        ),
        _buildActionBtn(
          Icons.speaker_phone_rounded,
          'Output',
          () => _showAudioOutputPicker(context),
        ),
        _buildActionBtn(
          Icons.fullscreen_rounded,
          'Window',
          () => _sendControl(
            'setProperty',
            propertyKey: 'fullscreen',
            propertyValue: 'toggle',
          ),
        ),
        _buildActionBtn(
          Icons.style_rounded,
          'Style',
          () => _showSubtitleStyler(context),
        ),
      ],
    );
  }

  Widget _buildActionBtn(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white54, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: GoogleFonts.outfit(
                color: Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTrackPicker(
    String title,
    List<String> options,
    int? active,
    Function(int) onSelect,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0F1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder:
          (context) => SafeArea(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              itemCount: options.length,
              itemBuilder: (context, i) {
                final isSelected = i == active;
                return ListTile(
                  onTap: () {
                    onSelect(i);
                    Navigator.pop(context);
                  },
                  leading: Icon(
                    isSelected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_off_rounded,
                    color:
                        isSelected ? const Color(0xFFFFD600) : Colors.white10,
                    size: 20,
                  ),
                  title: Text(
                    _cleanTrackLabel(options[i]),
                    style: GoogleFonts.outfit(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
    );
  }

  void _showAspectPicker(BuildContext context) {
    final ratios = {
      'Auto': 'no',
      '16:9': '16/9',
      '4:3': '4/3',
      '2.35:1': '2.35',
      'Full': '16/10',
    };
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0F1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder:
          (context) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 20),
            children:
                ratios.entries
                    .map(
                      (e) => ListTile(
                        title: Text(
                          e.key,
                          style: GoogleFonts.outfit(
                            color:
                                _aspect == e.value
                                    ? const Color(0xFFFFD600)
                                    : Colors.white70,
                          ),
                        ),
                        onTap: () {
                          setState(() => _aspect = e.value);
                          _sendControl(
                            'setProperty',
                            propertyKey: 'video-aspect-override',
                            propertyValue: e.value,
                          );
                          Navigator.pop(context);
                        },
                      ),
                    )
                    .toList(),
          ),
    );
  }

  void _showAudioOutputPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0F1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder:
          (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 20),
              Text(
                'Audio Output',
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Icon(
                  Icons.tv_rounded,
                  color:
                      _audioDevice == 'auto'
                          ? const Color(0xFFFFD600)
                          : Colors.white30,
                ),
                title: Text(
                  'TV Speakers',
                  style: GoogleFonts.outfit(color: Colors.white70),
                ),
                onTap: () {
                  setState(() => _audioDevice = 'auto');
                  _sendControl('setAudioOutput', propertyValue: 'local');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.phone_android_rounded,
                  color:
                      _audioDevice == 'phone'
                          ? const Color(0xFFFFD600)
                          : Colors.white30,
                ),
                title: Text(
                  'This Phone',
                  style: GoogleFonts.outfit(color: Colors.white70),
                ),
                onTap: () {
                  setState(() => _audioDevice = 'phone');
                  _sendControl('setAudioOutput', propertyValue: 'remote');
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
    );
  }

  void _showSubtitleStyler(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0F1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder:
          (context) => SafeArea(
            child: StatefulBuilder(
              builder:
                  (context, setModalState) => Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Subtitle Style',
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 32),
                        _styleRow('Size', _subSize, 0.5, 2.5, (v) {
                          setModalState(() => _subSize = v);
                          setState(() => _subSize = v);
                          _updateSubtitleStyle();
                        }),
                        _styleRow('Position', _subPos, 0, 100, (v) {
                          setModalState(() => _subPos = v);
                          setState(() => _subPos = v);
                          _updateSubtitleStyle();
                        }),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children:
                              ['#FFFFFF', '#FFFF00', '#00FF00', '#FF0000'].map((
                                c,
                              ) {
                                return GestureDetector(
                                  onTap: () {
                                    setModalState(() => _subColor = c);
                                    setState(() => _subColor = c);
                                    _updateSubtitleStyle();
                                  },
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Color(
                                        int.parse(c.replaceFirst('#', '0xFF')),
                                      ),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color:
                                            _subColor == c
                                                ? Colors.white
                                                : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                        ),
                      ],
                    ),
                  ),
            ),
          ),
    );
  }

  Widget _styleRow(
    String label,
    double value,
    double min,
    double max,
    Function(double) onChange,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChange),
        ),
      ],
    );
  }
}
