import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Professional MPV native window player for Windows
/// Uses child HWND with direct D3D11 swapchain ownership
///
/// Architecture:
/// Flutter Window
/// ├── Native Win32 child HWND
/// │   └── MPV renders here using vo=gpu-next
/// └── Flutter transparent overlay UI
class NativeMpvPlayer {
  static const MethodChannel _channel = MethodChannel(
    'com.zapshare/mpv_player',
  );

  int? _windowId;
  StreamController<MpvEvent>? _eventController;
  Timer? _pollTimer;
  bool _isPolling = false;

  // Playback state streams
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<Duration> get position => _positionController.stream;
  Stream<Duration> get duration => _durationController.stream;
  Stream<bool> get playing => _playingController.stream;
  Stream<bool> get buffering => _bufferingController.stream;
  Stream<String> get errors => _errorController.stream;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  NativeMpvPlayer();

  /// Initialize native window and MPV process
  ///
  /// [mpvPath] - Path to mpv.exe (e.g., 'C:\\mpv\\mpv.exe')
  /// [x, y, width, height] - Initial window position and size
  Future<void> initialize({
    required String mpvPath,
    int x = 0,
    int y = 0,
    int width = 800,
    int height = 600,
  }) async {
    try {
      // Create native window - handled by C++ Runner in this architecture.
      // We just need to launch MPV and set initial layout.

      // Set initial layout first
      await resize(x: x, y: y, width: width, height: height);

      // Launch MPV process attached to the pre-existing window
      // windowId is not needed but we can pass 0 for compatibility if desired,
      // but our C++ implementation ignores it.
      final String? pipeName = await _channel.invokeMethod<String>(
        'launchMpv',
        {'windowId': 0, 'mpvPath': mpvPath},
      );

      if (pipeName == null) {
        throw Exception('Failed to launch MPV');
      }

      // We use a dummy ID since we have a single window architecture
      _windowId = 1;

      debugPrint('✓ MPV launched with IPC pipe: $pipeName');

      _isInitialized = true;
      _startEventPolling();
    } catch (e) {
      debugPrint('✗ Failed to initialize MPV: $e');
      rethrow;
    }
  }

