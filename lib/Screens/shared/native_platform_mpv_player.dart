import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'video_player_interface.dart';

// =============================================================================
// Native Platform MPV Player Implementation (Linux + Windows)
//
// Architecture (Linux):
//   GTK Window
//   ├── GDK child window (X11 XID) ← MPV renders here via --wid
//   └── Flutter GL surface (transparent) ← Dart overlay UI on top
//
// Control flow:
//   Dart → MethodChannel → C++ plugin →  spawn mpv process
//                                         with --wid=<XID>
//                                         + --input-ipc-server=<socket>
//   Dart ← pollEvents ← C++ plugin  ←  GIOChannel reads from unix socket
//
// The C++ plugin exposes:
//   - initialize    → creates window + spawns MPV, returns XID
//   - getXid        → returns X11 window ID
//   - getSocketPath → returns unix socket path
//   - command       → sends command as list args (builds JSON IPC internally)
//   - sendCommand   → sends raw JSON string to IPC socket
//   - pollEvents    → returns List<String> of JSON event lines
//   - resize        → syncs video window to Flutter view size
//   - dispose       → kills MPV, cleans up
// =============================================================================

class NativePlatformMpvPlayer implements PlatformVideoPlayer {
  static const MethodChannel _channel = MethodChannel('zapshare/video_player');
  static const MethodChannel _legacyChannel = MethodChannel(
    'com.zapshare/mpv_player',
  );

  bool _isInitialized = false;
  int? _xid; // X11 window ID (Linux) or dummy (Windows)
  String? _socketPath; // Unix socket path (Linux)

  int? get textureId => null; // No texture — hole-punch approach
  int? get xid => _xid;
  String? get socketPath => _socketPath;

  // ───────────────────────────────────────────────
  // Streams
  // ───────────────────────────────────────────────

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
  Duration _lastKnownDuration = Duration.zero;
  bool _localPlayingState = false;

  Timer? _pollTimer;
  bool _isPolling = false;
  Completer<void>? _initCompleter;

  NativePlatformMpvPlayer() {
    _initializeInternal();
  }

  // ───────────────────────────────────────────────
  // Initialization
  // ───────────────────────────────────────────────

  Future<void> _initializeInternal() async {
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<void>();

    try {
      debugPrint("NativePlatformMpvPlayer: Initializing native plugin...");

      // On Windows, the old MethodChannel handler is used
      // On Linux, the new process-based plugin responds
      if (Platform.isWindows) {
        _channel.setMethodCallHandler(_handleMethodCall);
      }

      final result = await _channel.invokeMethod('initialize');
      if (result is int && result > 0) {
        _xid = result;
        debugPrint("NativePlatformMpvPlayer: Got XID = $_xid");
      }

      // Get socket path (Linux only)
      if (Platform.isLinux) {
        try {
          final path = await _channel.invokeMethod<String>('getSocketPath');
          _socketPath = path;
          debugPrint("NativePlatformMpvPlayer: IPC socket = $_socketPath");
        } catch (_) {}
      }

      _isInitialized = true;
      _startEventPolling();
      debugPrint("NativePlatformMpvPlayer: Initialized successfully.");
      _initCompleter!.complete();
    } catch (e) {
      debugPrint("MPV Init Error: $e");
      _errorController.add(e.toString());
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry
    }
  }

  // ───────────────────────────────────────────────
  // Event Polling (polls C++ event queue)
  // ───────────────────────────────────────────────

