import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zap_share/services/device_discovery_service.dart';
import 'video_player_interface.dart';

/// Native ExoPlayer video player implementation for Android / Android TV.
///
/// Uses platform channels to communicate with the native ExoPlayerBridge (Kotlin)
/// which provides full subtitle/audio track selection via Media3 TrackSelector API.
///
/// MethodChannel: zapshare.exoplayer
/// EventChannel:  zapshare.exoplayer.events
class ExoPlayerVideoPlayer implements PlatformVideoPlayer {
  static const _methodChannel = MethodChannel('zapshare.exoplayer');
  static const _eventChannel = EventChannel('zapshare.exoplayer.events');

  int? _textureId;
  bool _isDisposed = false;
  bool _isCreated = false;
  int _videoWidth = 1920;
  int _videoHeight = 1080;
  StreamSubscription? _eventSubscription;

  // Broadcast stream controllers
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

  // Track lists cached locally
  List<SubtitleTrackInfo> _subtitleTracks = [];
  List<AudioTrackInfo> _audioTracks = [];
  SubtitleTrackInfo? _activeSubtitle;
  AudioTrackInfo? _activeAudio;

  /// Create the native ExoPlayer and get the Flutter texture ID for rendering.
  Future<void> _ensureCreated() async {
    if (_isCreated) return;

    try {
      final result = await _methodChannel.invokeMethod('create');
      _textureId = result['textureId'] as int;
      _isCreated = true;

      // Listen to native events
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (error) {
          print('ExoPlayer event error: $error');
          _errorController.add(error.toString());
        },
      );
    } catch (e) {
      _errorController.add('Failed to create ExoPlayer: $e');
      rethrow;
    }
  }

  /// Handle events from the native ExoPlayerBridge
  void _handleNativeEvent(dynamic event) {
    if (_isDisposed || event is! Map) return;

    final eventType = event['event'] as String?;
    if (eventType == null) return;

    switch (eventType) {
      case 'isPlaying':
        _playingController.add(event['value'] as bool);
        break;

      case 'isBuffering':
        _bufferingController.add(event['value'] as bool);
        break;

      case 'completed':
        _completedController.add(event['value'] as bool);
        break;

      case 'error':
        _errorController.add(event['message'] as String? ?? 'Unknown error');
        break;

      case 'position':
        final posMs = (event['position'] as num?)?.toInt() ?? 0;
        final durMs = (event['duration'] as num?)?.toInt() ?? 0;
        final bufMs = (event['buffered'] as num?)?.toInt() ?? 0;

        _positionController.add(Duration(milliseconds: posMs));
        if (durMs > 0) {
          _durationController.add(Duration(milliseconds: durMs));
        }
        _bufferController.add(Duration(milliseconds: bufMs));
        break;

      case 'duration':
        final durMs = (event['value'] as num?)?.toInt() ?? 0;
        if (durMs > 0) {
          _durationController.add(Duration(milliseconds: durMs));
        }
        break;

      case 'tracksChanged':
        _updateTracks(event);
        break;

      case 'playbackState':
        // Handle state changes if needed
        final state = event['state'] as String?;
        if (state == 'ended') {
          _completedController.add(true);
        }
        break;

      case 'videoSize':
        // Track video dimensions for proper Texture sizing
        final w = (event['width'] as num?)?.toInt() ?? 0;
        final h = (event['height'] as num?)?.toInt() ?? 0;
        if (w > 0 && h > 0) {
          _videoWidth = w;
          _videoHeight = h;
        }
        break;
      case 'caption':
        _captionController.add(event['value'] as String? ?? '');
        break;
    }
  }

  /// Parse track info from native event and update streams
  void _updateTracks(Map<dynamic, dynamic> event) {
    // Parse subtitle tracks
    final subtitlesList = event['subtitles'] as List<dynamic>?;
    if (subtitlesList != null) {
      _subtitleTracks =
          subtitlesList.map((t) {
            final track = t as Map<dynamic, dynamic>;
            return SubtitleTrackInfo(
              id: track['id'] as String? ?? 'sub_${track['index']}',
              title:
                  (track['label'] as String?)?.isNotEmpty == true
                      ? track['label'] as String
                      : 'Subtitle ${(track['index'] as int?) ?? 0 + 1}',
              language: track['language'] as String?,
            );
          }).toList();

      _subtitleTracksController.add(_subtitleTracks);

      // Find active subtitle
      SubtitleTrackInfo? activeSub;
      for (int i = 0; i < subtitlesList.length; i++) {
        final t = subtitlesList[i] as Map<dynamic, dynamic>;
        if (t['isSelected'] == true) {
          activeSub = _subtitleTracks[i];
          break;
        }
      }
      _activeSubtitle = activeSub;
      _activeSubtitleController.add(activeSub);
    }

    // Parse audio tracks
    final audioList = event['audio'] as List<dynamic>?;
    if (audioList != null) {
      _audioTracks =
          audioList.map((t) {
            final track = t as Map<dynamic, dynamic>;
            return AudioTrackInfo(
              id: track['id'] as String? ?? 'audio_${track['index']}',
              title:
                  (track['label'] as String?)?.isNotEmpty == true
                      ? track['label'] as String
                      : 'Audio ${(track['index'] as int? ?? 0) + 1}',
              language: track['language'] as String?,
            );
          }).toList();

      _audioTracksController.add(_audioTracks);

      // Find active audio
      AudioTrackInfo? activeAud;
      for (int i = 0; i < audioList.length; i++) {
        final t = audioList[i] as Map<dynamic, dynamic>;
        if (t['isSelected'] == true) {
          activeAud = _audioTracks[i];
          break;
        }
      }
      _activeAudio = activeAud;
      _activeAudioController.add(activeAud);
    }
  }

  // ─── Playback Control ─────────────────────────────────────

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    try {
      await _ensureCreated();
      await _methodChannel.invokeMethod('open', {
        'source': source,
        'subtitlePath': subtitlePath,
      });
      // Pause discovery to save resources during playback
      DeviceDiscoveryService().pauseDiscovery();
    } catch (e) {
      _errorController.add('Failed to open video: $e');
    }
  }

  @override
  Future<void> play() async {
    await _methodChannel.invokeMethod('play');
    DeviceDiscoveryService().pauseDiscovery();
  }

  @override
  Future<void> pause() async {
    await _methodChannel.invokeMethod('pause');
    DeviceDiscoveryService().resumeDiscovery();
  }

  @override
  Future<void> playOrPause() async {
    await _methodChannel.invokeMethod('playOrPause');
  }

  @override
  Future<void> seek(Duration position) async {
    await _methodChannel.invokeMethod('seekTo', {
      'position': position.inMilliseconds,
    });
  }

  @override
  Future<void> setRate(double speed) async {
    await _methodChannel.invokeMethod('setSpeed', {'speed': speed});
  }

  @override
  Future<void> setVolume(double volume) async {
    // Our interface uses 0-100, ExoPlayer uses 0.0-1.0
    await _methodChannel.invokeMethod('setVolume', {'volume': volume / 100.0});
  }

  // ─── Subtitles & Audio ────────────────────────────────────

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    if (track is SubtitleTrackInfo) {
      if (track.id == 'no') {
        // Disable subtitles
        await _methodChannel.invokeMethod('disableSubtitles');
        _activeSubtitle = null;
        _activeSubtitleController.add(null);
        return;
      }

      // Find index in our cached list
      final index = _subtitleTracks.indexWhere((s) => s.id == track.id);
      if (index >= 0) {
        await _methodChannel.invokeMethod('selectSubtitleTrack', {
          'index': index,
        });
        _activeSubtitle = track;
        _activeSubtitleController.add(track);
      }
    } else {
      // Disable subtitles
      await _methodChannel.invokeMethod('disableSubtitles');
      _activeSubtitle = null;
      _activeSubtitleController.add(null);
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      final index = _audioTracks.indexWhere((a) => a.id == track.id);
      if (index >= 0) {
        await _methodChannel.invokeMethod('selectAudioTrack', {'index': index});
        _activeAudio = track;
        _activeAudioController.add(track);
      }
    }
  }

  // ─── Streams ──────────────────────────────────────────────

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
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream {
    final controller = StreamController<List<SubtitleTrackInfo>>.broadcast();
    controller.onListen = () {
      controller.add(_subtitleTracks);
    };
    final sub = _subtitleTracksController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  @override
  Stream<List<AudioTrackInfo>> get audioTracksStream {
    final controller = StreamController<List<AudioTrackInfo>>.broadcast();
    controller.onListen = () {
      controller.add(_audioTracks);
    };
    final sub = _audioTracksController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  @override
  Stream<SubtitleTrackInfo?> get activeSubtitleTrackStream {
    final controller = StreamController<SubtitleTrackInfo?>.broadcast();
    controller.onListen = () {
      controller.add(_activeSubtitle);
    };
    final sub = _activeSubtitleController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  @override
  Stream<AudioTrackInfo?> get activeAudioTrackStream {
    final controller = StreamController<AudioTrackInfo?>.broadcast();
    controller.onListen = () {
      controller.add(_activeAudio);
    };
    final sub = _activeAudioController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  // ─── Video Widget ─────────────────────────────────────────

  @override
  Widget buildVideoWidget({
    BoxFit? fit,
    Color? backgroundColor,
    Widget Function(BuildContext)? subtitleBuilder,
  }) {
    if (_textureId == null) {
      return Container(
        color: backgroundColor ?? Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFFFFD600)),
        ),
      );
    }

    return RepaintBoundary(
      child: Container(
        color: backgroundColor ?? Colors.black,
        width: double.infinity,
        height: double.infinity,
        child: FittedBox(
          fit: fit ?? BoxFit.contain,
          child: SizedBox(
            width: _videoWidth.toDouble(),
            height: _videoHeight.toDouble(),
            child: Texture(
              textureId: _textureId!,
              filterQuality: FilterQuality.none,
            ),
          ),
        ),
      ),
    );
  }

  // ─── Advanced Settings ────────────────────────────────────

  @override
  Future<void> setProperty(String key, String value) async {
    // ExoPlayer properties could be added via the native bridge
    // For now, log and ignore
    print('ExoPlayer setProperty: $key = $value');
  }

  // ─── Dispose ──────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    DeviceDiscoveryService().resumeDiscovery();

    _isDisposed = true;
    _eventSubscription?.cancel();

    try {
      await _methodChannel.invokeMethod('dispose');
    } catch (e) {
      print('ExoPlayer dispose error: $e');
    }

    await _playingController.close();
    await _positionController.close();
    await _durationController.close();
    await _bufferController.close();
    await _bufferingController.close();
    await _completedController.close();
    await _errorController.close();
    await _captionController.close();
    await _subtitleTracksController.close();
    await _audioTracksController.close();
    await _activeSubtitleController.close();
    await _activeAudioController.close();
  }
}
