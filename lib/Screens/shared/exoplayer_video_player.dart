import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:zap_share/services/device_discovery_service.dart';
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
  final StreamController<String> _captionController =
      StreamController<String>.broadcast(); // New caption stream

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

  // Manual subtitle parsing
  List<_SubtitleItem> _subtitles = [];

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    try {
      // Determine source type
      if (source.startsWith('http://') || source.startsWith('https://')) {
        _controller = vp.VideoPlayerController.networkUrl(
          Uri.parse(source),
          httpHeaders: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
          },
          videoPlayerOptions: vp.VideoPlayerOptions(
            mixWithOthers: true,
            allowBackgroundPlayback: true,
          ),
        );
      } else {
        _controller = vp.VideoPlayerController.file(
          File(source),
          videoPlayerOptions: vp.VideoPlayerOptions(
            mixWithOthers: true,
            allowBackgroundPlayback: true,
          ),
        );
      }

      // Parse subtitles if provided (Manual parsing for custom styling)
      if (subtitlePath != null) {
        await _parseSubtitles(subtitlePath);
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
      // We emit empty lists to satisfy the interface unless subtitles were parsed.
      // However, check if the controller reports any caption text initially or if we want to enable a "Native/Embedded" track option.
      // Since we can't key off a list, we'll optimistically add a "Native" track if no external subtitles were loaded,
      // just so the UI allows toggling. But this is tricky because we don't know if there ARE native subtitles.
      if (_subtitles.isEmpty) {
        // Optimistically add a "Default/Embedded" track so the user can at least try to toggle them on
        // if the video has embedded CCs (which video_player handles via caption field).
        final placeholder = SubtitleTrackInfo(
          id: 'embedded',
          title: 'Embedded / CC',
          language: 'und',
        );
        _subtitleTracksController.add([placeholder]);
        // Default to not active unless needed, but let's leave it null.
      }

      _audioTracksController.add(
        [],
      ); // Still no audio track support via video_player
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
    final isCompleted =
        value.position >= value.duration && value.duration.inMilliseconds > 0;
    _completedController.add(isCompleted);

    // Error
    if (value.hasError && value.errorDescription != null) {
      _errorController.add(value.errorDescription!);
    }
  }

  @override
  Stream<String> get captionStream => _captionController.stream;

  Future<void> _parseSubtitles(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final lines = const LineSplitter().convert(content);
      _subtitles.clear();

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;

        // Skip index number if present
        if (int.tryParse(line) != null) continue;

        if (line.contains('-->')) {
          final parts = line.split('-->');
          if (parts.length == 2) {
            final start = _parseDuration(parts[0].trim());
            final end = _parseDuration(parts[1].trim());

            // Collect text
            String text = '';
            while (i + 1 < lines.length) {
              final nextLine = lines[++i].trim();
              if (nextLine.isEmpty) break;
              text += (text.isEmpty ? '' : '\n') + nextLine;
            }

            if (text.isNotEmpty) {
              _subtitles.add(_SubtitleItem(start: start, end: end, text: text));
            }
          }
        }
      }

      if (_subtitles.isNotEmpty) {
        final track = SubtitleTrackInfo(
          id: 'external',
          title: 'External (SRT)',
          language: 'en',
        );
        _subtitleTracksController.add([track]);
        _activeSubtitleController.add(track);
      }
    } catch (e) {
      print('❌ Error parsing subtitles: $e');
    }
  }

  Duration _parseDuration(String s) {
    try {
      final parts = s.split(':');
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final secParts = parts[2].split(parts[2].contains(',') ? ',' : '.');
      final sec = int.parse(secParts[0]);
      final ms = int.parse(secParts[1]);
      return Duration(hours: h, minutes: m, seconds: sec, milliseconds: ms);
    } catch (_) {
      return Duration.zero;
    }
  }

  void _startPositionPolling() {
    // Poll position & buffer every 250ms (reduced from 100ms to allow UI breathing room)
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_isDisposed || _controller == null) return;

      final value = _controller!.value;

      // Update position
      _positionController.add(value.position);

      // Buffer position (ExoPlayer reports buffered end time)
      if (value.buffered.isNotEmpty) {
        final bufferedEnd = value.buffered.last.end;
        _bufferController.add(bufferedEnd);
      } else {
        _bufferController.add(Duration.zero);
      }

      // Update caption
      if (_subtitles.isNotEmpty) {
        final currentPos = value.position;
        // Simple linear search is fine for < 2000 items, or use `lastIndex` optimization if needed
        // For now, simple find
        final item = _subtitles.cast<_SubtitleItem?>().firstWhere(
          (s) => s!.start <= currentPos && s.end >= currentPos,
          orElse: () => null,
        );
        _captionController.add(item?.text ?? '');
      } else if (value.caption.text.isNotEmpty) {
        // Fallback to native captions (ExoPlayer via video_player)
        _captionController.add(value.caption.text);
      } else {
        _captionController.add('');
      }
    });
  }

  @override
  Future<void> play() async {
    await _controller?.play();
    // Pause discovery broadcasts to save resources for playback
    DeviceDiscoveryService().pauseDiscovery();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
    // Resume discovery broadcasts when paused
    DeviceDiscoveryService().resumeDiscovery();

    // Immediate position update to ensure UI reflects exact pause frame
    if (_controller != null) {
      _positionController.add(_controller!.value.position);
      _playingController.add(false);
    }
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
      // If it's our manual external track, we handle it in the polling loop.
      // If it's the 'embedded' track, we rely on _controller.value.caption.
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
      width: double.infinity,
      height: double.infinity,
      child: FittedBox(
        fit: fit ?? BoxFit.contain,
        child: SizedBox(
          width: _controller!.value.size.width,
          height: _controller!.value.size.height,
          child: vp.VideoPlayer(_controller!), // Texture
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
    // Resume discovery broadcasts when closing player
    DeviceDiscoveryService().resumeDiscovery();

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

class _SubtitleItem {
  final Duration start;
  final Duration end;
  final String text;

  _SubtitleItem({required this.start, required this.end, required this.text});
}
