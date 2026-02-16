import 'dart:async';
import 'package:flutter/widgets.dart';

/// Common interface for platform-specific video players
/// Windows: MPV with native Win32 child window
/// Android: ExoPlayer via video_player package
abstract class PlatformVideoPlayer {
  // ─── Playback Control ─────────────────────────────────────
  Future<void> open(String source, {String? subtitlePath});
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setRate(double speed);
  Future<void> setVolume(double volume); // 0.0 - 100.0
  Future<void> dispose();

  // ─── Subtitles ────────────────────────────────────────────
  Future<void> setSubtitleTrack(dynamic track);
  Future<void> setAudioTrack(dynamic track);

  // ─── State Streams ────────────────────────────────────────
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;

  // ─── Track Info ───────────────────────────────────────────
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream;
  Stream<List<AudioTrackInfo>> get audioTracksStream;
  Stream<SubtitleTrackInfo?> get activeSubtitleTrackStream;
  Stream<AudioTrackInfo?> get activeAudioTrackStream;

  // ─── Video Widget ─────────────────────────────────────────
  /// Returns the video rendering widget (native surface or texture)
  Widget buildVideoWidget({
    BoxFit? fit,
    Color? backgroundColor,
    Widget Function(BuildContext)? subtitleBuilder,
  });

  // ─── Advanced Settings (platform-specific) ────────────────
  Future<void> setProperty(String key, String value);
}

/// Common subtitle track info
class SubtitleTrackInfo {
  final String id;
  final String? title;
  final String? language;

  SubtitleTrackInfo({
    required this.id,
    this.title,
    this.language,
  });

  static SubtitleTrackInfo get none => SubtitleTrackInfo(id: 'no', title: 'None');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleTrackInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Common audio track info
class AudioTrackInfo {
  final String id;
  final String? title;
  final String? language;

  AudioTrackInfo({
    required this.id,
    this.title,
    this.language,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrackInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