  void _startEventPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _pollEvents();
    });
    // Immediate first poll
    _pollEvents();
  }

  Future<void> _pollEvents() async {
    if (_isPolling || !_isInitialized) return;
    _isPolling = true;
    try {
      final List<dynamic>? events = await _channel.invokeMethod<List<dynamic>>(
        'pollEvents',
      );
      if (events != null) {
        for (final dynamic item in events) {
          if (item is String) {
            _handleIpcEvent(item);
          }
        }
      }
    } catch (e) {
      // Channel might not be available during shutdown
    } finally {
      _isPolling = false;
    }
  }

  /// Parse a JSON IPC event line from MPV and dispatch to streams.
  void _handleIpcEvent(String jsonStr) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String? event = data['event'] as String?;

      if (event == 'property-change') {
        _handlePropertyChange(data);
      } else if (event == 'end-file') {
        _playingController.add(false);
        _completedController.add(true);
      } else if (event == 'file-loaded') {
        debugPrint('[MPV IPC] file-loaded');
      } else if (event == 'start-file') {
        _completedController.add(false);
      }

      // Error handling
      final String? error = data['error'] as String?;
      if (error != null && error != 'success') {
        _errorController.add('MPV IPC Error: $error');
      }
    } catch (e) {
      // Non-JSON lines (e.g. request responses) — ignore
    }
  }

  void _handlePropertyChange(Map<String, dynamic> data) {
    final String? name = data['name'] as String?;
    final dynamic value = data['data'];

    switch (name) {
      case 'time-pos':
        if (value is num) {
          final pos = Duration(milliseconds: (value.toDouble() * 1000).round());
          _positionController.add(pos);
          _currentPosition = pos;
        }
        break;

      case 'duration':
        if (value is num) {
          final dur = Duration(milliseconds: (value.toDouble() * 1000).round());
          if (dur.inMilliseconds == 0 &&
              _lastKnownDuration.inMilliseconds > 0) {
            // Ignore transient zero duration
            return;
          }
          _durationController.add(dur);
          _lastKnownDuration = dur;
        }
        break;

      case 'pause':
        if (value is bool) {
          _localPlayingState = !value;
          _playingController.add(!value);
        }
        break;

      case 'paused-for-cache':
        if (value is bool) {
          _bufferingController.add(value);
        }
        break;

      case 'eof-reached':
        if (value == true) {
          _completedController.add(true);
          _playingController.add(false);
        }
        break;

      case 'track-list':
        if (value is List) {
          _handleTrackListUpdate(value);
        }
        break;
    }
  }

  void _handleTrackListUpdate(List<dynamic> tracks) {
    final subs = <SubtitleTrackInfo>[];
    final audios = <AudioTrackInfo>[];
    SubtitleTrackInfo? activeSub;
    AudioTrackInfo? activeAudio;

    for (var t in tracks) {
      if (t is! Map) continue;
      final type = t['type'] as String?;
      final id = t['id'];
      final lang = (t['lang'] ?? 'unknown') as String;
      final title = (t['title'] ?? t['label'] ?? 'Track $id') as String;
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

  // ───────────────────────────────────────────────
  // Windows legacy handler (kept for backward compat)
  // ───────────────────────────────────────────────

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPosition':
        if (call.arguments is num) {
          final pos = Duration(
            milliseconds: ((call.arguments as num).toDouble() * 1000).round(),
          );
          _positionController.add(pos);
          _currentPosition = pos;
        }
        break;
      case 'onDuration':
        if (call.arguments is num) {
          final dur = Duration(
            milliseconds: ((call.arguments as num).toDouble() * 1000).round(),
          );
          if (dur.inMilliseconds == 0 &&
              _lastKnownDuration.inMilliseconds > 0) {
            return;
          }
          _durationController.add(dur);
          _lastKnownDuration = dur;
        }
        break;
      case 'onState':
        if (call.arguments is bool) {
          final isPlaying = call.arguments as bool;
          _localPlayingState = isPlaying;
          _playingController.add(isPlaying);
        }
        break;
      case 'onBuffering':
        if (call.arguments is bool) {
          _bufferingController.add(call.arguments as bool);
        }
        break;
      case 'onError':
        _errorController.add(call.arguments.toString());
        break;
      case 'onLog':
        if (call.arguments is String) {
          debugPrint("[Native] ${call.arguments}");
        }
        break;
    }
  }

  // ───────────────────────────────────────────────
  // PlatformVideoPlayer Implementation
  // ───────────────────────────────────────────────

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    debugPrint("[MPV Open] Source: $source, Subtitle: $subtitlePath");
    if (!_isInitialized) await _initializeInternal();

    // Reset state
    _currentPosition = Duration.zero;
    _positionController.add(Duration.zero);
    _completedController.add(false);

    // Normalize path
    String loadSource = source;
    bool looksLikeUrl = source.contains('://');
    if (!looksLikeUrl) {
      loadSource = source.replaceAll('\\', '/');
    }

    // Network stream optimizations
    if (looksLikeUrl) {
      if (source.contains('live.wav') || source.contains('localhost:50006')) {
        await _sendCommand(['set_property', 'cache', 'no']);
        await _sendCommand(['set_property', 'cache-pause', 'no']);
        await _sendCommand(['set_property', 'audio-buffer', '0.08']);
        await _sendCommand(['set_property', 'demuxer-max-bytes', '1048576']);
        await _sendCommand(['set_property', 'demuxer-readahead-secs', '0']);
        await _sendCommand(['set_property', 'vd-lavc-threads', '1']);
        await _sendCommand(['set_property', 'demuxer-lavf-analyzeduration', '0.1']);
        await _sendCommand(['set_property', 'demuxer-lavf-probesize', '8192']);
        await _sendCommand(['set_property', 'video-latency-hacks', 'yes']);
        await _sendCommand(['set_property', 'stream-buffer-size', '32k']);
        await _sendCommand(['set_property', 'network-timeout', '5']);
      } else {
        await _sendCommand(['apply-profile', 'default']);
        await _sendCommand(['set_property', 'cache', 'yes']);
        await _sendCommand(['set_property', 'cache-pause', 'yes']);
        await _sendCommand([
          'set_property',
          'demuxer-max-bytes',
          Platform.isLinux ? '512M' : '150M',
        ]);
        await _sendCommand([
          'set_property',
          'demuxer-readahead-secs',
          Platform.isLinux ? '600' : '60',
        ]);
        await _sendCommand([
          'set_property',
          'cache-secs',
          Platform.isLinux ? '120' : '60',
        ]);
        await _sendCommand(['set_property', 'user-agent', 'ZapShare/1.0']);
        await _sendCommand(['set_property', 'network-timeout', '30']);
      }
    }

    // Load file via IPC
    if (looksLikeUrl && (source.contains('live.wav') || source.contains('localhost:50006'))) {
      await _sendCommand([
        'loadfile',
        loadSource,
        'replace',
        0,
        'cache=no,cache-pause=no,demuxer-max-bytes=1048576,demuxer-readahead-secs=0,audio-buffer=0.08,vd-lavc-threads=1,demuxer-lavf-analyzeduration=0.1,demuxer-lavf-probesize=8192,video-latency-hacks=yes,stream-buffer-size=32k,network-timeout=5'
      ]);
    } else {
      await _sendCommand(['loadfile', loadSource]);
    }

    // Decoder optimizations for Linux (High bitrate HEVC)
    if (Platform.isLinux) {
      await _sendCommand(['set_property', 'hwdec', 'auto']);
      await _sendCommand(['set_property', 'vd-lavc-threads', '0']);
      await _sendCommand(['set_property', 'vd-lavc-dr', 'yes']);
      await _sendCommand(['set_property', 'vd-lavc-fast', 'yes']);
      await _sendCommand(['set_property', 'scale', 'bilinear']);
      // Enable keyboard in MPV embedded mode
      await _sendCommand(['set_property', 'input-vo-keyboard', 'yes']);
      await _sendCommand(['set_property', 'input-default-bindings', 'yes']);
    }

    // Auto-play
    await play();

    // External subtitle
    if (subtitlePath != null) {
      await _sendCommand(['sub-add', subtitlePath]);
    }
  }

  @override
  Future<void> play() async {
    _localPlayingState = true;
    _playingController.add(true);
    await _sendCommand(['set_property', 'pause', false]);
  }

  @override
  Future<void> pause() async {
    _localPlayingState = false;
    _playingController.add(false);
    await _sendCommand(['set_property', 'pause', true]);
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
    _currentPosition = position;
    _positionController.add(position);
    final seconds = position.inMilliseconds / 1000.0;
    await _sendCommand(['seek', seconds.toString(), 'absolute']);
  }

  @override
  Future<void> setRate(double speed) async {
    await _sendCommand(['set_property', 'speed', speed.toString()]);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _sendCommand(['set_property', 'volume', volume.toString()]);
  }

  @override
  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
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

  // ───────────────────────────────────────────────
  // Tracks
  // ───────────────────────────────────────────────

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    if (track == null) {
      await _sendCommand(['set_property', 'sid', 'no']);
    } else if (track is SubtitleTrackInfo) {
      await _sendCommand(['set_property', 'sid', track.id]);
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      await _sendCommand(['set_property', 'aid', track.id]);
    }
  }

  // ───────────────────────────────────────────────
  // Getters
  // ───────────────────────────────────────────────

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

  // ───────────────────────────────────────────────
  // Widget Builder
  // ───────────────────────────────────────────────

  @override
  Widget buildVideoWidget({
    BoxFit? fit,
    Color? backgroundColor,
    Widget Function(BuildContext)? subtitleBuilder,
  }) {
    return _NativeMpvWidget(player: this);
  }

  // ───────────────────────────────────────────────
  // Advanced
  // ───────────────────────────────────────────────

  @override
  Future<void> setProperty(String key, String value) async {
    await _sendCommand(['set_property', key, value]);
  }

  /// Tell native code to re-sync MPV window position.
  Future<void> notifyResize() async {
    try {
      await _channel.invokeMethod('resize');
    } catch (e) {
      debugPrint("notifyResize error: $e");
    }
  }

  // ───────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────

  /// Send a command to MPV. On Linux, this goes through the C++ plugin
  /// which builds JSON IPC and writes to the Unix socket. On Windows,
  /// it uses the existing MethodChannel 'command' handler.
  Future<void> _sendCommand(List<dynamic> args) async {
    debugPrint("[MPV Command] Sending: $args");
    try {
      await _channel.invokeMethod('command', args);
    } catch (e) {
      if (Platform.isWindows) {
        try {
          final legacyPayload = {'command': args};
          await _legacyChannel.invokeMethod('sendCommand', {
            'command': jsonEncode(legacyPayload),
          });
          return;
        } catch (legacyError) {
          debugPrint("MPV Command Error: $e");
          debugPrint("MPV Legacy Command Error: $legacyError");
          return;
        }
      }
      debugPrint("MPV Command Error: $e");
    }
  }
}

// =============================================================================
// Widget — transparent hole-punch that lets the native X11 window show through
// =============================================================================

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
    widget.player.errorStream.listen((err) {
      if (mounted) setState(() => _error = err);
    });

    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (widget.player._isInitialized && !_initialized) {
        setState(() => _initialized = true);
        widget.player.notifyResize();
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

    // True rendering hole-punch: physically erases the Flutter canvas (including opaque routes
    // below this one) to perfectly transparent so the X11 underlay window can show through.
    if ((Platform.isLinux || Platform.isWindows) && _initialized) {
      return CustomPaint(size: Size.infinite, painter: _HolePunchPainter());
    }

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

class _HolePunchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Erases all flutter drawing in this rect (including opaque background routes)
    final paint = Paint()..blendMode = BlendMode.clear;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
