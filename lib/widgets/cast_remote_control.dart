import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'package:zap_share/Screens/shared/CastRemoteControlScreen.dart';

/// A professional floating remote control overlay shown on the sender device
/// after casting a video to another device. Draggable, with full playback controls,
/// audio track switching, subtitle switching, volume, and seek.
class CastRemoteControlWidget extends StatefulWidget {
  /// IP address of the device playing the video
  final String targetDeviceIp;

  /// Name of the device playing the video
  final String targetDeviceName;

  /// File name being played
  final String fileName;

  /// HTTP URL of the video being cast (for local audio playback)
  final String? videoUrl;

  /// Local file URI or path (if available on this device)
  final String? localFileUri;

  /// Called when the user stops the cast session
  final VoidCallback? onDisconnect;

  const CastRemoteControlWidget({
    super.key,
    required this.targetDeviceIp,
    required this.targetDeviceName,
    required this.fileName,
    this.videoUrl,
    this.localFileUri,
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
  bool _hasStartedPlaying = false;
  bool _isSeeking = false;
  double _seekValue = 0;
  DateTime? _lastStatusTime;

  // Track state
  List<String> _audioTracks = [];
  List<String> _subtitleTracks = [];
  int? _activeAudioTrack;
  String?
  _activeAudioTrackLabel; // track by name (e.g. 'English') for better matching
  int? _activeSubtitleTrack;

  // UI state
  bool _expanded = true;
  bool _showAudioMenu = false;
  bool _showSubtitleMenu = false;

  // Smooth position interpolation
  double _animatedPosition = 0;
  Timer? _positionAnimTimer;

  // Connection check timer
  Timer? _connectionTimer;

  // Local audio playback for Cast Source mode
  Player? _localAudioPlayer;
  bool _isCastSourceAudio = false;
  bool _localAudioReady = false;
  Timer? _castSyncTimer; // tight 200ms sync loop while in castSource mode
  DateTime? _localAudioStartedAt; // when _startLocalAudio was called
  DateTime?
  _lastManualActionTime; // debounce: skip auto-correction shortly after user seeks
  int?
  _pendingLocalAudioTrack; // remember requested track before local audio player is ready
  String? _pendingLocalAudioLabel; // remember requested track label
  int _castSourceStartAttempts = 0; // retry limiter for cast source audio start
  StreamSubscription<String>? _playerErrorSub; // listen for mpv errors
  String? _castSourceError; // last error message shown in UI
  String? _castSourceLog; // diagnostic step log for UI display
  bool _isSwitchingTrack = false; // concurrency guard for rapid track changes
  bool _isStartingLocalAudio = false; // guard for full engine re-init

  static const _accentColor = Color(0xFFFFD600);
  static const _bgColor = Color(0xFF0E0E12);
  static const _cardColor = Color(0xFF1A1A22);
  static const _surfaceColor = Color(0xFF252530);

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
      final ipMatch = status.senderIp == widget.targetDeviceIp;
      final acceptAnyWhileConnecting = !_connected && _lastStatusTime == null;
      if (ipMatch || acceptAnyWhileConnecting) {
        if (!status.active) {
          if (_connected) {
            setState(() {
              _connected = false;
              _hasStartedPlaying = false;
            });
            _stopLocalAudio();
            debugPrint(
              '[CastRemote] TV signaled cast end, stopping local audio',
            );
          }
          return;
        }

        // Capture before setState so we can detect changes
        final prevAudioTrack = _activeAudioTrack;
        final prevAudioLabel = _activeAudioTrackLabel;

        setState(() {
          if (!_isSeeking) {
            _position = status.position;
            _animatedPosition = status.position;
          }
          _duration = status.duration;
          _buffered = status.buffered;
          _isPlaying = status.isPlaying;
          _isBuffering = status.isBuffering;
          _volume = status.volume;
          _connected = true;
          _lastStatusTime = DateTime.now();
          if (status.audioTracks != null) _audioTracks = status.audioTracks!;
          if (status.subtitleTracks != null) {
            _subtitleTracks = status.subtitleTracks!;
          }
          _activeAudioTrack = status.activeAudioTrack;
          _activeAudioTrackLabel = status.activeAudioTrackLabel;
          _activeSubtitleTrack = status.activeSubtitleTrack;

          // Foreground notification is handled persistently by DeviceDiscoveryService
          if (!_hasStartedPlaying && _connected && status.duration > 0) {
            _hasStartedPlaying = true;
          }
        });

        // Handle Cast Source audio routing FIRST
        _handleAudioOutputChange(
          status.audioOutput,
          status.position,
          status.isPlaying,
        );

        // If TV changed its active audio track while we are in castSource mode, mirror it
        if (_isCastSourceAudio &&
            (status.activeAudioTrack != prevAudioTrack ||
                status.activeAudioTrackLabel != prevAudioLabel)) {
          debugPrint(
            '[Cast] TV track changed: index=$prevAudioTrack->$status.activeAudioTrack label=$prevAudioLabel->$status.activeAudioTrackLabel',
          );

          if (_localAudioReady) {
            _switchLocalAudioTrack(
              status.activeAudioTrack ?? 0,
              label: status.activeAudioTrackLabel,
            );
          } else {
            _pendingLocalAudioTrack = status.activeAudioTrack;
            _pendingLocalAudioLabel = status.activeAudioTrackLabel;
          }
        }
      }
    });

