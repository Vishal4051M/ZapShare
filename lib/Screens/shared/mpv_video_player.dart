import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_player_interface.dart';

/// Cross-platform MPV video player using media_kit
/// Used for Android, Linux, macOS (and potentially Windows fallback)
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
    final isAndroid = Platform.isAndroid;
    _player = Player(
      configuration: PlayerConfiguration(
        // 128 MB for Android (prevents rebuffer stalls)
        // 256 MB for Desktop (handles large HDR/4K files)
        bufferSize: isAndroid ? 128 * 1024 * 1024 : 256 * 1024 * 1024,
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
      if (Platform.isAndroid) {
        // ═══ ANDROID: Maximum performance config ═══
        // Hardware decoding — mediacodec for zero-copy HW decode
        await np.setProperty('hwdec', 'mediacodec');
        await np.setProperty('hwdec-codecs', 'all');

        // Software fallback
        await np.setProperty('vd-lavc-software-fallback', '60');

        // Minimal scaling for mobile
        await np.setProperty('scale', 'bilinear');
        await np.setProperty('dscale', 'bilinear');
        await np.setProperty('cscale', 'bilinear');

        // Audio-sync avoids frame timing issues
        await np.setProperty('video-sync', 'audio');

        // Drop frames at VO level only
        await np.setProperty('framedrop', 'vo');

        // Large demuxer buffers + async cache
        await np.setProperty('demuxer-max-bytes', '150MiB');
        await np.setProperty('demuxer-max-back-bytes', '32MiB');
        await np.setProperty('demuxer-readahead-secs', '300');

        // Async cache layer
        await np.setProperty('cache', 'yes');
        await np.setProperty('cache-secs', '120');
        await np.setProperty('cache-pause-initial', 'yes');
        await np.setProperty('cache-pause-wait', '1');

        // Fast seeking
        await np.setProperty('hr-seek', 'yes');
        await np.setProperty('hr-seek-framedrop', 'yes');

        // Deinterlace auto
        await np.setProperty('deinterlace', 'auto');

        // Audio
        await np.setProperty('audio-pitch-correction', 'yes');
        await np.setProperty('audio-channels', 'auto-safe');

        // Performance
        await np.setProperty('vd-lavc-threads', '0');
        await np.setProperty('vd-lavc-dr', 'yes');
        await np.setProperty('untimed', 'no');
      } else {
        // ═══ DESKTOP (Linux/Mac/Fallback) ═══
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
      }

      // ═══ SUBTITLES ═══
      // Start with subtitles hidden, will be shown when user selects a track
      // This prevents double rendering and gives user control
      await np.setProperty('sub-visibility', 'no');

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
          await np.setProperty('cache-secs', Platform.isAndroid ? '90' : '180');
          if (Platform.isAndroid) {
            await np.setProperty('demuxer-readahead-secs', '600');
            await np.setProperty('cache-pause-wait', '3');
          }
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
      // Hide subtitles when turning off
      if (_player.platform is NativePlayer) {
        final np = _player.platform as NativePlayer;
        await np.setProperty('sub-visibility', 'no');
      }
    } else if (track is SubtitleTrackInfo) {
      if (track.id == 'no') {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        // Hide subtitles when turning off
        if (_player.platform is NativePlayer) {
          final np = _player.platform as NativePlayer;
          await np.setProperty('sub-visibility', 'no');
        }
      } else {
        // Use current state (synchronous) instead of stream.first (waits for next emission, hangs)
        final currentTracks = _player.state.tracks;
        final mpvTrack = currentTracks.subtitle.firstWhere(
          (t) => t.id == track.id,
          orElse: () => SubtitleTrack.no(),
        );
        await _player.setSubtitleTrack(mpvTrack);
        // Ensure subtitles are visible when selecting a track
        if (_player.platform is NativePlayer) {
          final np = _player.platform as NativePlayer;
          await np.setProperty('sub-visibility', 'yes');
        }
      }
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      // Use current state (synchronous) instead of stream.first (waits for next emission, hangs)
      final currentTracks = _player.state.tracks;
      final mpvTrack = currentTracks.audio.firstWhere(
        (t) => t.id == track.id,
        orElse: () => currentTracks.audio.first,
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
  Stream<String> get captionStream =>
      _player.stream.subtitle.map((list) => list.join('\n'));

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
    // Do NOT add SubtitleView here — VideoPlayerScreen renders subtitles
    // via its own captionStream overlay. Adding SubtitleView causes
    // double subtitles on Android.
    return Video(
      controller: _controller,
      fill: backgroundColor ?? Colors.black,
      fit: fit ?? BoxFit.contain,
      controls: NoVideoControls,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        visible: false,
      ),
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