  /// Resize native window (call when Flutter window resizes)
  Future<void> resize({
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    if (_windowId == null) return;

    await _channel.invokeMethod('resizeWindow', {
      'windowId': _windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
    });
  }

  /// Load and play video file
  Future<void> open(String path) async {
    if (_windowId == null) throw StateError('Not initialized');

    final command = jsonEncode({
      'command': ['loadfile', path],
    });

    await _channel.invokeMethod('sendCommand', {
      'windowId': _windowId,
      'command': command,
    });
  }

  /// Play
  Future<void> play() async {
    await setProperty('pause', 'no');
  }

  /// Pause
  Future<void> pause() async {
    await setProperty('pause', 'yes');
  }

  /// Toggle play/pause
  Future<void> togglePlayPause() async {
    final command = jsonEncode({
      'command': ['cycle', 'pause'],
    });

    await _channel.invokeMethod('sendCommand', {
      'windowId': _windowId,
      'command': command,
    });
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    final command = jsonEncode({
      'command': ['seek', position.inSeconds.toString(), 'absolute'],
    });

    await _channel.invokeMethod('sendCommand', {
      'windowId': _windowId,
      'command': command,
    });
  }

  /// Set volume (0.0 to 100.0)
  Future<void> setVolume(double volume) async {
    await setProperty('volume', volume.toString());
  }

  /// Set playback speed
  Future<void> setSpeed(double speed) async {
    await setProperty('speed', speed.toString());
  }

  /// Load subtitle file
  Future<void> loadSubtitle(String path) async {
    final command = jsonEncode({
      'command': ['sub-add', path],
    });

    await _channel.invokeMethod('sendCommand', {
      'windowId': _windowId,
      'command': command,
    });
  }

  /// Set subtitle track
  Future<void> setSubtitleTrack(int trackId) async {
    await setProperty('sid', trackId.toString());
  }

  /// Set audio track
  Future<void> setAudioTrack(int trackId) async {
    await setProperty('aid', trackId.toString());
  }

  /// Set generic MPV property
  Future<void> setProperty(String property, String value) async {
    if (_windowId == null) throw StateError('Not initialized');

    await _channel.invokeMethod('setProperty', {
      'windowId': _windowId,
      'property': property,
      'value': value,
    });
  }

  /// Get MPV property value
  Future<String?> getProperty(String property) async {
    if (_windowId == null) throw StateError('Not initialized');

    return await _channel.invokeMethod<String>('getProperty', {
      'windowId': _windowId,
      'property': property,
    });
  }

  /// Send raw MPV command (JSON format)
  Future<void> sendCommand(Map<String, dynamic> command) async {
    if (_windowId == null) throw StateError('Not initialized');

    await _channel.invokeMethod('sendCommand', {
      'windowId': _windowId,
      'command': jsonEncode(command),
    });
  }

  /// Handle MPV events from native side (which sends raw JSON strings)
  void _handleMpvEvent(dynamic eventArg) {
    try {
      // The native side sends a String containing JSON
      if (eventArg is! String) return;

      final String eventJson = eventArg;
      // We expect the string to be the JSON object itself
      final dynamic decoded = jsonDecode(eventJson);
      if (decoded is! Map<String, dynamic>) return;

      final event = MpvEvent.fromJson(decoded);

      // Update state streams based on events
      if (event.event == 'property-change') {
        switch (event.name) {
          case 'time-pos':
            if (event.data is num) {
              _positionController.add(
                Duration(seconds: (event.data as num).toInt()),
              );
            }
            break;
          case 'duration':
            if (event.data is num) {
              _durationController.add(
                Duration(seconds: (event.data as num).toInt()),
              );
            }
            break;
          case 'pause':
            if (event.data is bool) {
              _playingController.add(!(event.data as bool));
            }
            break;
          case 'paused-for-cache':
            if (event.data is bool) {
              _bufferingController.add(event.data as bool);
            }
            break;
        }
      } else if (event.event == 'end-file') {
        _playingController.add(false);
      } else if (event.event == 'client-message' && event.error != null) {
        _errorController.add(event.error!);
      } else if (event.error != null && event.error != 'success') {
        _errorController.add('MPV Error: ${event.error}');
      }

      _eventController?.add(event);
    } catch (e) {
      debugPrint('Error handling MPV event: $e');
    }
  }

  /// Get raw event stream
  Stream<MpvEvent> get events {
    _eventController ??= StreamController<MpvEvent>.broadcast();
    return _eventController!.stream;
  }

  // ─── Event Polling ─────────────────────────────────────────

  /// Start polling C++ event queue.
  /// Uses a 100ms Timer — responsive enough for UI updates, light enough
  /// to avoid measurable CPU overhead.
  void _startEventPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _pollEvents();
    });
    // Also do an immediate first poll
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
          _handleMpvEvent(item);
        }
      }
    } catch (e) {
      // Channel might not be available during shutdown, ignore
      debugPrint('[NativeMpvPlayer] pollEvents error: $e');
    } finally {
      _isPolling = false;
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isInitialized = false;

    if (_windowId != null) {
      try {
        await _channel.invokeMethod('destroyWindow', {'windowId': _windowId});
      } catch (e) {
        debugPrint('[NativeMpvPlayer] destroyWindow error: $e');
      }
      _windowId = null;
    }

    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _errorController.close();
    await _eventController?.close();
  }
}

/// MPV event data model
class MpvEvent {
  final String event;
  final String? name;
  final dynamic data;
  final int? id;
  final int? requestId;
  final String? error;

  MpvEvent({
    required this.event,
    this.name,
    this.data,
    this.id,
    this.requestId,
    this.error,
  });

  factory MpvEvent.fromJson(Map<String, dynamic> json) {
    return MpvEvent(
      event: json['event'] as String,
      name: json['name'] as String?,
      data: json['data'],
      id: json['id'] as int?,
      requestId: json['request_id'] as int?,
      error: json['error'] as String?,
    );
  }

  @override
  String toString() =>
      'MpvEvent($event${name != null ? ", $name" : ""}${data != null ? ", data=$data" : ""})';
}