    // Smooth position interpolation (update 10x/sec for smooth seek bar)
    _positionAnimTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || _isSeeking || !_isPlaying) return;
      setState(() {
        final safeDuration = _duration > 0 ? _duration : 0.0;
        _animatedPosition = (_animatedPosition + 0.1).clamp(
          0.0,
          safeDuration > 0 ? safeDuration : 1.0,
        );
      });
    });

    // Connection watchdog and periodic ping
    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();

      // If not connected, or if we haven't received status for a while, send a ping
      if (!_connected ||
          (_lastStatusTime != null &&
              now.difference(_lastStatusTime!) > const Duration(seconds: 10))) {
        _sendControl('ping');
      }

      // If we were connected but haven't heard back for 30 seconds, mark as disconnected
      // (Increased from 8s for robustness during 18GB+ file streaming with network congestion)
      if (_connected &&
          _lastStatusTime != null &&
          now.difference(_lastStatusTime!) > const Duration(seconds: 30)) {
        if (mounted) {
          setState(() {
            _connected = false;
            _hasStartedPlaying = false;
          });
          _stopLocalAudio();
          debugPrint(
            '[CastRemote] Lost connection to TV (30s timeout), stopping local audio',
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _connectionTimer?.cancel();
    _positionAnimTimer?.cancel();
    _castSyncTimer?.cancel();
    _playerErrorSub?.cancel();
    _pulseController.dispose();
    _stopLocalAudio();
    super.dispose();
  }

  void _sendControl(
    String action, {
    double? seekPosition,
    double? volume,
    int? trackIndex,
  }) {
    _discoveryService.sendCastControl(
      widget.targetDeviceIp,
      action,
      seekPosition: seekPosition,
      volume: volume,
      trackIndex: trackIndex,
    );
  }

  // ── Cast Source local audio playback ──

  void _showCastError(String msg) {
    debugPrint('[CastSource] ERROR: $msg');
    if (!mounted) return;
    setState(() => _castSourceError = msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(msg, style: const TextStyle(fontSize: 12))),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showCastInfo(String msg) {
    debugPrint('[CastSource] INFO: $msg');
    if (!mounted) return;
    setState(() {
      _castSourceError = null;
      _castSourceLog = msg;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.speaker_phone_rounded,
              color: Colors.black,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg,
                style: const TextStyle(color: Colors.black, fontSize: 12),
              ),
            ),
          ],
        ),
        backgroundColor: _accentColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _logCastStep(String step) {
    debugPrint('[CastSource] STEP: $step');
    if (mounted) setState(() => _castSourceLog = step);
  }

  void _handleAudioOutputChange(
    String? audioOutput,
    double position,
    bool isPlaying,
  ) {
    final wantCastSource = audioOutput == 'castSource';

    if (wantCastSource && !_isCastSourceAudio) {
      // Switching TO Cast Source — start local audio and tight sync loop.
      // Set the flag synchronously so repeat status updates don't re-enter this branch.
      _isCastSourceAudio = true;
      _castSourceStartAttempts = 0;
      setState(() => _castSourceError = null);
      // Use the track index the TV is already playing (from activeAudioTrack).
      // If it's null, keep whatever we had from prevAudioTrack / default 0.
      if (_activeAudioTrack != null) {
        _pendingLocalAudioTrack = _activeAudioTrack;
      }

      if (_isStartingLocalAudio) return; // Already initializing

      _lastManualActionTime =
          DateTime.now(); // suppress sync interference during startup

      // PAUSE TV initially so we can sync up
      if (isPlaying) _sendControl('pause');

      _startLocalAudio(position, isPlaying).catchError((e) {
        _showCastError('Audio start failed: $e');
        if (mounted && _castSourceStartAttempts < 5) {
          // Reset flag so the next periodic status update retries automatically
          _isCastSourceAudio = false;
          _localAudioReady = false;
        }
      });
      _startCastSyncTimer();
    } else if (!wantCastSource && _isCastSourceAudio) {
      // Switching BACK to default — stop local audio completely.
      _stopLocalAudio();
      if (mounted) {
        setState(() {
          _castSourceError = null;
          _castSourceLog = null;
        });
      }
    }
    // When already in the correct state (both sides agree), do nothing.
    // The tight sync timer handles drift correction.
  }

  void _startCastSyncTimer() {
    _castSyncTimer?.cancel();
    // Run every 500ms (not 200ms) to reduce seek-spam on slower devices.
    // Drift correction is only triggered if >1.5s off, so less-frequent
    // polling is perfectly fine.
    _castSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_isCastSourceAudio || !_localAudioReady) return;
      _syncLocalAudio();
    });
  }

  /// Returns the most reliable source for media_kit.
  /// If `videoUrl` (HTTP) is available, we rewrite the host to `127.0.0.1` to bypass
  /// any local network/NAT-loopback restrictions. This allows media_kit to use standard HTTP
  /// (which supports range-requests perfectly and always enumerates tracks correctly).
  /// If not, we fall back to the `content://` or file path.
  String? get _effectiveAudioSource {
    final httpUrl = widget.videoUrl;
    if (httpUrl != null && httpUrl.startsWith('http')) {
      try {
        final uri = Uri.parse(httpUrl);
        return uri.replace(host: '127.0.0.1').toString();
      } catch (_) {
        return httpUrl; // fallback if parse fails
      }
    }
    String? source = widget.localFileUri;
    if (source != null &&
        !source.startsWith('http') &&
        !source.startsWith('content://') &&
        !source.startsWith('file://')) {
      return 'file://$source';
    }
    return source;
  }

  Future<void> _startLocalAudio(double position, bool isPlaying) async {
    if (_isStartingLocalAudio) return;
    _isStartingLocalAudio = true;

    try {
      String? audioSource = _effectiveAudioSource;

      if (audioSource == null || audioSource.isEmpty) {
        _showCastError('No audio source');
        _isCastSourceAudio = false;
        return;
      }

      _castSourceStartAttempts++;
      _logCastStep('Connecting to server...');

      _playerErrorSub?.cancel();
      _localAudioPlayer?.dispose();
      _localAudioPlayer = Player();
      _localAudioReady = false;
      _localAudioStartedAt = DateTime.now();
      final player = _localAudioPlayer!;
      final playing = _isPlaying;

      // Capture the target track index and label now.
      final targetTrackIdx = _pendingLocalAudioTrack ?? _activeAudioTrack ?? 0;
      final targetLabel = _pendingLocalAudioLabel ?? _activeAudioTrackLabel;
      _pendingLocalAudioTrack = null;
      _pendingLocalAudioLabel = null;

      // ── Step 1: Configure MPV properties BEFORE opening media ─────────────────
      if (player.platform is NativePlayer) {
        final np = player.platform as NativePlayer;
        try {
          await np.setProperty('vid', 'no');
          await np.setProperty('vo', 'null');

          // Software-only decoding is CRITICAL for cross-codec switching (DDP <-> AAC)
          await np.setProperty('hwdec', 'no');

          // FORCE UNIFIED OUTPUT (Audio Fingerprint Fix)
          await np.setProperty('audio-channels', 'stereo');
          await np.setProperty('audio-samplerate', '48000');
          await np.setProperty('audio-format', 's16');
          await np.setProperty('audio-pitch-correction', 'yes');

          if (targetTrackIdx > 0) {
            await np.setProperty('aid', (targetTrackIdx + 1).toString());
          }

          await np.setProperty(
            'ao',
            Platform.isAndroid ? 'audiotrack' : 'auto',
          );
          await np.setProperty('volume', '100');
          await np.setProperty('force-seekable', 'yes');
          await np.setProperty('cache', 'yes');

          // REAL-TIME LIP-SYNC & BUFFERING FOR LARGE FILES (20GB+)
          // -0.350s (350ms) to offset player and network pipeline lag.
          await np.setProperty('audio-delay', '-0.35');

          // Aggressive buffering for massive files (stutter prevention)
          await np.setProperty(
            'demuxer-max-bytes',
            '256MiB',
          ); // 256MB demuxer buffer
          await np.setProperty('demuxer-max-back-bytes', '64MiB');
          await np.setProperty(
            'demuxer-readahead-secs',
            '300.0',
          ); // 5 minutes readahead
          await np.setProperty(
            'audio-buffer',
            '3.0',
          ); // 3 second audio-specific buffer
          await np.setProperty('cache-secs', '60.0'); // 1 minute general cache

          // Speed up probing for large files with many tracks
          await np.setProperty('probe-size', '5000000'); // 5MB probe

          await np.setProperty('hr-seek', 'yes');
          await np.setProperty('hr-seek-framedrop', 'yes');
        } catch (e) {
          debugPrint('[CastSource] Config error: $e');
        }
      }

      _playerErrorSub = player.stream.error.listen((error) {
        debugPrint('[CastSource] Player error: $error');
        if (mounted && _isCastSourceAudio) {
          _showCastError('Audio Error: $error');
        }
      });

      // ── Step 2: Open media ────────────────────────────────────────────────────
      try {
        _logCastStep('Opening stream...');
        // We open with play:false to allow precise seeking before start.
        await player.open(Media(audioSource), play: false);
      } catch (e) {
        _showCastError('Failed to open: $e');
        _stopLocalAudio();
        return;
      }

      // ── Step 3: Wait for track probe & stabilization ──────────────────────────
      _logCastStep('Probing tracks...');
      final tracksCompleter = Completer<void>();
      StreamSubscription<Tracks>? tracksSub;

      tracksSub = player.stream.tracks.listen((tracks) {
        if (tracksCompleter.isCompleted) return;
        final realAudio =
            tracks.audio
                .where(
                  (t) =>
                      t.id.isNotEmpty &&
                      t.id.toLowerCase() != 'auto' &&
                      t.id != 'no',
                )
                .toList();
        if (realAudio.isNotEmpty) {
          tracksCompleter.complete();
        }
      });

      try {
        await tracksCompleter.future.timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('[CastSource] Track probe timeout (continuing anyway)');
      } finally {
        tracksSub.cancel();
      }

      if (!_isCastSourceAudio || !identical(player, _localAudioPlayer)) return;

      // ── Step 4: Seek to TV position ───────────────────────────────────────────
      _logCastStep('Syncing position...');
      final elapsedSecs =
          DateTime.now().difference(_localAudioStartedAt!).inMilliseconds /
          1000.0;
      final targetPos = (_position + (_isPlaying ? elapsedSecs : 0)).clamp(
        0.0,
        _duration > 0 ? _duration : double.infinity,
      );

      try {
        // LIP-SYNC OFFSET in seek: We target slightly ahead so NP is ready
        final seekTarget = (targetPos * 1000).toInt();
        await player.seek(Duration(milliseconds: seekTarget));
        // Small pause to let the demuxer seek settle on the network stream
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        debugPrint('[CastSource] Seek failed: $e');
      }

      // ── Step 5: Select Track (Label Matching) ────────────────────────────────
      _logCastStep('Selecting track...');

      // Give the state a moment to synchronize with the stream results
      var tracks =
          player.state.tracks.audio
              .where(
                (t) =>
                    t.id.isNotEmpty &&
                    t.id.toLowerCase() != 'auto' &&
                    t.id != 'no',
              )
              .toList();
      if (tracks.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 400));
        tracks =
            player.state.tracks.audio
                .where(
                  (t) =>
                      t.id.isNotEmpty &&
                      t.id.toLowerCase() != 'auto' &&
                      t.id != 'no',
                )
                .toList();
      }

      if (tracks.isNotEmpty) {
        AudioTrack? selectedTrack;

        // Try mapping by label first (best accuracy)
        if (targetLabel != null) {
          selectedTrack = tracks.firstWhere(
            (t) =>
                (t.title?.toLowerCase() == targetLabel.toLowerCase()) ||
                (t.language?.toLowerCase() == targetLabel.toLowerCase()),
            orElse: () => tracks[targetTrackIdx.clamp(0, tracks.length - 1)],
          );
        } else {
          selectedTrack = tracks[targetTrackIdx.clamp(0, tracks.length - 1)];
        }

        final actualIdx = tracks.indexOf(selectedTrack);
        final trackDesc =
            selectedTrack.title ??
            selectedTrack.language ??
            'Track ${actualIdx + 1}';
        debugPrint(
          '[CastSource] Selected: $trackDesc (ID: ${selectedTrack.id}, idx: $actualIdx)',
        );

        if (player.platform is NativePlayer) {
          final np = player.platform as NativePlayer;
          // Setting 'aid' is the most reliable way for native MPV tracking
          await np.setProperty('aid', selectedTrack.id);
        }
        // setAudioTrack handles the high-level media_kit state
        await player.setAudioTrack(selectedTrack);
      }

      // ── Step 6: Final Stabilization & Play ────────────────────────────────────
      _localAudioReady = true;
      _logCastStep('Ready');
      if (playing) {
        await player.play();
        // RESUME TV now that phone is ready
        _sendControl('play');
      }

      if (mounted) {
        setState(() {
          _castSourceError = null;
          _castSourceLog = 'Playing Track ${targetTrackIdx + 1}';
        });
        _showCastInfo('Phone audio active (Track ${targetTrackIdx + 1})');
      }

      debugPrint(
        '[CastSource] playback started at ${targetPos.toStringAsFixed(1)}s',
      );
    } finally {
      _isStartingLocalAudio = false;
    }
  }

  /// Sync local audio against the latest TV position, accounting for the
  /// time elapsed since the last status update was received.
  void _syncLocalAudio() {
    final player = _localAudioPlayer;
    if (player == null || !_localAudioReady) return;

    // If the user just manually controlled playback, respect their intent for 1000ms
    // before letting the timer override position — prevents audio jumping on quick seeks.
    final lastAction = _lastManualActionTime;
    final recentManualAction =
        lastAction != null &&
        DateTime.now().difference(lastAction).inMilliseconds < 1000;

    // Extrapolate TV's current position from last known status
    final timeSinceStatus =
        _lastStatusTime != null
            ? DateTime.now().difference(_lastStatusTime!).inMilliseconds /
                1000.0
            : 0.0;
    final expectedPos =
        _isPlaying
            ? (_position + timeSinceStatus).clamp(
              0.0,
              _duration > 0 ? _duration : double.infinity,
            )
            : _position;

    // Always keep play/pause in sync
    if (_isPlaying && !player.state.playing) {
      player.play();
    } else if (!_isPlaying && player.state.playing) {
      player.pause();
    }

    // Sync volume to match the remote control state
    final targetVol = _volume * 100.0;
    if ((player.state.volume - targetVol).abs() > 1.0) {
      player.setVolume(targetVol);
    }

    // Skip drift correction right after a manual seek/action to avoid fighting it
    if (recentManualAction) return;

    // Correct drift: use a 2.0s threshold for hard seeks (with loading UI),
    // and seamless speed adjustment for drifts above 20ms.
    final localPos = player.state.position.inMilliseconds / 1000.0;
    final diff =
        localPos -
        expectedPos; // positive = local is AHEAD, negative = local is BEHIND
    // Use 4-decimal precision for matching as requested
    final absDiff = double.parse(diff.abs().toStringAsFixed(4));

    if (absDiff > 2.0 && !player.state.buffering) {
      debugPrint(
        '[CastSource] Hard sync (4-dec): local=${localPos.toStringAsFixed(4)}s, expected=${expectedPos.toStringAsFixed(4)}s, diff=${diff.toStringAsFixed(4)}s',
      );

      // Pause both to allow perfectly clean resync
      final wasPlayingGlobal = _isPlaying;
      if (wasPlayingGlobal) {
        _sendControl('pause');
        player.pause();
      }

      // Explicitly show loading state during hard sync for visual feedback
      if (mounted) {
        setState(() {
          _localAudioReady = false;
          _castSourceLog = 'Resyncing...';
        });
      }

      // Seek both players to the same calculated expected position
      // (ensures local and remote are truly pointing to the same time code)
      _sendControl('seek', seekPosition: expectedPos);
      player.seek(Duration(milliseconds: (expectedPos * 1000).toInt()));

      // Mark as manual for 5 seconds to let the seek settle and avoid fighting status updates
      _lastManualActionTime = DateTime.now().add(const Duration(seconds: 5));

      // Restore playback rate after hard sync
      if (player.state.rate != 1.0) player.setRate(1.0);

      // Re-enable ready state & Play after a delay to allow both players to seek and buffer
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted && _isCastSourceAudio) {
          setState(() {
            _localAudioReady = true;
          });
          if (wasPlayingGlobal) {
            _sendControl('play');
            player.play();
          }
        }
      });
    } else if (absDiff > 0.02) {
      // Seamless drift correction: target below 100ms consistently
      // We start adjusting speed as soon as we drift more than 20ms.
      double rate = 1.0;
      if (diff > 0.6)
        rate = 0.94;
      else if (diff > 0.1)
        rate = 0.97;
      else if (diff > 0.02)
        rate = 0.99;
      else if (diff < -0.6)
        rate = 1.06;
      else if (diff < -0.1)
        rate = 1.03;
      else if (diff < -0.02)
        rate = 1.01;

      if (player.state.rate != rate) {
        debugPrint(
          '[CastSource] Fine-sync rate: $rate (diff: ${diff.toStringAsFixed(4)}s)',
        );
        player.setRate(rate);
      }
    } else {
      // Sync matched within 20ms threshold (sub-100ms requirement met)
      if (player.state.rate != 1.0) {
        player.setRate(1.0);
      }
    }
  }

  /// Immediately sync local audio player for user-initiated seek/play/pause
  void _syncLocalAudioNow({double? seekTo, bool? playing}) {
    final player = _localAudioPlayer;
    if (player == null || !_isCastSourceAudio || !_localAudioReady) return;

    // Mark the time so the background sync timer doesn't immediately undo this
    if (seekTo != null || playing != null) {
      // Debounce for 5 seconds after manual seek to let remote player status stabilize
      _lastManualActionTime = DateTime.now().add(const Duration(seconds: 5));
    }
    if (seekTo != null) {
      player.seek(Duration(milliseconds: (seekTo * 1000).toInt()));
    }
    if (playing == true && !player.state.playing) {
      player.play();
    } else if (playing == false && player.state.playing) {
      player.pause();
    }
  }

  Future<void> _switchLocalAudioTrack(int trackIndex, {String? label}) async {
    final player = _localAudioPlayer;
    if (!_isCastSourceAudio) return;

    // Concurrency Guard: If a switch is in progress, just queue the latest request.
    if (_isSwitchingTrack) {
      debugPrint('[CastSource] Switch already in progress, queueing: $label');
      _pendingLocalAudioTrack = trackIndex;
      _pendingLocalAudioLabel = label;
      return;
    }

    _isSwitchingTrack = true;
    _lastManualActionTime = DateTime.now().add(const Duration(seconds: 2));
    _logCastStep('Switching track...');

    // If the player isn't even ready yet, just update the pending track and wait.
    if (player == null || !_localAudioReady) {
      _pendingLocalAudioTrack = trackIndex;
      _pendingLocalAudioLabel = label;
      _isSwitchingTrack = false;
      return;
    }

    final wasPlayingGlobal = _isPlaying;

    try {
      // PAUSE TV while switching to ensure clean sync on resume
      _sendControl('pause');
      setState(() {
        _localAudioReady = false;
        _castSourceLog = 'Syncing...';
      });

      final realTracks =
          player.state.tracks.audio
              .where((t) => t.id.isNotEmpty && t.id != 'auto')
              .toList();

      // ── Precise Switch Strategy ──────────────────────────────────────────────
      if (player.platform is NativePlayer) {
        final np = player.platform as NativePlayer;
        final wasPlayingLocal = player.state.playing;

        // 1. Pause for clean pipeline break
        await player.pause();

        // 2. Map target index/label to real track
        AudioTrack? track;
        if (label != null) {
          track = realTracks.firstWhere(
            (t) =>
                (t.title?.toLowerCase() == label.toLowerCase()) ||
                (t.language?.toLowerCase() == label.toLowerCase()),
            orElse:
                () => realTracks[trackIndex.clamp(0, realTracks.length - 1)],
          );
        } else {
          track = realTracks[trackIndex.clamp(0, realTracks.length - 1)];
        }

        final localIdx = realTracks.indexOf(track);
        debugPrint(
          '[CastSource] Switching: aid=${localIdx + 1} label=$label matched=${track.title}',
        );

        // 3. Select track
        await np.setProperty('aid', (localIdx + 1).toString());
        await player.setAudioTrack(track);

        // 4. Wait for codec switch to settle (Android PCM buffer)
        await Future.delayed(const Duration(milliseconds: 300));

        // 5. Resume
        _localAudioReady = true;
        if (wasPlayingLocal) await player.play();

        // RESUME TV if it was playing before the switch
        if (wasPlayingGlobal) {
          _sendControl('play');
        }

        if (mounted) {
          _logCastStep('Ready');
          _showCastInfo(
            'Switched to ${track.title ?? 'Track ${localIdx + 1}'}',
          );
        }
      } else {
        // Non-native fallback: simple setAudioTrack
        final localIdx = trackIndex.clamp(0, realTracks.length - 1);
        await player.setAudioTrack(realTracks[localIdx]);
        _localAudioReady = true;
      }
    } catch (e) {
      debugPrint(
        '[CastSource] Optimized switch failed, falling back to full restart: $e',
      );
      // ── FALLBACK: Full Engine Restart ─────────────────────────────────────────
      _logCastStep('Restarting audio...');
      final currentPos = player.state.position.inMilliseconds / 1000.0;
      _pendingLocalAudioTrack = trackIndex;
      _pendingLocalAudioLabel = label;
      _localAudioReady = false;
      await _startLocalAudio(currentPos, wasPlayingGlobal);
    } finally {
      _isSwitchingTrack = false;
      // If a new request came in WHILE we were switching, handle it now
      if (_pendingLocalAudioTrack != null || _pendingLocalAudioLabel != null) {
        final nextIdx = _pendingLocalAudioTrack ?? trackIndex;
        final nextLabel = _pendingLocalAudioLabel;
        _pendingLocalAudioTrack = null;
        _pendingLocalAudioLabel = null;
        _switchLocalAudioTrack(nextIdx, label: nextLabel);
      }
    }
  }

  void _stopLocalAudio() {
    debugPrint('[CastSource] Stopping local audio');
    _castSyncTimer?.cancel();
    _castSyncTimer = null;
    _playerErrorSub?.cancel();
    _playerErrorSub = null;
    _localAudioPlayer?.dispose();
    _localAudioPlayer = null;
    _localAudioReady = false;
    _isCastSourceAudio = false;
    _localAudioStartedAt = null;
    _pendingLocalAudioTrack = null;
    _castSourceStartAttempts = 0;
    _castSourceLog = null;
  }

  String _formatDuration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite || seconds < 0) return '0:00';
    // Use try-catch or limit the value to avoid toInt() overflow/error
    final ms =
        (seconds * 1000)
            .clamp(0.0, 3600000000.0)
            .toInt(); // Limit to 1000 hours
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              _connected
                  ? _accentColor.withValues(alpha: 0.15)
                  : Colors.red.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 24,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCompactHeader(),
            if (_expanded) ...[
              if (!_hasStartedPlaying) ...[
                const SizedBox(height: 20),
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _accentColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Connecting & Loading Media...',
                        style: GoogleFonts.outfit(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ] else ...[
                _buildSeekSection(),
                _buildPlaybackControls(),
                _buildVolumeSection(),
                if (_audioTracks.length > 1 || _subtitleTracks.isNotEmpty)
                  _buildTrackSection(),
                const SizedBox(height: 8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // ── Compact header with expand/collapse ──

  Widget _buildCompactHeader() {
    return GestureDetector(
      onTap:
          () => setState(() {
            _expanded = !_expanded;
            _showAudioMenu = false;
            _showSubtitleMenu = false;
          }),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: _cardColor,
          border: Border(
            bottom: BorderSide(
              color:
                  _expanded
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          children: [
            // Cast icon with pulse
            AnimatedBuilder(
              animation: _pulseController,
              builder:
                  (_, __) => Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: (_connected ? _accentColor : Colors.red)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.cast_connected_rounded,
                      color:
                          _connected
                              ? Color.lerp(
                                _accentColor.withValues(alpha: 0.6),
                                _accentColor,
                                _pulseController.value,
                              )
                              : Colors.red.withValues(alpha: 0.5),
                      size: 18,
                    ),
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
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              _connected ? const Color(0xFF4CAF50) : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _connected
                              ? widget.targetDeviceName
                              : _lastStatusTime == null
                              ? 'Connecting to ${widget.targetDeviceName}...'
                              : 'Connection lost. Reconnecting...',
                          style: GoogleFonts.outfit(
                            color:
                                _connected
                                    ? Colors.white38
                                    : (_lastStatusTime == null
                                        ? Colors.white30
                                        : Colors.orangeAccent.withValues(
                                          alpha: 0.7,
                                        )),
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_isCastSourceAudio) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.speaker_phone_rounded,
                          color: _accentColor,
                          size: 12,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          _localAudioReady ? 'Phone Audio' : 'Starting...',
                          style: GoogleFonts.outfit(
                            color:
                                _localAudioReady
                                    ? _accentColor.withValues(alpha: 0.7)
                                    : Colors.orange.withValues(alpha: 0.7),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_castSourceLog != null && !_localAudioReady) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 8,
                            height: 8,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.2,
                              color: _accentColor.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _castSourceLog!,
                            style: GoogleFonts.outfit(
                              color: _accentColor.withValues(alpha: 0.7),
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                      if (_connected && !_expanded) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${_formatDuration(_isSeeking ? _seekValue : _animatedPosition)} / ${_formatDuration(_duration)}',
                          style: GoogleFonts.outfit(
                            color: Colors.white24,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_castSourceError != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Colors.red.shade300,
                          size: 11,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _castSourceError!,
                            style: GoogleFonts.outfit(
                              color: Colors.red.shade300,
                              fontSize: 9,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // Mini play/pause when collapsed
            if (!_expanded)
              if (!_hasStartedPlaying)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _accentColor,
                    ),
                  ),
                )
              else
                IconButton(
                  onPressed: () {
                    final wasPlaying = _isPlaying;
                    setState(() => _isPlaying = !wasPlaying);
                    _sendControl(wasPlaying ? 'pause' : 'play');
                    _syncLocalAudioNow(playing: !wasPlaying);
                  },
                  icon: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: _accentColor,
                    size: 22,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
            // Expand/collapse
            IconButton(
              onPressed:
                  () => setState(() {
                    _expanded = !_expanded;
                    _showAudioMenu = false;
                    _showSubtitleMenu = false;
                  }),
              icon: Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: Colors.white38,
                size: 20,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            // Open Full Screen Remote
            IconButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (context) => CastRemoteControlScreen(
                          targetDeviceIp: widget.targetDeviceIp,
                          targetDeviceName: widget.targetDeviceName,
                          fileName: widget.fileName,
                          videoUrl: widget.videoUrl,
                          localFileUri: widget.localFileUri,
                        ),
                  ),
                );
              },
              icon: const Icon(
                Icons.fullscreen_rounded,
                color: _accentColor,
                size: 20,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            // Disconnect
            IconButton(
              onPressed: () {
                _sendControl('stop');
                _stopLocalAudio();
                _discoveryService.stopCastSession();
                setState(() {
                  _hasStartedPlaying = false;
                });
                widget.onDisconnect?.call();
              },
              icon: const Icon(
                Icons.close_rounded,
                color: Colors.white30,
                size: 18,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }

  // ── Seek bar section ──

  Widget _buildSeekSection() {
    final maxVal = _duration > 0 ? _duration : 1.0;
    final currentVal =
        _isSeeking ? _seekValue : _animatedPosition.clamp(0.0, maxVal);
    final bufferedVal = _buffered.clamp(0.0, maxVal);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Column(
        children: [
          SizedBox(
            height: 28,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: _accentColor,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                thumbColor: _accentColor,
                overlayColor: _accentColor.withValues(alpha: 0.12),
                secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: currentVal.clamp(0.0, maxVal),
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
                  _syncLocalAudioNow(seekTo: v);
                  setState(() {
                    _position = v;
                    _animatedPosition = v;
                    _isSeeking = false;
                  });
                },
              ),
            ),
          ),
          // Time labels
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(currentVal),
                  style: GoogleFonts.jetBrainsMono(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_isBuffering)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 8,
                        height: 8,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: _accentColor.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Buffering',
                        style: GoogleFonts.outfit(
                          color: Colors.white24,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                Text(
                  _formatDuration(maxVal),
                  style: GoogleFonts.jetBrainsMono(
                    color: Colors.white30,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Playback controls (rewind, play/pause, forward) ──

  Widget _buildPlaybackControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // -30s
          _buildControlBtn(
            icon: Icons.replay_30_rounded,
            size: 22,
            onTap: () {
              final newPos = (_position - 30).clamp(
                0.0,
                _duration > 0 ? _duration : 0.0,
              );
              _sendControl('seek', seekPosition: newPos);
              _syncLocalAudioNow(seekTo: newPos);
              setState(() {
                _position = newPos;
                _animatedPosition = newPos;
              });
            },
          ),
          const SizedBox(width: 8),
          // -10s
          _buildControlBtn(
            icon: Icons.replay_10_rounded,
            size: 26,
            onTap: () {
              final newPos = (_position - 10).clamp(
                0.0,
                _duration > 0 ? _duration : 0.0,
              );
              _sendControl('seek', seekPosition: newPos);
              _syncLocalAudioNow(seekTo: newPos);
              setState(() {
                _position = newPos;
                _animatedPosition = newPos;
              });
            },
          ),
          const SizedBox(width: 12),
          // Play/Pause
          GestureDetector(
            onTap: () {
              final wasPlaying = _isPlaying;
              // Optimistic update — change icon immediately without waiting for status
              setState(() => _isPlaying = !wasPlaying);
              _sendControl(wasPlaying ? 'pause' : 'play');
              _syncLocalAudioNow(playing: !wasPlaying);
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _accentColor,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: _accentColor.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.black,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // +10s
          _buildControlBtn(
            icon: Icons.forward_10_rounded,
            size: 26,
            onTap: () {
              final newPos = (_position + 10).clamp(
                0.0,
                _duration > 0 ? _duration : 0.0,
              );
              _sendControl('seek', seekPosition: newPos);
              _syncLocalAudioNow(seekTo: newPos);
              setState(() {
                _position = newPos;
                _animatedPosition = newPos;
              });
            },
          ),
          const SizedBox(width: 8),
          // +30s
          _buildControlBtn(
            icon: Icons.forward_30_rounded,
            size: 22,
            onTap: () {
              final newPos = (_position + 30).clamp(
                0.0,
                _duration > 0 ? _duration : 0.0,
              );
              _sendControl('seek', seekPosition: newPos);
              _syncLocalAudioNow(seekTo: newPos);
              setState(() {
                _position = newPos;
                _animatedPosition = newPos;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required double size,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _surfaceColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white70, size: size),
        ),
      ),
    );
  }

  // ── Volume section ──

  Widget _buildVolumeSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              final newVol = _volume > 0 ? 0.0 : 1.0;
              setState(() => _volume = newVol);
              _sendControl('volume', volume: newVol);
            },
            child: Icon(
              _volume == 0
                  ? Icons.volume_off_rounded
                  : _volume < 0.3
                  ? Icons.volume_mute_rounded
                  : _volume < 0.7
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
              color: Colors.white38,
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                  activeTrackColor: Colors.white54,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                  thumbColor: Colors.white70,
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
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 32,
            child: Text(
              '${(_volume * 100).round()}',
              style: GoogleFonts.jetBrainsMono(
                color: Colors.white30,
                fontSize: 10,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  // ── Audio & Subtitle track section ──

  Widget _buildTrackSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Column(
        children: [
          Row(
            children: [
              // Audio track button
              if (_audioTracks.length > 1)
                Expanded(
                  child: _buildTrackButton(
                    icon: Icons.audiotrack_rounded,
                    label:
                        _activeAudioTrack != null &&
                                _activeAudioTrack! < _audioTracks.length
                            ? _audioTracks[_activeAudioTrack!]
                            : 'Audio',
                    active: _showAudioMenu,
                    onTap:
                        () => setState(() {
                          _showAudioMenu = !_showAudioMenu;
                          _showSubtitleMenu = false;
                        }),
                  ),
                ),
              if (_audioTracks.length > 1 && _subtitleTracks.isNotEmpty)
                const SizedBox(width: 8),
              // Subtitle track button
              if (_subtitleTracks.isNotEmpty)
                Expanded(
                  child: _buildTrackButton(
                    icon: Icons.subtitles_rounded,
                    label:
                        _activeSubtitleTrack != null &&
                                _activeSubtitleTrack! < _subtitleTracks.length
                            ? _subtitleTracks[_activeSubtitleTrack!]
                            : 'Subtitles Off',
                    active: _showSubtitleMenu,
                    onTap:
                        () => setState(() {
                          _showSubtitleMenu = !_showSubtitleMenu;
                          _showAudioMenu = false;
                        }),
                  ),
                ),
            ],
          ),
          // Audio track picker
          if (_showAudioMenu)
            _buildTrackPicker(_audioTracks, _activeAudioTrack, (idx) {
              _sendControl('setAudioTrack', trackIndex: idx);
              // Also switch the local audio player's track when in castSource mode
              if (_isCastSourceAudio) {
                _switchLocalAudioTrack(idx);
              }
              setState(() {
                _activeAudioTrack = idx;
                _showAudioMenu = false;
              });
            }),
          // Subtitle track picker
          if (_showSubtitleMenu) _buildSubtitlePicker(),
        ],
      ),
    );
  }

  Widget _buildTrackButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? _accentColor.withValues(alpha: 0.1) : _surfaceColor,
            borderRadius: BorderRadius.circular(8),
            border:
                active
                    ? Border.all(color: _accentColor.withValues(alpha: 0.3))
                    : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: active ? _accentColor : Colors.white38,
                size: 14,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: GoogleFonts.outfit(
                    color: active ? _accentColor : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                active
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color:
                    active
                        ? _accentColor.withValues(alpha: 0.5)
                        : Colors.white24,
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrackPicker(
    List<String> tracks,
    int? activeIdx,
    void Function(int) onSelect,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 150),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: tracks.length,
        itemBuilder: (context, idx) {
          final isActive = idx == activeIdx;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(idx),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: isActive ? _accentColor.withValues(alpha: 0.08) : null,
                child: Row(
                  children: [
                    if (isActive)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.check_rounded,
                          color: _accentColor,
                          size: 14,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        tracks[idx],
                        style: GoogleFonts.outfit(
                          color: isActive ? _accentColor : Colors.white70,
                          fontSize: 12,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSubtitlePicker() {
    final allOptions = ['Off', ..._subtitleTracks];
    final activeIdx =
        _activeSubtitleTrack != null ? _activeSubtitleTrack! + 1 : 0;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 150),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: allOptions.length,
        itemBuilder: (context, idx) {
          final isActive = idx == activeIdx;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                if (idx == 0) {
                  _sendControl('setSubtitleTrack', trackIndex: -1);
                  setState(() {
                    _activeSubtitleTrack = null;
                    _showSubtitleMenu = false;
                  });
                } else {
                  _sendControl('setSubtitleTrack', trackIndex: idx - 1);
                  setState(() {
                    _activeSubtitleTrack = idx - 1;
                    _showSubtitleMenu = false;
                  });
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: isActive ? _accentColor.withValues(alpha: 0.08) : null,
                child: Row(
                  children: [
                    if (isActive)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.check_rounded,
                          color: _accentColor,
                          size: 14,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        allOptions[idx],
                        style: GoogleFonts.outfit(
                          color: isActive ? _accentColor : Colors.white70,
                          fontSize: 12,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
