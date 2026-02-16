import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' as vp;
import 'video_player_interface.dart';

/// Android ExoPlayer video player implementation
/// Uses video_player package which provides ExoPlayer backend on Android
class ExoPlayerVideoPlayer implements PlatformVideoPlayer {
  vp.VideoPlayerController? _controller;

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _completedController =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  // ExoPlayer doesn't expose subtitle/audio track APIs via video_player
  // (would need platform channels for advanced features)
  final StreamController<List<SubtitleTrackInfo>> _subtitleTracksController =
      StreamController<List<SubtitleTrackInfo>>.broadcast();
  final StreamController<List<AudioTrackInfo>> _audioTracksController =
      StreamController<List<AudioTrackInfo>>.broadcast();
  final StreamController<SubtitleTrackInfo?> _activeSubtitleController =
      StreamController<SubtitleTrackInfo?>.broadcast();
  final StreamController<AudioTrackInfo?> _activeAudioController =
      StreamController<AudioTrackInfo?>.broadcast();

  Timer? _positionTimer;
  Timer? _bufferTimer;
  bool _isDisposed = false;

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    try {
      // Determine source type
      if (source.startsWith('http://') || source.startsWith('https://')) {
        _controller = vp.VideoPlayerController.networkUrl(
          Uri.parse(source),
          videoPlayerOptions: vp.VideoPlayerOptions(
            mixWithOthers: false,
            allowBackgroundPlayback: false,
          ),
        );
      } else {
        _controller = vp.VideoPlayerController.file(
          File(source),
          videoPlayerOptions: vp.VideoPlayerOptions(
            mixWithOthers: false,
            allowBackgroundPlayback: false,
          ),
        );
      }

      // Initialize
      await _controller!.initialize();

      // Set up listeners
      _controller!.addListener(_onControllerUpdate);

      // Start position polling (ExoPlayer streams position updates)
      _startPositionPolling();

      // Emit initial values
      _durationController.add(_controller!.value.duration);
      _playingController.add(_controller!.value.isPlaying);
      _bufferingController.add(_controller!.value.isBuffering);

      // Note: video_player package doesn't expose subtitle/audio track APIs
      // We emit empty lists to satisfy the interface
      _subtitleTracksController.add([]);
      _audioTracksController.add([]);
    } catch (e) {
      _errorController.add('Failed to open video: ${e.toString()}');
    }
  }

  void _onControllerUpdate() {
    if (_isDisposed || _controller == null) return;

    final value = _controller!.value;

    // Playing state
    _playingController.add(value.isPlaying);

    // Buffering state
    _bufferingController.add(value.isBuffering);

    // Duration
    _durationController.add(value.duration);

    // Completed (position >= duration)
    final isCompleted = value.position >= value.duration && 
                        value.duration.inMilliseconds > 0;
    _completedController.add(isCompleted);

    // Error
    if (value.hasError && value.errorDescription != null) {
      _errorController.add(value.errorDescription!);
    }
  }

  void _startPositionPolling() {
    // Poll position & buffer every 100ms (smooth progress updates)
    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isDisposed || _controller == null) return;

      final value = _controller!.value;
      _positionController.add(value.position);

      // Buffer position (ExoPlayer reports buffered end time)
      if (value.buffered.isNotEmpty) {
        final bufferedEnd = value.buffered.last.end;
        _bufferController.add(bufferedEnd);
      } else {
        _bufferController.add(Duration.zero);
      }
    });
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> playOrPause() async {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  @override
  Future<void> setRate(double speed) async {
    await _controller?.setPlaybackSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    // video_player expects 0.0 - 1.0
    await _controller?.setVolume(volume / 100.0);
  }

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    // video_player doesn't expose subtitle track selection
    // Would need platform channel implementation for advanced features
    // For now, emit the change event
    if (track is SubtitleTrackInfo) {
      _activeSubtitleController.add(track);
    } else {
      _activeSubtitleController.add(null);
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    // video_player doesn't expose audio track selection
    // Would need platform channel implementation
    if (track is AudioTrackInfo) {
      _activeAudioController.add(track);
    }
  }

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

  @override
  Widget buildVideoWidget({
    BoxFit? fit,
    Color? backgroundColor,
    Widget Function(BuildContext)? subtitleBuilder,
  }) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(
        color: backgroundColor ?? Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFFFFD600)),
        ),
      );
    }

    return Container(
      color: backgroundColor ?? Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: vp.VideoPlayer(_controller!),
        ),
      ),
    );
  }

  @override
  Future<void> setProperty(String key, String value) async {
    // ExoPlayer properties would need platform channel implementation
    // Not exposed via video_player package
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _positionTimer?.cancel();
    _bufferTimer?.cancel();

    await _playingController.close();
    await _positionController.close();
    await _durationController.close();
    await _bufferController.close();
    await _bufferingController.close();
    await _completedController.close();
    await _errorController.close();
    await _subtitleTracksController.close();
    await _audioTracksController.close();
    await _activeSubtitleController.close();
    await _activeAudioController.close();

    _controller?.removeListener(_onControllerUpdate);
    await _controller?.dispose();
    _controller = null;
  }
}
