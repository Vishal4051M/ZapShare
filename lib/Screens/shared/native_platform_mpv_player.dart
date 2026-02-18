import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'video_player_interface.dart';

// -----------------------------------------------------------------------------
// Native Platform MPV Player Implementation
// -----------------------------------------------------------------------------

class NativePlatformMpvPlayer implements PlatformVideoPlayer {
  static const MethodChannel _channel = MethodChannel('zapshare/video_player');

  bool _isInitialized = false;

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _captionController = StreamController<String>.broadcast();

  final _subtitleTracksController =
      StreamController<List<SubtitleTrackInfo>>.broadcast();
  final _audioTracksController =
      StreamController<List<AudioTrackInfo>>.broadcast();
  final _activeSubtitleController =
      StreamController<SubtitleTrackInfo?>.broadcast();
  final _activeAudioController = StreamController<AudioTrackInfo?>.broadcast();
  Duration _currentPosition = Duration.zero;

  Completer<void>? _initCompleter;

  NativePlatformMpvPlayer() {
    _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<void>();

    try {
      debugPrint("NativePlatformMpvPlayer: Connecting to native plugin...");
      _channel.setMethodCallHandler(_handleMethodCall);
      await _channel.invokeMethod('initialize');

      // Re-register properties from Dart side to be absolutely sure
      // C++ side does it too, but redundancy helps if the pipe wasn't fully ready
      // Re-register properties from Dart side to be absolutely sure
      // C++ side does it too, but redundancy helps if the pipe wasn't fully ready
      // Updated: We now rely on C++ side reacting to "file-loaded" event.
      // Removed scheduled observers from here.

      _isInitialized = true;
      debugPrint("NativePlatformMpvPlayer: Initialized successfully.");
      _initCompleter!.complete();
    } catch (e) {
      debugPrint("MPV Init Error: $e");
      _errorController.add(e.toString());
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    // Uncomment for deep debugging of IPC traffic
    debugPrint(
      "[MPV IPC] Received: ${call.method} with args: ${call.arguments}",
    );

    switch (call.method) {
      case 'onPosition':
        if (call.arguments is num) {
          final positionSeconds = (call.arguments as num).toDouble();
          final position = Duration(
            milliseconds: (positionSeconds * 1000).round(),
          );
          _positionController.add(position);
          _currentPosition = position;
        }
        break;
      case 'onDuration':
        if (call.arguments is num) {
          final durationSeconds = (call.arguments as num).toDouble();
          final duration = Duration(
            milliseconds: (durationSeconds * 1000).round(),
          );

          // FIX: Ignore 0 duration if we already have a valid one.
          // MPV might report 0 temporarily during seek/buffering.
          if (duration.inMilliseconds == 0 &&
              _lastKnownDuration.inMilliseconds > 0) {
            debugPrint(
              "NativePlatformMpvPlayer: Ignored zero duration update (keeping $_lastKnownDuration)",
            );
            return;
          }

          _durationController.add(duration);
          _handleDurationUpdate(duration);
        }
        break;
      case 'onState':
        if (call.arguments is bool) {
          final isPlaying = call.arguments as bool;
          _playingController.add(isPlaying);
        }
        break;
      case 'onBuffering':
        if (call.arguments is bool) {
          final isBuffering = call.arguments as bool;
          _bufferingController.add(isBuffering);
        }
        break;
      case 'onError':
        debugPrint("MPV Player Error from Native: ${call.arguments}");
        _errorController.add(call.arguments.toString());
        break;
      case 'onTracks':
        if (call.arguments is String) {
          try {
            final List<dynamic> tracks = jsonDecode(call.arguments as String);
            _handleTrackUpdate(tracks);
          } catch (e) {
            debugPrint("Error parsing tracks: $e");
          }
        }
        break;
      case 'onLog':
        if (call.arguments is String) {
          debugPrint("[Native] ${call.arguments}");
        }
        break;
      case 'onSubtitle':
        if (call.arguments is String) {
          _captionController.add(call.arguments as String);
        } else {
          _captionController.add('');
        }
        break;
    }
  }

  void _handleTrackUpdate(List<dynamic> tracks) {
    final subs = <SubtitleTrackInfo>[];
    final audios = <AudioTrackInfo>[];
    SubtitleTrackInfo? activeSub;
    AudioTrackInfo? activeAudio;

    for (var t in tracks) {
      if (t is! Map) continue;
      final type = t['type'];
      final id = t['id'];
      final lang = t['lang'] ?? 'unknown';
      final title = t['title'] ?? t['label'] ?? 'Track $id';
      final selected = t['selected'] == true;

      if (type == 'sub') {
        final info = SubtitleTrackInfo(
          id: id.toString(),
          title: "$title ($lang)",
          language: lang,
        );
        subs.add(info);
        if (selected) activeSub = info;
      } else if (type == 'audio') {
        final info = AudioTrackInfo(
          id: id.toString(),
          title: "$title ($lang)",
          language: lang,
        );
        audios.add(info);
        if (selected) activeAudio = info;
      }
    }

    _subtitleTracksController.add(subs);
    _audioTracksController.add(audios);
    _activeSubtitleController.add(activeSub);
    _activeAudioController.add(activeAudio);
  }

  // ---------------------------------------------------------------------------
  // PlatformVideoPlayer Implementation
  // ---------------------------------------------------------------------------

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    debugPrint("[MPV Action] Opening source: $source (subs: $subtitlePath)");
    if (!_isInitialized) await _initializeInternal();

    // Reset state
    _currentPosition = Duration.zero;
    _positionController.add(Duration.zero);

    // Handle local files
    // Use raw path for Windows, C++ plugin handles JSON escaping correctly.
    // We strictly ensure backslashes for Windows paths to be safe.
    String loadSource = source;
    bool looksLikeUrl = source.contains('://');
    if (!looksLikeUrl) {
      // Normalize to forward slashes for MPV (works better cross-platform + Windows)
      loadSource = source.replaceAll('\\', '/');
    }

    // Load file
    await _sendCommand(['loadfile', loadSource]);

    // Note: C++ now handles 'file-loaded' event automatically to start observers

    // Start polling fallback just in case IPC event is missed (safety net)
    // Especially important for HTTP streams where metadata might delay
    _startDurationPolling();

    // Auto-play
    await play();

    if (subtitlePath != null) {
      await _sendCommand(['sub-add', subtitlePath]);
    }
  }

