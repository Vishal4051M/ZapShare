import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_player_interface.dart';

/// Windows MPV video player with native Win32 child window rendering
/// Uses media_kit for MPV integration with Flutter overlay UI
class MpvVideoPlayer implements PlatformVideoPlayer {
  late final Player _player;
  late final VideoController _controller;
  bool _isInitialized = false;

  final StreamController<List<SubtitleTrackInfo>> _subtitleTracksController =
      StreamController<List<SubtitleTrackInfo>>.broadcast();
  final StreamController<List<AudioTrackInfo>> _audioTracksController =
      StreamController<List<AudioTrackInfo>>.broadcast();
  final StreamController<SubtitleTrackInfo?> _activeSubtitleController =
      StreamController<SubtitleTrackInfo?>.broadcast();
  final StreamController<AudioTrackInfo?> _activeAudioController =
      StreamController<AudioTrackInfo?>.broadcast();

  MpvVideoPlayer() {
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 256 * 1024 * 1024, // 256 MB for Windows (4K/HDR files)
        logLevel: MPVLogLevel.warn,
      ),
    );

    // Initialize MPV properties IMMEDIATELY (synchronously) for embedded rendering
    _initializeMpvPropertiesSync();

    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // Listen to track changes and convert to common format
    _player.stream.tracks.listen((tracks) {
      _subtitleTracksController.add(
        tracks.subtitle
            .map(
              (t) => SubtitleTrackInfo(
                id: t.id,
                title: t.title,
                language: t.language,
              ),
            )
            .toList(),
      );
      _audioTracksController.add(
        tracks.audio
            .map(
              (t) => AudioTrackInfo(
                id: t.id,
                title: t.title,
                language: t.language,
              ),
            )
            .toList(),
      );
    });

    _player.stream.track.listen((track) {
      _activeSubtitleController.add(
        track.subtitle.id == 'no'
            ? null
            : SubtitleTrackInfo(
              id: track.subtitle.id,
              title: track.subtitle.title,
              language: track.subtitle.language,
            ),
      );
      _activeAudioController.add(
        AudioTrackInfo(
          id: track.audio.id,
          title: track.audio.title,
          language: track.audio.language,
        ),
      );
    });
  }

  /// Initialize MPV properties for embedded Windows rendering
  /// Called from constructor - properties are set asynchronously but ASAP
  void _initializeMpvPropertiesSync() {
    // Fire off async initialization immediately (don't wait)
    // These properties will be set before first frame render
    _initializeMpvProperties().catchError((e) {
      debugPrint('Warning: Failed to initialize MPV properties: $e');
    });
  }

  /// Do NOT override 'vo', 'gpu-context', 'gpu-api', 'video-sync', or
  /// 'framedrop'. media_kit handles all rendering and timing internally.
  /// Overriding these properties conflicts with the texture pipeline and
  /// causes sluggish playback (the "0.95x speed" feel).
  Future<void> _initializeMpvProperties() async {
    if (_player.platform is! NativePlayer) return;

    final np = _player.platform as NativePlayer;

    try {
      // ═══ HARDWARE DECODING ═══
      await np.setProperty('hwdec', 'auto-safe');
      await np.setProperty('hwdec-codecs', 'all');

      // ═══ PLAYBACK ═══
      await np.setProperty('keep-open', 'yes');

      // ═══ SEEKING ═══
      await np.setProperty('hr-seek', 'yes');

      // ═══ BUFFERING ═══
      await np.setProperty('cache', 'yes');
      await np.setProperty('cache-secs', '120');
      await np.setProperty('demuxer-max-bytes', '256MiB');
      await np.setProperty('demuxer-readahead-secs', '300');

      // ═══ AUDIO ═══
      await np.setProperty('audio-pitch-correction', 'yes');
      await np.setProperty('audio-channels', 'auto-safe');

      _isInitialized = true;
    } catch (e) {
      debugPrint('Warning: Failed to set some MPV properties: $e');
      _isInitialized = true;
    }
  }

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    // Ensure MPV properties are initialized before opening media
    // Wait up to 2 seconds for initialization to complete
    int waitCount = 0;
    while (!_isInitialized && waitCount < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitCount++;
    }

    if (!_isInitialized) {
      debugPrint('Warning: Opening media before MPV fully initialized');
    }

    // Platform-specific network settings
    if (_player.platform is NativePlayer) {
      final np = _player.platform as NativePlayer;

      // Network-specific settings for streaming
      if (source.startsWith('http')) {
        try {
          await np.setProperty('network-timeout', '30');
          await np.setProperty(
            'stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,timeout=30000000',
          );
          await np.setProperty('cache-secs', '120');
        } catch (e) {
          debugPrint('Warning: Failed to set network properties: $e');
        }
      }
    }

    // Open media
    await _player.open(Media(source));

    // Load external subtitle if provided
    if (subtitlePath != null && subtitlePath.isNotEmpty) {
      await _player.setSubtitleTrack(SubtitleTrack.uri(subtitlePath));
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double speed) => _player.setRate(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    if (track == null) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } else if (track is SubtitleTrackInfo) {
      if (track.id == 'no') {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        // Find the matching media_kit track
        final tracks = await _player.stream.tracks.first;
        final mpvTrack = tracks.subtitle.firstWhere(
          (t) => t.id == track.id,
          orElse: () => SubtitleTrack.no(),
        );
        await _player.setSubtitleTrack(mpvTrack);
      }
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      final tracks = await _player.stream.tracks.first;
      final mpvTrack = tracks.audio.firstWhere(
        (t) => t.id == track.id,
        orElse: () => tracks.audio.first,
      );
      await _player.setAudioTrack(mpvTrack);
    }
  }

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Stream<String> get errorStream => _player.stream.error;

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
    return Stack(
      children: [
        Video(
          controller: _controller,
          fill: backgroundColor ?? Colors.black,
          fit: fit ?? BoxFit.contain,
          controls: NoVideoControls,
        ),
        // Add explicit SubtitleView because NoVideoControls disables the built-in one
        SubtitleView(
          controller: _controller,
          configuration: const SubtitleViewConfiguration(
            style: TextStyle(
              height: 1.4,
              fontSize: 32.0,
              letterSpacing: 0.0,
              wordSpacing: 0.0,
              color: Color(0xffffffff),
              fontWeight: FontWeight.normal,
              backgroundColor: Color(0xaa000000),
            ),
            textAlign: TextAlign.center,
            padding: EdgeInsets.all(24.0),
          ),
        ),
      ],
    );
  }

  @override
  Future<void> setProperty(String key, String value) async {
    if (_player.platform is NativePlayer) {
      final np = _player.platform as NativePlayer;
      await np.setProperty(key, value);
    }
  }

  @override
  Future<void> dispose() async {
    await _subtitleTracksController.close();
    await _audioTracksController.close();
    await _activeSubtitleController.close();
    await _activeAudioController.close();
    await _player.dispose();
  }
}