  // Duration polling timer (Safety Net)
  Timer? _durationTimer;
  Duration _lastKnownDuration = Duration.zero;

  void _startDurationPolling() {
    _durationTimer?.cancel();
    _lastKnownDuration = Duration.zero;

    // Poll every 1 second until we get a valid duration
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_lastKnownDuration.inMilliseconds > 0) {
        timer.cancel(); // We have duration, stop polling
        return;
      }
      // Retry getting duration using forceful get_property
      // ID 100 matches the Duration Polling ID in C++ plugin
      _getProperty('duration', 100);
    });
  }

  // Handle duration updates to stop polling
  void _handleDurationUpdate(Duration dur) {
    debugPrint("NativePlatformMpvPlayer: Duration update received: $dur");
    if (dur.inMilliseconds > 0) {
      _lastKnownDuration = dur;
      // Note: We don't cancel instantly on first non-zero because stream info might refine
      // But typically it's safe to cancel once we have a value.
      _durationTimer?.cancel();
      _durationTimer = null;
    }
  }

  bool _localPlayingState = false;

  @override
  Future<void> play() async {
    // Optimistic update
    _localPlayingState = true;
    _playingController.add(true);
    await _sendCommand(['set', 'pause', 'no']);
  }

  @override
  Future<void> pause() async {
    // Optimistic update
    _localPlayingState = false;
    _playingController.add(false);
    await _sendCommand(['set', 'pause', 'yes']);
  }

  @override
  Future<void> playOrPause() async {
    if (_localPlayingState) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    // Optimistic update
    _currentPosition = position;
    _positionController.add(position);

    // Use floating point seconds for precision
    final seconds = position.inMilliseconds / 1000.0;
    // Send as double for correct JSON serialization
    await _sendCommand(['seek', seconds, 'absolute']);
  }

  @override
  Future<void> setRate(double speed) async {
    await _sendCommand(['set', 'speed', speed]);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _sendCommand(['set', 'volume', volume]);
  }

  @override
  Future<void> dispose() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}

    _playingController.close();
    _positionController.close();
    _durationController.close();
    _bufferController.close();
    _bufferingController.close();
    _completedController.close();
    _errorController.close();
    _captionController.close();

    _subtitleTracksController.close();
    _audioTracksController.close();
    _activeSubtitleController.close();
    _activeAudioController.close();
  }

  // ---------------------------------------------------------------------------
  // Tracks (Stubs for now as we need IPC readback to support them)
  // ---------------------------------------------------------------------------

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    if (track == null) {
      await _sendCommand(['set', 'sid', 'no']);
    } else if (track is SubtitleTrackInfo) {
      await _sendCommand(['set', 'sid', track.id]);
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      await _sendCommand(['set', 'aid', track.id]);
    }
  }

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------
  Duration get currentPosition => _currentPosition;

  @override
  Stream<bool> get playingStream => _playingController.stream;
  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<Duration> get bufferStream => _bufferController.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;
  @override
  Stream<bool> get completedStream => _completedController.stream;
  @override
  Stream<String> get errorStream => _errorController.stream;
  @override
  Stream<String> get captionStream => _captionController.stream;

  @override
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream =>
      _subtitleTracksController.stream;
  @override
  Stream<List<AudioTrackInfo>> get audioTracksStream =>
      _audioTracksController.stream;
  @override
  Stream<SubtitleTrackInfo?> get activeSubtitleTrackStream =>
      _activeSubtitleController.stream;
  @override
  Stream<AudioTrackInfo?> get activeAudioTrackStream =>
      _activeAudioController.stream;

  // ---------------------------------------------------------------------------
  // Widget Builder
  // ---------------------------------------------------------------------------

  @override
  Widget buildVideoWidget({
    BoxFit? fit,
    Color? backgroundColor,
    Widget Function(BuildContext)? subtitleBuilder,
  }) {
    // Return the transparent capture widget
    return _NativeMpvWidget(player: this);
  }

  // ---------------------------------------------------------------------------
  // Advanced
  // ---------------------------------------------------------------------------
  @override
  Future<void> setProperty(String key, String value) async {
    await _sendCommand(['set_property', key, value]);
  }

  /// Tell native code to re-sync MPV window position.
  /// Called after fullscreen toggle or window resize events.
  Future<void> notifyResize() async {
    try {
      await _channel.invokeMethod('resize');
    } catch (e) {
      debugPrint("notifyResize error: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _sendCommand(List<dynamic> args) async {
    debugPrint("[MPV Command] Sending: $args");
    try {
      await _channel.invokeMethod('command', args);
    } catch (e) {
      debugPrint("MPV Command Error: $e");
    }
  }

  Future<void> _getProperty(String property, int id) async {
    debugPrint("[MPV getProperty] Requesting: $property (id: $id)");
    try {
      await _channel.invokeMethod('get_property', [property, id]);
    } catch (e) {
      debugPrint("MPV getProperty Error: $e");
    }
  }

  void _stopPolling() {}
}

// -----------------------------------------------------------------------------
// Widget
// -----------------------------------------------------------------------------

class _NativeMpvWidget extends StatefulWidget {
  final NativePlatformMpvPlayer player;

  const _NativeMpvWidget({Key? key, required this.player}) : super(key: key);

  @override
  State<_NativeMpvWidget> createState() => _NativeMpvWidgetState();
}

class _NativeMpvWidgetState extends State<_NativeMpvWidget> {
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // Listen for errors
    widget.player.errorStream.listen((err) {
      if (mounted) setState(() => _error = err);
    });

    // Poll for initialized state
    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (widget.player._isInitialized && !_initialized) {
        setState(() => _initialized = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              "Player Error:\n$_error",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      );
    }

    // IMPORTANT: This container must be transparent to reveal the MPV window behind it.
    // No GestureDetector here — the VideoPlayerScreen handles all gestures/taps.
    return Container(
      color: Colors.transparent,
      width: double.infinity,
      height: double.infinity,
      child:
          !_initialized
              ? const Center(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
              )
              : null,
    );
  }
}
